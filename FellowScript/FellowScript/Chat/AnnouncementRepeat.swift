// AnnouncementRepeat.swift — recurring announcement reminders (task
// 20261016-announcement-recurring-reminder). Pure model + rules, no UI:
// the cadence enum, the form draft, the wire change, the member-facing
// indicator text and the warm error mapping. Mirrors the server contract in
// api/backend/interactions/announcement_repeat_rules.py.
//
// The server flag ships OFF, so every repeat_* key is absent from payloads
// until it is enabled (all optional here) and a non-null repeat_interval in a
// request is rejected with a 422. The client therefore never sends a repeat
// key unless the author actually changed the repeat controls, and maps the
// flag-off rejection to a calm message instead of a raw server string.

import Foundation

enum AnnouncementRepeat: String, CaseIterable, Equatable {
    case daily, weekly, monthly

    var title: String { rawValue.capitalized }
    /// Lowercase adverb used in sentences ("Repeats weekly").
    var cadence: String { rawValue }
}

/// What the form holds for the repeat controls. `interval == nil` is Off.
struct AnnouncementRepeatDraft: Equatable {
    var interval: AnnouncementRepeat?
    /// Optional end date, normalized to the end of the chosen local day.
    var until: Date?

    static let off = AnnouncementRepeatDraft(interval: nil, until: nil)

    init(interval: AnnouncementRepeat?, until: Date?) {
        self.interval = interval
        self.until = interval == nil ? nil : until
    }

    /// Prefill from a saved announcement. Missing keys (old payloads, flag off)
    /// decode as Off.
    init(from item: FSGroupAnnouncement?) {
        let interval = item?.repeat_interval.flatMap(AnnouncementRepeat.init(rawValue:))
        self.init(interval: interval, until: item?.repeat_until.flatMap(FSAnnouncementDates.parse))
    }

    /// End of the local day for a picked date, kept inside the server horizon.
    static func endOfDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: DateComponents(day: 1, minute: -1), to: start) ?? date
        let latest = now.addingTimeInterval(TimeInterval(AnnouncementLimits.horizonDays * 86_400 - 3600))
        return min(end, latest)
    }

    /// Earliest sensible end day: the day after the first post (the server
    /// needs at least one reminder to fit before the end).
    static func earliestEndDay(after base: Date, calendar: Calendar = .current) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: base) ?? base
        return calendar.startOfDay(for: next)
    }

    /// Why the draft can't be saved yet, or nil. `base` is the first post time
    /// (the chosen publish time, or now for an already-published edit).
    func blockingError(base: Date, now: Date = Date()) -> String? {
        guard interval != nil, let until else { return nil }
        if until <= max(base, now).addingTimeInterval(3600) {
            return "Pick an end date at least a day after the first post, or leave it open."
        }
        return nil
    }

    /// The wire change relative to what was loaded. Equal = omit every key.
    func change(from original: AnnouncementRepeatDraft, timeZone: String = TimeZone.current.identifier) -> AnnouncementRepeatChange {
        if self == original { return .unchanged }
        guard let interval else { return .off }
        return .set(interval: interval, until: until, timeZone: timeZone)
    }
}

enum AnnouncementRepeatChange: Equatable {
    case unchanged
    /// Explicit null: turns the whole repeat off (the server also clears until/tz).
    case off
    /// Always carries the device IANA zone; `until == nil` sends an explicit
    /// null so a removed end date is actually cleared.
    case set(interval: AnnouncementRepeat, until: Date?, timeZone: String)

    func merge(into o: inout [String: Any]) {
        switch self {
        case .unchanged: break
        case .off: o["repeat_interval"] = NSNull()
        case .set(let interval, let until, let tz):
            o["repeat_interval"] = interval.rawValue
            o["repeat_tz"] = tz
            o["repeat_until"] = until.map(FSAnnouncementDates.string(from:)) ?? NSNull()
        }
    }
}

// ── Member-facing indicator ─────────────────────────────────────────────────
extension FSGroupAnnouncement {
    private var repeatCadence: AnnouncementRepeat? { repeat_interval.flatMap(AnnouncementRepeat.init(rawValue:)) }

    /// "Repeats weekly, until Nov 30" (cadence and end date only, never the next
    /// occurrence). Nil when there is no repeat or the key is absent.
    var repeatIndicator: String? {
        guard let cadence = repeatCadence else { return nil }
        if repeat_active == false { return "Repeat finished" }
        let head = "Repeats \(cadence.cadence)"
        if let raw = repeat_until, let d = FSAnnouncementDates.parse(raw) {
            return "\(head), until \(d.formatted(.dateTime.month(.abbreviated).day()))"
        }
        if repeat_auto_stops == true { return "\(head), ends automatically" }
        return head
    }
}

// ── Warm errors ─────────────────────────────────────────────────────────────
enum AnnouncementRepeatError {
    /// A friendly line for the server rejections tied to repeats (422 / 409) and
    /// the 403 edit rule, or nil to fall through to the form's generic handling.
    /// The server's `detail` is short and matched by substring, never shown raw.
    static func message(for error: Error) -> String? {
        guard case AppError.networkError(let raw) = error else { return nil }
        let m = raw.lowercased()
        if m.contains("repeating reminders are not available") {
            return "Repeating reminders aren't available yet. Set Repeat to Off to post this announcement."
        }
        if m.contains("at most 3 repeating") {
            return "This group already has 3 repeating announcements. Turn one off, or set this one to Off."
        }
        if m.contains("reminder limit") {
            return "This announcement has sent all the reminders it can. Set Repeat to Off to save your changes."
        }
        if m.contains("repeat_tz") {
            return "We couldn't read your time zone for the repeat. Set Repeat to Off, or try again."
        }
        if m.contains("repeat_until") || m.contains("too soon") {
            return "Pick an end date a little further out, or leave it open."
        }
        if m.contains("repeat_interval") || m.contains("repeat interval") {
            return "Choose Daily, Weekly, Monthly or Off for the repeat."
        }
        if m.contains("not allowed to edit") {
            return "Only the person who posted this, or the group creator, can change it."
        }
        return nil
    }
}
