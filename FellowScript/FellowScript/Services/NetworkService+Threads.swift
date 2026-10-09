// NetworkService+Threads.swift — task 20261001-message-threads step 10.
// Clients for the thread routes (api/routes/threads.py) and message
// delete/undo routes (api/routes/messages_delete.py). Behavioural reference:
// frontend/src/lib/threadsApi.js.
//
// Throw-not-fabricate: every method throws FSThreadsError on any non-2xx,
// transport error, or undecodable body; callers keep what they already show
// (preserve-cache-on-failed-refresh) and surface the error. The error carries
// the server's machine `code` (terms_reaccept_required, thread_limit) so the
// UI can branch without sniffing message text.

import Foundation

enum FSThreadsError: LocalizedError, Equatable {
    case termsReacceptRequired
    case threadLimit
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .termsReacceptRequired: return "Please review and accept the updated Terms to continue."
        case .threadLimit:           return "This group has reached its thread limit."
        case .notFound:              return "That message or thread is no longer available."
        case .failed(let m):         return m
        }
    }
}

private struct CreateThreadBody: Encodable { let message_id: String }
private struct RenameThreadBody: Encodable { let title: String }
private struct DeleteResponse: Decodable { let id: String; let undo_seconds: Int? }
private struct ThreadsListResponse: Decodable {
    let threads: [FSThreadSummary]?
    let page: RawPage?
}

extension NetworkService {

    static let defaultUndoSeconds = 10

    private func threadsBase(_ userId: String, _ groupId: String) -> String {
        "/groups/\(encodeURIComponent(userId))/\(encodeURIComponent(groupId))"
    }

