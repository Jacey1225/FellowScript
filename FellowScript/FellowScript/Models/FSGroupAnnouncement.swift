// FSGroupAnnouncement.swift — group announcements (task
// 20260929-group-announcements). Mirrors api/routes/group_announcements.py.
// Dates stay as the server's ISO-8601 strings; `FSAnnouncementDates` parses
// them for display so a malformed value never crashes decoding.

import Foundation

/// The caller's free-limit usage (server `check_limit` dict). `allowed == false`
/// means creating another announcement is rejected right now.
struct FSAnnouncementGate: Codable, Equatable {
    let allowed:   Bool
    let unlimited: Bool?
    let used:      Int?
    let limit:     Int?
    let remaining: Int?
}

struct FSGroupAnnouncement: Codable, Identifiable, Equatable {
    let id:               String
    let group_id:         String
    let creator_id:       String?
    let creator_username: String?
    var title:            String
    var description:      String
    var banner_url:       String?
    var publish_at:       String
    let created_at:       String
    var updated_at:       String
    /// False = scheduled (visible to its author / group creator only).
    var published:        Bool
    /// Server-computed: author or group creator may edit/delete.
    var can_edit:         Bool
    /// Strict `#RRGGBB` or nil (= default parchment). Absent in old payloads.
    /// Never used as a color directly: go through `AnnouncementTitleColor`.
    var title_color:      String? = nil
    /// Allowlisted font key (task 20261009-announcements-advanced). Absent while the
    /// server flag is off and in old payloads; resolve via `AnnouncementTitleFont`.
    var title_font:       String? = nil
    /// Allowlisted background theme key; resolve via `AnnouncementBgTheme`.
    var bg_theme:         String? = nil
    // Part E attachments. Each key is omitted by the server while its flag is
    // off (and in old payloads), so all are optional; nil/empty = nothing to show.
    var links:            [FSAnnouncementLink]? = nil
    var gallery:          [FSAnnouncementGalleryImage]? = nil
    var is_event:         Bool? = nil
    var payment_handles:  [FSPaymentHandle]? = nil
    /// Non-nil = members can RSVP (not a group join).
    var capacity:         Int? = nil
    var rsvp_count:       Int? = nil
    var rsvp_joined:      Bool? = nil
    /// Optional poll (flag announcement_polls, task 20261024-announcement-polls). Omitted by
    /// the server while the flag is off, when there is no poll, and in old payloads.
    var poll:             FSAnnouncementPoll? = nil
    /// Optional free-text place (flag announcement_location). Omitted by the server
    /// while the flag is off and in old payloads.
    var location:         String? = nil
    // Recurring reminders (task 20261016-announcement-recurring-reminder). All
    // keys are omitted by the server while its flag is off; nil = no repeat.
    var repeat_interval:   String? = nil
    var repeat_until:      String? = nil
    var repeat_ends_at:    String? = nil
    var repeat_auto_stops: Bool?   = nil
    var repeat_active:     Bool?   = nil
    /// Editors only (prefill); the device zone is always re-sent on change.
    var repeat_tz:         String? = nil
}

/// Poll attached to an announcement. Votes are anonymous: only counts and the caller's own selection.
struct FSAnnouncementPoll: Codable, Equatable {
    var question:     String
    var multiple:     Bool
    var closes_at:    String?
    var closed:       Bool
    var total_voters: Int
    var options:      [FSPollOption]
    var my_votes:     [String]
}

struct FSPollOption: Codable, Equatable, Identifiable {
    let id:      String
    var label:   String
    var votes:   Int
    var percent: Int
}

/// What the create/edit form submits for the poll.
struct FSPollDraft: Equatable {
    var question: String
    var options:  [String]
    var multiple: Bool = false
    var closesAt: Date? = nil

    var jsonObject: [String: Any] {
        ["question": question, "options": options, "multiple": multiple,
         "closes_at": closesAt.map(FSAnnouncementDates.string(from:)) ?? NSNull()]
    }
}

struct FSAnnouncementLink: Codable, Equatable, Identifiable {
    var url:   String
    var label: String? = nil
    var id: String { url }
}

struct FSAnnouncementGalleryImage: Codable, Equatable, Identifiable {
    let key: String
    let url: String?
    var id: String { key }
}

/// Display-only host payment handle (Venmo / Cash App / PayPal / Zelle).
/// The app never processes a payment.
struct FSPaymentHandle: Codable, Equatable, Identifiable {
    var provider: String
    var handle:   String
    var id: String { provider }
}

struct FSAnnouncementsPage: Codable, Equatable {
    var announcements: [FSGroupAnnouncement]
    var truncated:     Bool?
    var gate:          FSAnnouncementGate?
}

/// Chat-header widget source: `{"announcement": {...} | null}`.
struct FSLatestAnnouncement: Codable, Equatable {
    var announcement: FSGroupAnnouncement?
}

