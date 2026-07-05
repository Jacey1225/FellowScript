// Schedules iOS local notifications for each FSNotification.
// Called after any CRUD operation and on every app foreground.
//
// Flow per notification:
//   1. Compute next fire date from the timestamps array (client-side, exact)
//   2. If not already pending, fetch AI content from /trigger endpoint
//   3. Register a UNCalendarNotificationTrigger that fires at that exact time
//
// After the notification fires iOS removes it from pending. The next app
// foreground sees it missing and reschedules the following occurrence.

import Foundation
import UserNotifications

enum NotificationScheduler {

    // ── Public entry point ────────────────────────────────────────────────────

    static func scheduleAll(
        userId: String,
        notifications: [FSNotification],
        service: DataServiceProtocol
    ) async {
        let center     = UNUserNotificationCenter.current()
        let pending    = await center.pendingNotificationRequests()
        let pendingIds = Set(pending.map { $0.identifier })
        let validIds   = Set(notifications.map { $0.id })

        // Remove local notifications for notifications the user has deleted
        let stale = pending.map { $0.identifier }.filter { !validIds.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        for notif in notifications {
            // Skip if every slot is empty
            guard notif.timestamps.contains(where: { $0 != nil }) else { continue }
            // Skip if a valid future trigger is already pending for this notification
            if pendingIds.contains(notif.id) { continue }

            guard let fireDate = nextFireDate(for: notif) else { continue }

            // Fetch AI-generated body; fall back gracefully so scheduling always succeeds
            let result  = try? await service.triggerNotification(userId: userId, notifId: notif.id)
            let title   = (result?["name"]    ?? notif.name).isEmpty ? "FellowScript" : (result?["name"] ?? notif.name)
            let body    = result?["content"] ?? notif.prompt

            scheduleLocal(id: notif.id, title: title, body: body, at: fireDate)
        }
    }

    // ── Next fire date (pure, no network) ─────────────────────────────────────

    static func nextFireDate(for notification: FSNotification) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        let cal       = Calendar.current
        let now       = Date()
        let slotCount = notification.timestamps.count   // always 31

        // Walk forward up to 62 days to find the next scheduled slot
        for offset in 0..<(slotCount * 2) {
            guard let target = cal.date(byAdding: .day, value: offset, to: now) else { continue }

            let day     = cal.component(.day, from: target)  // 1–31
            let slotIdx = day - 1                             // 0-indexed

            guard slotIdx < slotCount,
                  let timeStr  = notification.timestamps[slotIdx],
                  !timeStr.isEmpty,
                  let timeSeed = fmt.date(from: timeStr) else { continue }

            // Build the exact fire date: same calendar day, clock time from the slot
            var comps        = cal.dateComponents([.year, .month, .day], from: target)
            comps.hour       = cal.component(.hour,   from: timeSeed)
            comps.minute     = cal.component(.minute, from: timeSeed)
            comps.second     = 0

            guard let fireDate = cal.date(from: comps), fireDate > now else { continue }
            return fireDate
        }
        return nil
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private static func scheduleLocal(id: String, title: String, body: String, at date: Date) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body
        content.sound     = .default

        let comps   = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Scheduler] Failed to schedule \(id): \(error.localizedDescription)")
            } else {
                let df = DateFormatter()
                df.dateStyle = .short; df.timeStyle = .short
                print("[Scheduler] Scheduled '\(title)' for \(df.string(from: date))")
            }
        }
    }
}