    /// Maps a non-2xx response to FSThreadsError.
    private func threadsError(status: Int, data: Data, fallback: String) -> FSThreadsError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var code: String? = nil
        var message: String? = nil
        if let detail = body?["detail"] as? [String: Any] {
            code = detail["code"] as? String
            message = detail["message"] as? String
        } else if let detail = body?["detail"] as? String {
            message = detail
        }
        if status == 403, code == "terms_reaccept_required" { return .termsReacceptRequired }
        if status == 409, code == "thread_limit" { return .threadLimit }
        if status == 404 { return .notFound }
        return .failed(message ?? fallback)
    }

    private func threadsSend(_ path: String, method: String, body: Encodable? = nil,
                             fallback: String) async throws -> Data {
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
        guard let http = response as? HTTPURLResponse else { throw FSThreadsError.failed(fallback) }
        guard (200..<300).contains(http.statusCode) else {
            throw threadsError(status: http.statusCode, data: data, fallback: fallback)
        }
        return data
    }

    // GET /groups/{u}/{g}/threads?limit=&cursor_timestamp=&cursor_id=
    func fetchThreads(userId: String, groupId: String, limit: Int, cursorTimestamp: String?, cursorId: String?) async throws -> FSThreadsPage {
        var query = "limit=\(limit)"
        if let ts = cursorTimestamp, let id = cursorId {
            query += "&cursor_timestamp=\(encodeURIComponent(ts))&cursor_id=\(encodeURIComponent(id))"
        }
        let (data, response) = try await getRawResponseMappingErrors("\(threadsBase(userId, groupId))/threads?\(query)")
        _ = response
        guard let resp = decode(ThreadsListResponse.self, from: data, endpoint: "/groups/{id}/{id}/threads"),
              let rows = resp.threads else {
            throw FSThreadsError.failed("Couldn't load threads.")
        }
        let page = resp.page
        let hasMore = page?.has_more == true && page?.next_cursor_timestamp != nil && page?.next_cursor_id != nil
        return FSThreadsPage(threads: rows, hasMore: hasMore,
                             cursorTimestamp: hasMore ? page?.next_cursor_timestamp : nil,
                             cursorId: hasMore ? page?.next_cursor_id : nil)
    }

    private func getRawResponseMappingErrors(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await getRawResponse(path)
        } catch {
            throw FSThreadsError.failed("Could not reach the server.")
        }
        guard let http = response as? HTTPURLResponse else { throw FSThreadsError.failed("Couldn't load threads.") }
        guard (200..<300).contains(http.statusCode) else {
            throw threadsError(status: http.statusCode, data: data, fallback: "Couldn't load threads.")
        }
        return (data, http)
    }

    // POST /groups/{u}/{g}/threads  body {message_id} -> summary (201 created, 200 existing)
    func createThread(userId: String, groupId: String, messageId: String) async throws -> FSThreadSummary {
        let data = try await threadsSend("\(threadsBase(userId, groupId))/threads", method: "POST",
                                         body: CreateThreadBody(message_id: messageId),
                                         fallback: "Couldn't start a thread on that message.")
        guard let summary = decode(FSThreadSummary.self, from: data, endpoint: "/groups/{id}/{id}/threads") else {
            throw FSThreadsError.failed("Couldn't start a thread on that message.")
        }
        return summary
    }

    // GET /groups/{u}/{g}/threads/{t}/messages?limit=&cursor_timestamp=&cursor_seq=&cursor_id=
    // Same page envelope and row shape as the main chat; throws on any failure
    // (no fabricated empty thread), the caller shows a retry control.
    func fetchThreadMessages(userId: String, groupId: String, threadId: String, limit: Int, cursor: FSMessageCursor?) async throws -> FSMessagePage {
        var query = "limit=\(limit)"
        if let cursor {
            query += "&cursor_timestamp=\(encodeURIComponent(cursor.timestamp))"
            if let seq = cursor.seq { query += "&cursor_seq=\(seq)" }
            query += "&cursor_id=\(encodeURIComponent(cursor.id))"
        }
        let path = "\(threadsBase(userId, groupId))/threads/\(encodeURIComponent(threadId))/messages?\(query)"
        let data: Data
        do {
            let (d, _) = try await getRawResponseMappingErrors(path)
            data = d
        } catch let e as FSThreadsError where e == .notFound {
            throw e
        } catch {
            throw FSThreadsError.failed("Couldn't load this thread.")
        }
        guard let page = parsePage(data: data) else {
            throw FSThreadsError.failed("Couldn't load this thread.")
        }
        return page
    }

    // PUT /groups/{u}/{g}/threads/{t}  body {title} -> summary (creator only; 404 otherwise)
    func renameThread(userId: String, groupId: String, threadId: String, title: String) async throws -> FSThreadSummary {
        let data = try await threadsSend("\(threadsBase(userId, groupId))/threads/\(encodeURIComponent(threadId))",
                                         method: "PUT", body: RenameThreadBody(title: title),
                                         fallback: "Couldn't rename that thread. Please try again.")
        guard let summary = decode(FSThreadSummary.self, from: data, endpoint: "/groups/{id}/{id}/threads/{id}") else {
            throw FSThreadsError.failed("Couldn't rename that thread. Please try again.")
        }
        return summary
    }

    // DELETE /groups/{u}/{g}/threads/{t} -> 204 (creator or group owner; hard delete; 404 otherwise)
    func deleteThread(userId: String, groupId: String, threadId: String) async throws {
        _ = try await threadsSend("\(threadsBase(userId, groupId))/threads/\(encodeURIComponent(threadId))",
                                  method: "DELETE", fallback: "Couldn't delete that thread. Please try again.")
    }

    // DELETE /groups/{u}/{g}/messages/{m} -> {id, undo_seconds}
    func deleteGroupMessage(userId: String, groupId: String, messageId: String) async throws -> FSMessageDeleteResult {
        let data = try await threadsSend("\(threadsBase(userId, groupId))/messages/\(encodeURIComponent(messageId))",
                                         method: "DELETE", fallback: "Couldn't delete that message. Please try again.")
        guard let resp = decode(DeleteResponse.self, from: data, endpoint: "/groups/{id}/{id}/messages/{id}") else {
            throw FSThreadsError.failed("Couldn't delete that message. Please try again.")
        }
        return FSMessageDeleteResult(id: resp.id, undoSeconds: resp.undo_seconds ?? Self.defaultUndoSeconds)
    }

    // POST /groups/{u}/{g}/messages/{m}/restore -> {id}
    func restoreGroupMessage(userId: String, groupId: String, messageId: String) async throws {
        _ = try await threadsSend("\(threadsBase(userId, groupId))/messages/\(encodeURIComponent(messageId))/restore",
                                  method: "POST", fallback: "Couldn't undo that delete.")
    }
}

// Default implementations so existing conformers (MockDataService, test
// doubles) keep compiling. They throw rather than invent data; only
// NetworkService talks to the real endpoints.
extension DataServiceProtocol {
    private var threadsUnsupported: FSThreadsError { .failed("Threads aren't available right now.") }

    func fetchThreads(userId: String, groupId: String, limit: Int, cursorTimestamp: String?, cursorId: String?) async throws -> FSThreadsPage {
        throw threadsUnsupported
    }
    func createThread(userId: String, groupId: String, messageId: String) async throws -> FSThreadSummary {
        throw threadsUnsupported
    }
    func fetchThreadMessages(userId: String, groupId: String, threadId: String, limit: Int, cursor: FSMessageCursor?) async throws -> FSMessagePage {
        throw threadsUnsupported
    }
    func renameThread(userId: String, groupId: String, threadId: String, title: String) async throws -> FSThreadSummary {
        throw threadsUnsupported
    }
    func deleteThread(userId: String, groupId: String, threadId: String) async throws {
        throw threadsUnsupported
    }
    func deleteGroupMessage(userId: String, groupId: String, messageId: String) async throws -> FSMessageDeleteResult {
        throw FSThreadsError.failed("Couldn't delete that message. Please try again.")
    }
    func restoreGroupMessage(userId: String, groupId: String, messageId: String) async throws {
        throw FSThreadsError.failed("Couldn't undo that delete.")
    }
}
