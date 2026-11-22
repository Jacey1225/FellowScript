// NetworkService+ThreadActions.swift -- task 20261122-app-fixes-threads-widget (item 2).
// Reactions and pins on THREAD messages (api/routes/threads.py:
// .../threads/{t}/messages/{m}/reactions and .../pin). Thread messages live in
// their own table, so the main-chat /message-reactions and /message-pins routes
// do not accept them. Throw-not-fabricate: any non-2xx, transport error or
// undecodable body throws FSReactionError / FSPinError (same cases the main chat
// uses), so the caller rolls back its optimistic change and shows it. The server
// answers flag-off, non-member, blocked and unknown with one uniform 404.

import Foundation

private struct ThreadReactionBody: Encodable { let emoji: String }

extension NetworkService {

    private func threadActionPath(_ userId: String, _ groupId: String, _ threadId: String, _ messageId: String, _ leaf: String) -> String {
        "/groups/\(encodeURIComponent(userId))/\(encodeURIComponent(groupId))/threads/\(encodeURIComponent(threadId))/messages/\(encodeURIComponent(messageId))/\(leaf)"
    }

    /// Raw send; returns (status, data) and throws only on transport failure.
    private func threadActionSend(_ path: String, method: String, body: Encodable?) async throws -> (Int, Data) {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw FSThreadsError.failed("Could not reach the server.")
        }
        guard let http = response as? HTTPURLResponse else { throw FSThreadsError.failed("Something went wrong. Please try again.") }
        return (http.statusCode, data)
    }

    private func threadReactionSend(_ userId: String, _ groupId: String, _ threadId: String, _ messageId: String,
                                    method: String, emoji: String) async throws -> ReactionSummary {
        var path = threadActionPath(userId, groupId, threadId, messageId, "reactions")
        if method == "DELETE" { path += "?emoji=\(encodeURIComponent(emoji))" }
        let fallback = "Couldn't update your reaction. Please try again."
        let status: Int
        let data: Data
        do {
            (status, data) = try await threadActionSend(path, method: method,
                                                        body: method == "POST" ? ThreadReactionBody(emoji: emoji) : nil)
        } catch {
            throw FSReactionError.failed("Could not reach the server.")
        }
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            var code: String? = nil
            if let detail = body?["detail"] as? [String: Any] { code = detail["code"] as? String }
            switch status {
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

    private func threadPinSend(_ userId: String, _ groupId: String, _ threadId: String, _ messageId: String,
                               method: String) async throws {
        let status: Int
        let data: Data
        do {
            (status, data) = try await threadActionSend(threadActionPath(userId, groupId, threadId, messageId, "pin"),
                                                        method: method, body: nil)
        } catch {
            throw FSPinError.failed("Could not reach the server.")
        }
        guard (200..<300).contains(status) else { throw Self.pinError(status: status, data: data) }
    }

    // POST .../threads/{t}/messages/{m}/reactions  body {emoji} -> {emoji, count, viewer_reacted}
    func addThreadMessageReaction(userId: String, groupId: String, threadId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        try await threadReactionSend(userId, groupId, threadId, messageId, method: "POST", emoji: emoji)
    }

    // DELETE .../threads/{t}/messages/{m}/reactions?emoji= -> {emoji, count, viewer_reacted}
    func removeThreadMessageReaction(userId: String, groupId: String, threadId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        try await threadReactionSend(userId, groupId, threadId, messageId, method: "DELETE", emoji: emoji)
    }

    // POST / DELETE .../threads/{t}/messages/{m}/pin -> {message_id, thread_id, pinned}
    func pinThreadMessage(userId: String, groupId: String, threadId: String, messageId: String) async throws {
        try await threadPinSend(userId, groupId, threadId, messageId, method: "POST")
    }
    func unpinThreadMessage(userId: String, groupId: String, threadId: String, messageId: String) async throws {
        try await threadPinSend(userId, groupId, threadId, messageId, method: "DELETE")
    }
}

// Defaults so existing conformers keep compiling; they throw rather than invent data.
extension DataServiceProtocol {
    func addThreadMessageReaction(userId: String, groupId: String, threadId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        throw FSReactionError.failed("Reactions aren't available right now.")
    }
    func removeThreadMessageReaction(userId: String, groupId: String, threadId: String, messageId: String, emoji: String) async throws -> ReactionSummary {
        throw FSReactionError.failed("Reactions aren't available right now.")
    }
    func pinThreadMessage(userId: String, groupId: String, threadId: String, messageId: String) async throws {
        throw FSPinError.failed("Pinned messages aren't available right now.")
    }
    func unpinThreadMessage(userId: String, groupId: String, threadId: String, messageId: String) async throws {
        throw FSPinError.failed("Pinned messages aren't available right now.")
    }
}