enum FSAnnouncementDates {
    /// Python's isoformat() emits microseconds, which ISO8601DateFormatter
    /// does not reliably accept; trim the fraction to milliseconds first.
    static func parse(_ raw: String) -> Date? {
        var s = raw
        if let dot = s.firstIndex(of: "."),
           let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = s[s.index(after: dot)..<end]
            s.replaceSubrange(dot..<end, with: "." + String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// ISO-8601 with an explicit +00:00 offset (what the server requires).
    static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    static func display(_ raw: String) -> String {
        guard let d = parse(raw) else { return "" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

/// What the form submits. `publishAt` is only sent when `includePublishAt`
/// (a published announcement's time can't change).
struct FSAnnouncementDraft {
    enum Banner: Equatable { case unchanged, removed, uploaded(String) }
    /// unchanged = omit the key; reset = explicit null (back to default).
    enum TitleColor: Equatable { case unchanged, reset, set(String) }
    var title: String
    var description: String
    var banner: Banner = .unchanged
    var titleColor: TitleColor = .unchanged
    /// Same shape as `TitleColor` for the allowlisted font / theme keys.
    enum KeyChange: Equatable { case unchanged, reset, set(String) }
    var titleFont: KeyChange = .unchanged
    var bgTheme: KeyChange = .unchanged
    /// Part E. `.unchanged` omits the key; `.clear` sends the server's clear value.
    enum Change<T: Equatable>: Equatable { case unchanged, clear, set(T) }
    var links: Change<[FSAnnouncementLink]> = .unchanged
    var galleryKeys: Change<[String]> = .unchanged
    var isEvent: Change<Bool> = .unchanged
    var paymentHandles: Change<[FSPaymentHandle]> = .unchanged
    var capacity: Change<Int> = .unchanged
    var location: Change<String> = .unchanged
    /// Poll: `.clear` removes it (and its votes); `.set` creates or replaces it.
    var poll: Change<FSPollDraft> = .unchanged
    /// Recurring reminders; `.unchanged` omits every repeat key.
    var repeatChange: AnnouncementRepeatChange = .unchanged
    var includePublishAt: Bool = true
    var publishAt: Date?        // nil + includePublishAt on create = publish now

    var jsonObject: [String: Any] {
        var o: [String: Any] = ["title": title, "description": description]
        switch banner {
        case .unchanged: break
        case .removed: o["banner_key"] = NSNull()
        case .uploaded(let key): o["banner_key"] = key
        }
        switch titleColor {
        case .unchanged: break
        case .reset: o["title_color"] = NSNull()
        case .set(let hex): if AnnouncementTitleColor.isValidHex(hex) { o["title_color"] = hex.uppercased() }
        }
        // Only keys in the client allowlists are ever sent (the server re-validates).
        switch titleFont {
        case .unchanged: break
        case .reset: o["title_font"] = NSNull()
        case .set(let k): if AnnouncementTitleFont(rawValue: k) != nil { o["title_font"] = k }
        }
        switch bgTheme {
        case .unchanged: break
        case .reset: o["bg_theme"] = NSNull()
        case .set(let k): if AnnouncementBgTheme(rawValue: k) != nil { o["bg_theme"] = k }
        }
        switch links {
        case .unchanged: break
        case .clear: o["links"] = [[String: Any]]()
        case .set(let l):
            o["links"] = l.map { link -> [String: Any] in
                var d: [String: Any] = ["url": link.url]
                if let label = link.label, !label.isEmpty { d["label"] = label }
                return d
            }
        }
        switch galleryKeys {
        case .unchanged: break
        case .clear: o["gallery_keys"] = [String]()
        case .set(let k): o["gallery_keys"] = k
        }
        switch isEvent {
        case .unchanged: break
        case .clear: o["is_event"] = false
        case .set(let b): o["is_event"] = b
        }
        switch paymentHandles {
        case .unchanged: break
        case .clear: o["payment_handles"] = [[String: Any]]()
        case .set(let h): o["payment_handles"] = h.map { ["provider": $0.provider, "handle": $0.handle] }
        }
        switch capacity {
        case .unchanged: break
        case .clear: o["capacity"] = NSNull()
        case .set(let n): o["capacity"] = n
        }
        switch location {
        case .unchanged: break
        case .clear: o["location"] = NSNull()
        case .set(let s): o["location"] = s
        }
        switch poll {
        case .unchanged: break
        case .clear: o["poll"] = NSNull()
        case .set(let d): o["poll"] = d.jsonObject
        }
        repeatChange.merge(into: &o)
        if includePublishAt {
            o["publish_at"] = publishAt.map(FSAnnouncementDates.string(from:)) ?? NSNull()
        }
        return o
    }
}
