// NetworkService+Pins.swift -- task 20261012-message-pins.
// POST/DELETE /message-pins/{user_id}/{message_id} and
// GET /message-pins/{user_id}/group/{group_id} | /dm/{friend_id}?limit&offset
// (api/routes/message_pins.py).
// Throw-not-fabricate: any non-2xx, transport error or undecodable body throws
// FSPinError; callers roll back optimistic changes. The server answers
// flag-off, non-member, blocked and deleted with one uniform 404 (.unavailable).

import Foundation

enum FSPinError: LocalizedError, Equatable {
    case unavailable
    case termsReacceptRequired
    case rateLimited
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:           return "That message is no longer available."
        case .termsReacceptRequired: return "Please review and accept the updated Terms to continue."
        case .rateLimited:           return "Easy there. Give it a moment and try again."
        case .failed(let m):         return m
        }
    }

    static let fallback = "That didn't go through. Please try again."
}

/// The message half of one pin row (server-clipped preview, never full text).
nonisolated struct FSPinnedMessageBody: Decodable, Equatable {
    var id: String
    var fromUserId: String
    var fromUser: String
    var text: String
    var timestamp: String
    var attachmentKind: String?

    private enum CodingKeys: String, CodingKey {
        case id, text, timestamp
        case fromUserId = "from_user_id", fromUser = "from_user", attachmentKind = "attachment_kind"
    }

    init(id: String, fromUserId: String = "", fromUser: String = "", text: String = "",
         timestamp: String = "", attachmentKind: String? = nil) {
        self.id = id; self.fromUserId = fromUserId; self.fromUser = fromUser
        self.text = text; self.timestamp = timestamp; self.attachmentKind = attachmentKind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fromUserId = (try? c.decodeIfPresent(String.self, forKey: .fromUserId)) ?? ""
        fromUser = (try? c.decodeIfPresent(String.self, forKey: .fromUser)) ?? ""
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        timestamp = (try? c.decodeIfPresent(String.self, forKey: .timestamp)) ?? ""
        attachmentKind = try? c.decodeIfPresent(String.self, forKey: .attachmentKind)
    }
}

nonisolated struct FSPinnedMessage: Decodable, Equatable, Identifiable {
    var messageId: String
    var pinnedById: String
    var pinnedBy: String
    var pinnedAt: String?
    var message: FSPinnedMessageBody

    var id: String { messageId }

    private enum CodingKeys: String, CodingKey {
        case message
        case messageId = "message_id", pinnedById = "pinned_by_id", pinnedBy = "pinned_by", pinnedAt = "pinned_at"
    }

    init(messageId: String, pinnedById: String = "", pinnedBy: String = "", pinnedAt: String? = nil,
         message: FSPinnedMessageBody) {
        self.messageId = messageId; self.pinnedById = pinnedById; self.pinnedBy = pinnedBy
        self.pinnedAt = pinnedAt; self.message = message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(String.self, forKey: .messageId)
        message = try c.decode(FSPinnedMessageBody.self, forKey: .message)
        pinnedById = (try? c.decodeIfPresent(String.self, forKey: .pinnedById)) ?? ""
        pinnedBy = (try? c.decodeIfPresent(String.self, forKey: .pinnedBy)) ?? ""
        pinnedAt = try? c.decodeIfPresent(String.self, forKey: .pinnedAt)
    }

    /// One short visible line: the clipped text, else the attachment label.
    var previewText: String {
        let t = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        switch message.attachmentKind.flatMap(FSAttachmentKind.init(rawValue:)) {
        case .image: return "Photo"
        case .video: return "Video"
        case .gif:   return "GIF"
        case .file:  return "File"
        case nil:    return "Message"
        }
    }
}

/// One page of `{pins, has_more, count}`. `count` is the chat's total pins.
nonisolated struct FSPinPage: Decodable, Equatable {
    var pins: [FSPinnedMessage]
    var hasMore: Bool
    var count: Int

    private enum CodingKeys: String, CodingKey { case pins, hasMore = "has_more", count }

    init(pins: [FSPinnedMessage], hasMore: Bool, count: Int) {
        self.pins = pins; self.hasMore = hasMore; self.count = count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pins = try c.decode([FSPinnedMessage].self, forKey: .pins)
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? pins.count
    }
}

extension NetworkService {

    /// Maps a non-2xx status to the error. Pure so it is unit-testable.
    static func pinError(status: Int, data: Data) -> FSPinError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var code: String? = nil
        if let detail = body?["detail"] as? [String: Any] { code = detail["code"] as? String }
        switch status {
        case 404: return .unavailable
        case 429: return .rateLimited
        case 403 where code == "terms_reaccept_required": return .termsReacceptRequired
        default:  return .failed(FSPinError.fallback)
        }
    }

    private func pinRequest(_ path: String, method: String) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw FSPinError.failed("Could not reach the server.")
        }
        guard let http = response as? HTTPURLResponse else { throw FSPinError.failed(FSPinError.fallback) }
        guard (200..<300).contains(http.statusCode) else { throw Self.pinError(status: http.statusCode, data: data) }
        return data
    }

    // POST /message-pins/{user_id}/{message_id} -> {message_id, pinned: true}
    func pinMessage(userId: String, messageId: String) async throws {
        _ = try await pinRequest("/message-pins/\(encodeURIComponent(userId))/\(encodeURIComponent(messageId))", method: "POST")
    }

    // DELETE /message-pins/{user_id}/{message_id} -> {message_id, pinned: false}
    func unpinMessage(userId: String, messageId: String) async throws {
        _ = try await pinRequest("/message-pins/\(encodeURIComponent(userId))/\(encodeURIComponent(messageId))", method: "DELETE")
    }

    func fetchPins(userId: String, contactId: String, isGroup: Bool, limit: Int, offset: Int) async throws -> FSPinPage {
        let scope = isGroup ? "group" : "dm"
        let path = "/message-pins/\(encodeURIComponent(userId))/\(scope)/\(encodeURIComponent(contactId))?limit=\(limit)&offset=\(offset)"
        let data = try await pinRequest(path, method: "GET")
        guard let page = try? JSONDecoder().decode(FSPinPage.self, from: data) else {
            throw FSPinError.failed("Couldn't load pinned messages. Try again?")
        }
        return page
    }
}

// Default implementations so existing conformers (MockDataService, test
// doubles) keep compiling. They throw rather than invent data.
extension DataServiceProtocol {
    func pinMessage(userId: String, messageId: String) async throws {
        throw FSPinError.failed("Pinned messages aren't available right now.")
    }
    func unpinMessage(userId: String, messageId: String) async throws {
        throw FSPinError.failed("Pinned messages aren't available right now.")
    }
    func fetchPins(userId: String, contactId: String, isGroup: Bool, limit: Int, offset: Int) async throws -> FSPinPage {
        throw FSPinError.failed("Pinned messages aren't available right now.")
    }
}
