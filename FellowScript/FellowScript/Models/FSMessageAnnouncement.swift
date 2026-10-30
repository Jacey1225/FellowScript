// FSMessageAnnouncement.swift -- task 20261030-chat-announcements.
// The announcement card a timeline line carries (system_kind "announcement").
// History rows carry the viewer's serialized announcement; a live frame carries
// a viewer-neutral card with fewer keys, so every field except id/title is
// optional and decoding never throws: a line whose card is unusable simply has
// no card and renders as the plain system line (never a placeholder). The full
// announcement (RSVP, polls, can_edit) is always re-fetched on tap.

import Foundation

nonisolated struct FSMessageAnnouncement: Codable, Equatable {
    let id: String
    var title: String
    var description: String
    var banner_url: String?
    var creator_username: String?
    var title_color: String?
    var title_font: String?
    var bg_theme: String?
    var publish_at: String?
    var created_at: String?
    var updated_at: String?
    /// Server-derived (updated_at later than created_at); absent in old payloads.
    var edited: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, title, description, banner_url, creator_username, title_color, title_font,
             bg_theme, publish_at, created_at, updated_at, edited
    }

    init(id: String, title: String, description: String = "", banner_url: String? = nil,
         creator_username: String? = nil, title_color: String? = nil, title_font: String? = nil,
         bg_theme: String? = nil, publish_at: String? = nil, created_at: String? = nil,
         updated_at: String? = nil, edited: Bool? = nil) {
        self.id = id; self.title = title; self.description = description; self.banner_url = banner_url
        self.creator_username = creator_username; self.title_color = title_color
        self.title_font = title_font; self.bg_theme = bg_theme; self.publish_at = publish_at
        self.created_at = created_at; self.updated_at = updated_at; self.edited = edited
    }

    /// Throws only when id or title is missing (the caller treats that as "no card").
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        banner_url = try? c.decodeIfPresent(String.self, forKey: .banner_url)
        creator_username = try? c.decodeIfPresent(String.self, forKey: .creator_username)
        title_color = try? c.decodeIfPresent(String.self, forKey: .title_color)
        title_font = try? c.decodeIfPresent(String.self, forKey: .title_font)
        bg_theme = try? c.decodeIfPresent(String.self, forKey: .bg_theme)
        publish_at = try? c.decodeIfPresent(String.self, forKey: .publish_at)
        created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try? c.decodeIfPresent(String.self, forKey: .updated_at)
        edited = try? c.decodeIfPresent(Bool.self, forKey: .edited)
    }

    /// Parses the `announcement` object of a live frame. nil when absent or unusable.
    static func parse(_ raw: Any?) -> FSMessageAnnouncement? {
        guard let dict = raw as? [String: Any], JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(FSMessageAnnouncement.self, from: data)
    }

    /// Adapter so the shared card face (AnnouncementWidgetCardBody) renders the
    /// line. Structural defaults only (published, not editable); no content is invented.
    func cardItem(groupId: String) -> FSGroupAnnouncement {
        let now = publish_at ?? created_at ?? ""
        return FSGroupAnnouncement(
            id: id, group_id: groupId, creator_id: nil, creator_username: creator_username,
            title: title, description: description, banner_url: banner_url,
            publish_at: now, created_at: created_at ?? now, updated_at: updated_at ?? now,
            published: true, can_edit: false,
            title_color: title_color, title_font: title_font, bg_theme: bg_theme)
    }
}

/// Never-throwing wrapper for use inside RawMsg: a malformed `announcement`
/// key must not cost the user the whole message list.
nonisolated struct FSLenientAnnouncement: Decodable {
    let value: FSMessageAnnouncement?
    init(from decoder: Decoder) throws { value = try? FSMessageAnnouncement(from: decoder) }
}

/// Live `announcement_updated` frame (action updated / deleted / restored).
nonisolated struct FSAnnouncementSync: Equatable {
    enum Action: String { case updated, deleted, restored }
    let announcementId: String
    let action: Action

    init?(frame: [String: Any]) {
        guard let id = frame["announcement_id"] as? String, !id.isEmpty,
              let raw = frame["action"] as? String, let action = Action(rawValue: raw) else { return nil }
        announcementId = id
        self.action = action
    }
}

extension Array where Element == FSMessage {
    /// Drops the timeline line(s) of a deleted announcement (restore re-fetches history).
    mutating func removeAnnouncementLines(announcementId: String) {
        removeAll { $0.announcement?.id == announcementId }
    }
}
