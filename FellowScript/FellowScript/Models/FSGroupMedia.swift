// FSGroupMedia.swift -- task 20261023-group-info-row. Row of
// GET /groups/{user_id}/{group_id}/media (flag group_media; contract in
// .claude/pipeline/20261023-group-info-row/backend.json). Decoding is
// tolerant: only message_id is required, an unknown kind falls back to image
// so a new server kind can never fail the page.

import Foundation

struct FSGroupMediaItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case image, video, gif }

    let messageId: String
    var kind: Kind
    var thumbURL: String?
    var url: String?
    var width: Int?
    var height: Int?
    /// Seconds, when the sender's client supplied it.
    var duration: Double?
    var senderId: String?
    var senderName: String
    var createdAt: String

    var id: String { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id", kind
        case thumbURL = "thumb_url", url, width, height, duration
        case senderId = "sender_id", senderName = "sender_name", createdAt = "created_at"
    }

    init(messageId: String, kind: Kind = .image, thumbURL: String? = nil, url: String? = nil,
         width: Int? = nil, height: Int? = nil, duration: Double? = nil,
         senderId: String? = nil, senderName: String = "", createdAt: String = "") {
        self.messageId = messageId; self.kind = kind; self.thumbURL = thumbURL; self.url = url
        self.width = width; self.height = height; self.duration = duration
        self.senderId = senderId; self.senderName = senderName; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(String.self, forKey: .messageId)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = raw.flatMap(Kind.init(rawValue:)) ?? .image
        thumbURL = (try? c.decodeIfPresent(String.self, forKey: .thumbURL)) ?? nil
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? nil
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? nil
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? nil
        senderId = (try? c.decodeIfPresent(String.self, forKey: .senderId)) ?? nil
        senderName = ((try? c.decodeIfPresent(String.self, forKey: .senderName)) ?? nil) ?? ""
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil) ?? ""
    }
}

/// One page of media, newest first. Cursor fields are nil when there is no next page.
struct FSGroupMediaPage: Equatable {
    var items: [FSGroupMediaItem]
    var hasMore: Bool
    var cursorTimestamp: String?
    var cursorSeq: Int?
    var cursorId: String?
}

struct FSGroupMediaCursor: Equatable {
    var timestamp: String
    var seq: Int?
    var id: String
}

/// Pure presentation helpers (unit-testable).
enum FSGroupMediaLayout {
    static let pageSize = 30

    /// Grid columns by panel width: under 600pt 3, 600-899pt 4, 900pt and up 5.
    static func columns(forWidth width: CGFloat) -> Int {
        if width >= 900 { return 5 }
        if width >= 600 { return 4 }
        return 3
    }

    /// "1:05" style; nil for missing/zero/invalid durations.
    static func durationText(_ seconds: Double?) -> String? {
        guard let s = seconds, s.isFinite, s > 0 else { return nil }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "Photo from Sam, Oct 19, 2026" (Video / GIF likewise).
    static func accessibilityLabel(_ item: FSGroupMediaItem) -> String {
        let noun: String
        switch item.kind {
        case .image: noun = "Photo"
        case .video: noun = "Video"
        case .gif:   noun = "GIF"
        }
        let who = item.senderName.isEmpty ? "someone" : item.senderName
        let when = FSAnnouncementDates.parse(item.createdAt).map { $0.formatted(date: .abbreviated, time: .omitted) }
        return when.map { "\(noun) from \(who), \($0)" } ?? "\(noun) from \(who)"
    }
}
