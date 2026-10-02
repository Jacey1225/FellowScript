// FSThread.swift — task 20261001-message-threads step 10: thread models, the
// wire-frame -> FSMessage mappers, and the pure policy that decides which
// long-press actions a message offers. Contract: shared-contract-v2 and
// api/routes/threads.py, api/backend/interactions/thread_send.py,
// api/backend/interactions/message_delete.py. Web reference:
// frontend/src/lib/threadsApi.js and ChatThread.jsx (actionsFor).

import Foundation

/// One row of `GET /groups/{u}/{g}/threads` (and the create-thread summary).
/// Decoding is tolerant: only `id` is required; a missing `title` becomes
/// "Thread" and missing counts become 0, so a row can never fail the page.
struct FSThreadSummary: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var rootPreview: String
    /// Present on the create-thread summary; the list rows do not carry it.
    var rootMessageId: String?
    var rootDeleted: Bool
    var replyCount: Int
    var lastActivityAt: String
    var createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case rootPreview    = "root_preview"
        case rootMessageId  = "root_message_id"
        case rootDeleted    = "root_deleted"
        case replyCount     = "reply_count"
        case lastActivityAt = "last_activity_at"
        case createdBy      = "created_by"
    }

    init(id: String, title: String = "Thread", rootPreview: String = "", rootMessageId: String? = nil,
         rootDeleted: Bool = false, replyCount: Int = 0, lastActivityAt: String = "", createdBy: String? = nil) {
        self.id = id
        self.title = title
        self.rootPreview = rootPreview
        self.rootMessageId = rootMessageId
        self.rootDeleted = rootDeleted
        self.replyCount = replyCount
        self.lastActivityAt = lastActivityAt
        self.createdBy = createdBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let t = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        title = (t?.isEmpty == false) ? t! : "Thread"
        rootPreview = ((try? c.decodeIfPresent(String.self, forKey: .rootPreview)) ?? nil) ?? ""
        rootMessageId = (try? c.decodeIfPresent(String.self, forKey: .rootMessageId)) ?? nil
        rootDeleted = ((try? c.decodeIfPresent(Bool.self, forKey: .rootDeleted)) ?? nil) ?? false
        replyCount = ((try? c.decodeIfPresent(Int.self, forKey: .replyCount)) ?? nil) ?? 0
        lastActivityAt = ((try? c.decodeIfPresent(String.self, forKey: .lastActivityAt)) ?? nil) ?? ""
        createdBy = (try? c.decodeIfPresent(String.self, forKey: .createdBy)) ?? nil
    }
}

/// A page of the group's threads (newest activity first).
struct FSThreadsPage {
    let threads: [FSThreadSummary]
    let hasMore: Bool
    /// `{timestamp, id}` keyset cursor (the list has no seq).
    let cursorTimestamp: String?
    let cursorId: String?
}

/// Result of a message delete: the server's undo window.
struct FSMessageDeleteResult: Equatable {
    let id: String
    let undoSeconds: Int
}

// ── Wire frames -> FSMessage ──────────────────────────────────────────────────

extension FSMessage {

    /// Live `{type:"thread_message"}` frame. Carries `sender` (a username, no
    /// id lookup needed), `body` and `created_at` instead of `from_user` /
    /// `text` / `timestamp`. nil when the frame has no id or no thread id.
    init?(threadFrame json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, json["thread_id"] is String else { return nil }
        self.init(id: id,
                  text: (json["body"] as? String) ?? "",
                  mine: false,
                  sender: (json["sender"] as? String) ?? "",
                  timestamp: (json["created_at"] as? String) ?? "",
                  attachmentKind: json["attachment_kind"] as? String,
                  attachmentURL: json["attachment_url"] as? String,
                  attachmentMeta: Self.decodeMeta(json["attachment_meta"]))
    }

    /// Live `{type:"message_restored"}` frame: everything needed to re-insert
    /// the row (sender username, body, created_at, attachment fields).
    init?(restoredFrame json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id,
                  text: (json["body"] as? String) ?? "",
                  mine: false,
                  sender: (json["sender"] as? String) ?? "",
                  timestamp: (json["created_at"] as? String) ?? "",
                  attachmentKind: json["attachment_kind"] as? String,
                  attachmentURL: json["attachment_url"] as? String,
                  attachmentMeta: Self.decodeMeta(json["attachment_meta"]))
    }

    private static func decodeMeta(_ raw: Any?) -> FSAttachmentMeta? {
        guard let dict = raw as? [String: Any], !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(FSAttachmentMeta.self, from: data)
    }

    /// Text a Copy action puts on the pasteboard: the message text; a GIF
    /// copies its URL; image/video/file offer nothing to copy.
    var copyableText: String? {
        if attachmentKind == "gif" {
            let url = attachmentMeta?.url ?? attachmentURL
            return (url?.isEmpty == false) ? url : nil
        }
        if let kind = attachmentKind, !kind.isEmpty { return nil }
        return text.isEmpty ? nil : text
    }
}

