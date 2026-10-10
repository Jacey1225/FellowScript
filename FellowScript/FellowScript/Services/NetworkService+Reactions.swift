// NetworkService+Reactions.swift -- task 20261010-chat-reactions.
// POST/DELETE /message-reactions/{user_id}/{message_id} (api/routes/message_reactions.py).
// Throw-not-fabricate: any non-2xx, transport error or undecodable body throws
// FSReactionError; the caller rolls back its optimistic change and shows it.
// The server answers flag-off, non-member, blocked and deleted with one
// uniform 404, which maps to .unavailable.

import Foundation

enum FSReactionError: LocalizedError, Equatable {
    case unavailable
    case termsReacceptRequired
    case limitReached
    case rateLimited
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:           return "That message can't be reacted to anymore."
        case .termsReacceptRequired: return "Please review and accept the updated Terms to continue."
        case .limitReached:          return "This message has reached its reaction limit."
        case .rateLimited:           return "You're reacting too quickly. Please wait a moment."
        case .failed(let m):         return m
        }
    }
}

private struct ReactionBody: Encodable { let emoji: String }

extension NetworkService {

    private func reactionSend(messageId: String, userId: String, method: String, emoji: String) async throws -> ReactionSummary {
        var path = "/message-reactions/\(encodeURIComponent(userId))/\(encodeURIComponent(messageId))"
        if method == "DELETE" { path += "?emoji=\(encodeURIComponent(emoji))" }
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(ReactionBody(emoji: emoji))
        }
        let fallback = "Couldn't update your reaction. Please try again."
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw FSReactionError.failed("Could not reach the server.")
        }
        guard let http = response as? HTTPURLResponse else { throw FSReactionError.failed(fallback) }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            var code: String? = nil
            if let detail = body?["detail"] as? [String: Any] { code = detail["code"] as? String }
            switch http.statusCode {
            case 404: throw FSReactionError.unavailable
            case 429: throw FSReactionError.rateLimited
            case 403 where code == "terms_reaccept_required": throw FSReactionError.termsReacceptRequired
            case 409: throw FSReactionError.limitReached
            default:  throw FSReactionError.failed(fallback)
            }
        }
        guard let result = try? JSONDecoder().decode(ReactionSummary.self, from: data) else {
            throw FSReactionError.failed(fallback)
        }
        return result
    }

    // POST /message-reactions/{user_id}/{message_id}  body {emoji} -> {emoji, count, viewer_reacted}
    func addMessageReaction(userId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        try await reactionSend(messageId: messageId, userId: userId, method: "POST", emoji: emoji)
    }

    // DELETE /message-reactions/{user_id}/{message_id}?emoji= -> {emoji, count, viewer_reacted}
    func removeMessageReaction(userId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        try await reactionSend(messageId: messageId, userId: userId, method: "DELETE", emoji: emoji)
    }
}

// Default implementations so existing conformers (MockDataService, test
// doubles) keep compiling. They throw rather than invent data.
extension DataServiceProtocol {
    func addMessageReaction(userId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        throw FSReactionError.failed("Reactions aren't available right now.")
    }
    func removeMessageReaction(userId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        throw FSReactionError.failed("Reactions aren't available right now.")
    }
}
