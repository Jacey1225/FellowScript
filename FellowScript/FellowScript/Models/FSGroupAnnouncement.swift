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
}

struct FSAnnouncementsPage: Codable, Equatable {
    var announcements: [FSGroupAnnouncement]
    var truncated:     Bool?
    var gate:          FSAnnouncementGate?
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
    var title: String
    var description: String
    var banner: Banner = .unchanged
    var includePublishAt: Bool = true
    var publishAt: Date?        // nil + includePublishAt on create = publish now

    var jsonObject: [String: Any] {
        var o: [String: Any] = ["title": title, "description": description]
        switch banner {
        case .unchanged: break
        case .removed: o["banner_key"] = NSNull()
        case .uploaded(let key): o["banner_key"] = key
        }
        if includePublishAt {
            o["publish_at"] = publishAt.map(FSAnnouncementDates.string(from:)) ?? NSNull()
        }
        return o
    }
}