// ── Long-press action policy ──────────────────────────────────────────────────

enum FSMessageActionKind: String, Equatable {
    case startThread, copy, delete, report, block

    var title: String {
        switch self {
        case .startThread: return "Start thread"
        case .copy:        return "Copy"
        case .delete:      return "Delete"
        case .report:      return "Report"
        case .block:       return "Block user"
        }
    }

    var systemImage: String {
        switch self {
        case .startThread: return "bubble.left.and.bubble.right"
        case .copy:        return "doc.on.doc"
        case .delete:      return "trash"
        case .report:      return "exclamationmark.bubble"
        case .block:       return "hand.raised"
        }
    }

    var isDestructive: Bool { self == .delete || self == .block }
}

/// Where a message is shown and what the caller is allowed to do. Pure value
/// so the rules are unit-testable without a view.
struct FSMessageActionContext: Equatable {
    var isGroup: Bool
    var inThread: Bool
    var threadsEnabled: Bool
    var messageDeleteEnabled: Bool
    /// True once the message has a server id (acked or fetched) and is not a
    /// failed/in-flight optimistic echo.
    var isSettled: Bool
    /// The other participant's user id when it can be resolved (a group member
    /// by username, or the DM contact); nil hides Report/Block.
    var senderUserId: String?
}

enum FSMessageActionPolicy {
    /// Menu items for `message`, in display order.
    ///  - thread message: Copy only (there is no delete route for them);
    ///  - main-chat message in a group, own: Start thread (threads on),
    ///    Copy, Delete (message_delete on);
    ///  - main-chat message in a group, others': Copy, Start thread (threads
    ///    on), Report, Block (sender resolvable);
    ///  - DM: Copy only.
    /// Copy is omitted when there is nothing to copy (image/video/file).
    static func actions(for message: FSMessage, in ctx: FSMessageActionContext) -> [FSMessageActionKind] {
        var list: [FSMessageActionKind] = []
        let canThread = !ctx.inThread && ctx.isGroup && ctx.threadsEnabled && ctx.isSettled
        let canCopy = message.copyableText != nil
        if message.mine {
            if canThread { list.append(.startThread) }
            if canCopy { list.append(.copy) }
            if !ctx.inThread && ctx.isGroup && ctx.messageDeleteEnabled && ctx.isSettled {
                list.append(.delete)
            }
        } else {
            if canCopy { list.append(.copy) }
            if canThread { list.append(.startThread) }
            if !ctx.inThread && ctx.isGroup && ctx.isSettled && ctx.senderUserId != nil {
                list.append(.report)
                list.append(.block)
            }
        }
        return list
    }

    /// Relative time for a thread row ("just now", "5m ago", "3h ago", "2d ago",
    /// else a short date). Mirrors threadsApi.js relativeTime.
    static func relativeTime(_ iso: String, now: Date = Date()) -> String {
        guard let date = parseFlexibleISO8601(iso) else { return "" }
        let s = max(0, Int(now.timeIntervalSince(date).rounded()))
        if s < 60 { return "just now" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m)m ago" }
        let h = Int((Double(m) / 60).rounded())
        if h < 24 { return "\(h)h ago" }
        let d = Int((Double(h) / 24).rounded())
        if d < 30 { return "\(d)d ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

/// Insert a restored (or rolled-back) message at its time position. A row
/// whose id is already present is not inserted twice; a row that cannot be
/// placed goes to the end. Mirrors threadsApi.js insertRestored.
func fsInsertRestored(_ current: [FSMessage], _ message: FSMessage) -> [FSMessage] {
    if current.contains(where: { $0.id == message.id }) { return current }
    guard let t = parseFlexibleISO8601(message.timestamp) else { return current + [message] }
    if let idx = current.firstIndex(where: { m in
        if let mt = parseFlexibleISO8601(m.timestamp) { return mt > t }
        return false
    }) {
        var copy = current
        copy.insert(message, at: idx)
        return copy
    }
    return current + [message]
}
