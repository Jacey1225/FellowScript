// Manages scheduling and firing of FSHeartbeat events.
//
// Flow:
//   scheduleAll  — registers a local UNNotification reminder for each event's next fire date.
//                  Called after any create/delete and on app foreground.
//   checkAndFire — on app foreground, calls commit_heartbeat for any event whose scheduled
//                  time has passed since it last fired. Tracks last-fired timestamps in
//                  UserDefaults so events are not double-fired across sessions.

import Foundation
import UserNotifications

enum HeartbeatScheduler {

    private static let lastFiredKey = "fs_hb_last_fired"
    // Prevents a second concurrent checkAndFire from double-firing the same event
    // when scenePhase transitions to .active more than once before the first run
    // finishes (e.g. Face ID, Control Center, or app-switcher briefly deactivates
    // the scene).  Static stored properties on enums are valid in Swift.
    private static var isFiring = false

    // ── Schedule reminder notifications for upcoming events ───────────────────

    static func scheduleAll(events: [FSHeartbeat]) {
        let center    = UNUserNotificationCenter.current()
        let activeIds = Set(events.map { "hb-\($0.id)" })

        center.getPendingNotificationRequests { pending in
            let stale = pending.map { $0.identifier }
                               .filter { $0.hasPrefix("hb-") && !activeIds.contains($0) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }

        for event in events {
            guard let fireDate = event.nextFireDate() else { continue }
            let content       = UNMutableNotificationContent()
            content.title     = "Scheduled Event"
            content.body      = event.prompt.isEmpty
                                ? "Open FellowScript to see your agent's response."
                                : String(event.prompt.prefix(80))
            content.sound     = .default
            content.userInfo  = ["heartbeat_id": event.id, "agent_id": event.agent_id]

            let comps   = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: "hb-\(event.id)", content: content, trigger: trigger
            )
            center.add(request) { _ in }
        }
    }

    // ── Fire any overdue events ────────────────────────────────────────────────

    static func checkAndFire(
        userId: String,
        events: [FSHeartbeat],
        service: DataServiceProtocol
    ) async {
        guard !isFiring else { return }
        isFiring = true
        defer { isFiring = false }

        var lastFired = UserDefaults.standard.dictionary(forKey: lastFiredKey)
                            as? [String: Double] ?? [:]
        let now = Date()

        for event in events {
            guard let dueDate = mostRecentPassedDate(for: event) else { continue }
            if let prev = lastFired[event.id], prev >= dueDate.timeIntervalSince1970 { continue }

            let result = try? await service.commitHeartbeat(
                userId: userId, agentId: event.agent_id, heartbeatId: event.id, prompt: event.prompt
            )
            // The backend always responds 200 for this route, whether the
            // heartbeat actually fired or not — {"success": "..."} on a real
            // fire, but {"error": "..."} (LLM/JSON failure) or {"skipped":
            // "..."} (already fired for this calendar day — commit_hb_response
            // now enforces a date-boundary check server-side, not just a
            // rolling window) are equally valid all-string dicts that decode
            // fine into [String: String]. Checking `result != nil` alone
            // treats all three as success, which both suppresses any retry
            // (by marking lastFired) and fires a false "Event Response Saved"
            // notification even when nothing was saved. Only a `success` key
            // means the fire actually happened. A `skipped` result deliberately
            // does NOT mark the event fired here (see
            // HeartbeatSchedulerRegressionTests.test_skippedResult_...) — the
            // server is always the source of truth for "already fired today",
            // so retrying is harmless (server just says skipped again) and
            // safer than the client guessing wrong and permanently suppressing
            // a legitimate retry (e.g. after a transient failure).
            guard result?["success"] != nil else { continue }

            lastFired[event.id] = now.timeIntervalSince1970
            // Persist immediately after each successful fire, not once after the
            // whole batch. checkAndFire awaits a network call per event, and if
            // the app is backgrounded/suspended mid-loop (e.g. the user reopens
            // briefly then swipes away again while a later event in the same
            // batch is still in flight), any events already marked fired only in
            // the in-memory `lastFired` dict would be lost — the next reopen
            // would see them as never-fired and re-call commitHeartbeat for an
            // event that already succeeded today. The backend's calendar-day
            // idempotency guard (commit_hb_response) would still no-op that
            // retry server-side, but persisting per-event here closes the gap
            // at the source instead of relying solely on the server backstop.
            UserDefaults.standard.set(lastFired, forKey: lastFiredKey)

            let content   = UNMutableNotificationContent()
            content.title = "Event Response Saved"
            content.body  = "Your agent responded to a scheduled event. Check your notes."
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "hb-resp-\(event.id)-\(Int(now.timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static func mostRecentPassedDate(for event: FSHeartbeat) -> Date? {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        fmt.timeZone = TimeZone(identifier: "UTC")   // timestamps stored as UTC "HH:mm"
        let cal = Calendar.current; let now = Date()
        var best: Date? = nil

        for offset in 0...62 {
            guard let target = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let day = cal.component(.day, from: target)
            let idx = day - 1
            guard idx < event.timestamps.count,
                  let timeStr = event.timestamps[idx], !timeStr.isEmpty,
                  let seed = fmt.date(from: timeStr) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: target)
            comps.hour   = cal.component(.hour,   from: seed)
            comps.minute = cal.component(.minute, from: seed)
            comps.second = 0
            guard let fireDate = cal.date(from: comps), fireDate <= now else { continue }
            if best == nil || fireDate > best! { best = fireDate }
        }
        return best
    }
}
