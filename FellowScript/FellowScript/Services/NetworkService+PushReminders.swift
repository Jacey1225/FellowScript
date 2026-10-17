// NetworkService+PushReminders.swift -- task 20261016-push-notifications-and-ui.
// Push preferences now carry per-reminder "HH:MM" times next to the boolean
// toggles. The flat map is parsed into a snapshot; a missing or malformed key
// throws (never a guessed default). Kept out of NetworkService.swift on purpose.

import Foundation

struct PushPreferenceSnapshot: Equatable {
    var toggles: [String: Bool]
    /// Keyed by `<type>_time` (e.g. "prayer_reminder_time"), value "HH:MM" (24h).
    var times: [String: String]
}

enum PushReminderKeys {
    /// Reminder toggle key -> its time key.
    static let timeKey: [String: String] = [
        "prayer_reminder": "prayer_reminder_time",
        "check_in_reminder": "check_in_reminder_time",
        "deep_question_reminder": "deep_question_reminder_time",
    ]
    static let timeKeys: [String] = ["prayer_reminder_time", "check_in_reminder_time", "deep_question_reminder_time"]

    /// Strict "HH:MM" (00-23 : 00-59).
    static func isValidTime(_ s: String) -> Bool {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count == 2, p[1].count == 2,
              let h = Int(p[0]), let m = Int(p[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    /// Builds "HH:MM" from calendar components so locale and DST never alter it.
    static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Today at the given "HH:MM" in the current calendar, for a DatePicker.
    static func date(from time: String, calendar: Calendar = .current) -> Date? {
        guard isValidTime(time) else { return nil }
        let p = time.split(separator: ":").compactMap { Int($0) }
        return calendar.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date())
    }
}

extension NetworkService {
    func fetchPushPreferenceSnapshot(userId: String) async throws -> PushPreferenceSnapshot {
        let data = try await request("/notification/\(encodeURIComponent(userId))/push-preferences", method: "GET")
        return try Self.parsePushPreferenceSnapshot(data)
    }

    func setPushPreferenceValue(userId: String, key: String, value: Any) async throws -> PushPreferenceSnapshot {
        let data = try await checkedRequestRaw("/notification/\(encodeURIComponent(userId))/push-preferences",
                                               method: "PUT", jsonObject: [key: value])
        return try Self.parsePushPreferenceSnapshot(data)
    }

    static func parsePushPreferenceSnapshot(_ data: Data) throws -> PushPreferenceSnapshot {
        let toggles = try parsePushPreferences(data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.networkError("Notification settings unavailable.")
        }
        var times: [String: String] = [:]
        for k in PushReminderKeys.timeKeys {
            guard let v = obj[k] as? String, PushReminderKeys.isValidTime(v) else {
                throw AppError.networkError("Notification settings unavailable.")
            }
            times[k] = v
        }
        return PushPreferenceSnapshot(toggles: toggles, times: times)
    }
}
