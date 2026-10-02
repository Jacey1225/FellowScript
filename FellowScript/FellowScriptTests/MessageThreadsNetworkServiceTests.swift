// MessageThreadsNetworkServiceTests.swift -- task 20261001-message-threads,
// testing step 11. Exercises the REAL NetworkService thread / delete / restore
// clients through a recording URLProtocol stub: routes, query + body shape,
// decoding (tolerant rows, page cursor), and throw-not-fabricate errors
// including terms_reaccept_required, thread_limit and 404.

import XCTest
@testable import FellowScript

final class ThreadsStubURLProtocol: URLProtocol {
    struct Req { let method: String; let url: String; let path: String; let body: Data? }
    static var active = false
    /// "METHOD path" (no query) -> (status, body). Unlisted routes 404.
    static var routes: [String: (Int, String)] = [:]
    static var log: [Req] = []
    static func reset() { routes = [:]; log = [] }

    override class func canInit(with request: URLRequest) -> Bool { active && request.url?.host == "fellowscript.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            body = data
        }
        let method = request.httpMethod ?? "GET"
        Self.log.append(Req(method: method, url: url.absoluteString, path: url.path, body: body))
        let route = Self.routes["\(method) \(url.path)"] ?? (404, #"{"detail":"nf"}"#)
        let resp = HTTPURLResponse(url: url, statusCode: route.0, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.1.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MessageThreadsNetworkServiceTests: XCTestCase {

    override func setUp() {
        ThreadsStubURLProtocol.reset()
        ThreadsStubURLProtocol.active = true
        URLProtocol.registerClass(ThreadsStubURLProtocol.self)
    }
    override func tearDown() {
        ThreadsStubURLProtocol.active = false
        URLProtocol.unregisterClass(ThreadsStubURLProtocol.self)
    }

    private let svc = NetworkService.shared
    private let base = "/api/groups/u1/g1"

    private func expectError(_ expected: FSThreadsError, file: StaticString = #filePath, line: UInt = #line,
                             _ op: () async throws -> Void) async {
        do { try await op(); XCTFail("must throw", file: file, line: line) }
        catch let e as FSThreadsError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("wrong error type: \(error)", file: file, line: line) }
    }

    // MARK: list threads

    func test_fetchThreads_decodesRows_andKeysetCursor_andQuery() async throws {
        ThreadsStubURLProtocol.routes["GET \(base)/threads"] = (200, """
        {"threads":[
          {"id":"t1","title":"Plan","root_preview":"hello","root_deleted":false,"reply_count":3,
           "last_activity_at":"2026-10-01T10:00:00+00:00","created_by":"alice"},
          {"id":"t2"}],
         "page":{"limit":2,"has_more":true,"next_cursor_timestamp":"2026-10-01T09:00:00+00:00","next_cursor_id":"t2"}}
        """)
        let page = try await svc.fetchThreads(userId: "u1", groupId: "g1", limit: 2,
                                              cursorTimestamp: "2026-10-02T10:00:00+00:00", cursorId: "t0")
        XCTAssertEqual(page.threads.map(\.id), ["t1", "t2"])
        XCTAssertEqual(page.threads[0].title, "Plan")
        XCTAssertEqual(page.threads[0].replyCount, 3)
        XCTAssertEqual(page.threads[0].rootPreview, "hello")
        // tolerant row: only id present
        XCTAssertEqual(page.threads[1].title, "Thread")
        XCTAssertEqual(page.threads[1].replyCount, 0)
        XCTAssertFalse(page.threads[1].rootDeleted)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.cursorTimestamp, "2026-10-01T09:00:00+00:00")
        XCTAssertEqual(page.cursorId, "t2")
        let url = ThreadsStubURLProtocol.log.last!.url
        XCTAssertTrue(url.contains("limit=2"))
        XCTAssertTrue(url.contains("cursor_timestamp=2026-10-02T10:00:00%2B00:00"), "'+' must be percent-encoded: \(url)")
        XCTAssertTrue(url.contains("cursor_id=t0"))
    }

    func test_fetchThreads_noCursorParams_onFirstPage_andHasMoreWithoutCursorIsEnd() async throws {
        ThreadsStubURLProtocol.routes["GET \(base)/threads"] =
            (200, #"{"threads":[{"id":"a"}],"page":{"has_more":true}}"#)
        let page = try await svc.fetchThreads(userId: "u1", groupId: "g1", limit: 20, cursorTimestamp: nil, cursorId: nil)
        XCTAssertFalse(ThreadsStubURLProtocol.log.last!.url.contains("cursor"))
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.cursorId)
    }

    func test_fetchThreads_throwsOnHttpErrorAndMalformedBody_neverEmptyList() async {
        ThreadsStubURLProtocol.routes["GET \(base)/threads"] = (500, #"{"detail":"boom"}"#)
        do { _ = try await svc.fetchThreads(userId: "u1", groupId: "g1", limit: 20, cursorTimestamp: nil, cursorId: nil); XCTFail() }
        catch { XCTAssertTrue(error is FSThreadsError) }
        ThreadsStubURLProtocol.routes["GET \(base)/threads"] = (200, #"{"nope":1}"#)
        do { _ = try await svc.fetchThreads(userId: "u1", groupId: "g1", limit: 20, cursorTimestamp: nil, cursorId: nil); XCTFail() }
        catch { XCTAssertEqual(error as? FSThreadsError, .failed("Couldn't load threads.")) }
    }

    func test_fetchThreads_404_isNotFound() async {
        await expectError(.notFound) {
            _ = try await svc.fetchThreads(userId: "u1", groupId: "g1", limit: 20, cursorTimestamp: nil, cursorId: nil)
        }
    }

    // MARK: create

    func test_createThread_postsMessageId_andDecodesSummary_for201And200() async throws {
        for status in [201, 200] {
            ThreadsStubURLProtocol.reset()
            ThreadsStubURLProtocol.routes["POST \(base)/threads"] = (status, """
            {"id":"t9","title":"Root text","root_message_id":"m5","root_preview":"Root text","reply_count":0,
             "last_activity_at":"2026-10-01T10:00:00+00:00","created_by":"u1"}
            """)
            let s = try await svc.createThread(userId: "u1", groupId: "g1", messageId: "m5")
            XCTAssertEqual(s.id, "t9")
            XCTAssertEqual(s.rootMessageId, "m5")
            let req = ThreadsStubURLProtocol.log.last!
            XCTAssertEqual(req.method, "POST")
            let body = try JSONSerialization.jsonObject(with: req.body ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["message_id"] as? String, "m5")
        }
    }

    func test_createThread_termsReaccept_threadLimit_notFound_generic() async {
        let path = "POST \(base)/threads"
        ThreadsStubURLProtocol.routes[path] = (403, #"{"detail":{"code":"terms_reaccept_required","message":"x"}}"#)
        await expectError(.termsReacceptRequired) { _ = try await svc.createThread(userId: "u1", groupId: "g1", messageId: "m") }
        ThreadsStubURLProtocol.routes[path] = (409, #"{"detail":{"code":"thread_limit","message":"x"}}"#)
        await expectError(.threadLimit) { _ = try await svc.createThread(userId: "u1", groupId: "g1", messageId: "m") }
        ThreadsStubURLProtocol.routes[path] = (404, #"{"detail":"Not found"}"#)
        await expectError(.notFound) { _ = try await svc.createThread(userId: "u1", groupId: "g1", messageId: "m") }
        ThreadsStubURLProtocol.routes[path] = (400, #"{"detail":"Title blocked"}"#)
        await expectError(.failed("Title blocked")) { _ = try await svc.createThread(userId: "u1", groupId: "g1", messageId: "m") }
        // a 403 without the terms code is NOT the terms gate
        ThreadsStubURLProtocol.routes[path] = (403, #"{"detail":"Forbidden"}"#)
        await expectError(.failed("Forbidden")) { _ = try await svc.createThread(userId: "u1", groupId: "g1", messageId: "m") }
        // 200 with an undecodable body never fabricates a thread
        ThreadsStubURLProtocol.routes[path] = (200, #"{"title":"no id"}"#)
        await expectError(.failed("Couldn't start a thread on that message.")) {
            _ = try await svc.createThread(userId: "u1", groupId: "g1", messageId: "m")
        }
    }

    // MARK: thread messages

    func test_fetchThreadMessages_decodesPage_andBuildsCursorQuery() async throws {
        ThreadsStubURLProtocol.routes["GET \(base)/threads/t1/messages"] = (200, """
        {"messages":[{"id":"a","text":"hi","from_user":"alice","mine":false,"timestamp":"2026-10-01T10:00:00Z"},
                     {"id":"b","text":"yo","from_user":"me","mine":true,"timestamp":"2026-10-01T10:01:00Z"}],
         "page":{"limit":2,"has_more":true,"next_cursor_timestamp":"2026-10-01T10:00:00+00:00","next_cursor_seq":4,"next_cursor_id":"a"}}
        """)
        let page = try await svc.fetchThreadMessages(userId: "u1", groupId: "g1", threadId: "t1", limit: 2,
                                                     cursor: FSMessageCursor(timestamp: "2026-10-01T11:00:00+00:00", seq: 9, id: "z"))
        XCTAssertEqual(page.messages.map(\.id), ["a", "b"])
        XCTAssertEqual(page.messages.map(\.mine), [false, true])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.cursor, FSMessageCursor(timestamp: "2026-10-01T10:00:00+00:00", seq: 4, id: "a"))
        let url = ThreadsStubURLProtocol.log.last!.url
        XCTAssertTrue(url.contains("/threads/t1/messages?"))
        XCTAssertTrue(url.contains("cursor_timestamp=2026-10-01T11:00:00%2B00:00"))
        XCTAssertTrue(url.contains("cursor_seq=9"))
        XCTAssertTrue(url.contains("cursor_id=z"))
    }

    func test_fetchThreadMessages_failures_throw_andNotFoundIsPreserved() async {
        ThreadsStubURLProtocol.routes["GET \(base)/threads/t1/messages"] = (500, "{}")
        await expectError(.failed("Couldn't load this thread.")) {
            _ = try await svc.fetchThreadMessages(userId: "u1", groupId: "g1", threadId: "t1", limit: 30, cursor: nil)
        }
        await expectError(.notFound) {
            _ = try await svc.fetchThreadMessages(userId: "u1", groupId: "g1", threadId: "missing", limit: 30, cursor: nil)
        }
        ThreadsStubURLProtocol.routes["GET \(base)/threads/t1/messages"] = (200, #"{"messages":[]}"#) // no page block
        await expectError(.failed("Couldn't load this thread.")) {
            _ = try await svc.fetchThreadMessages(userId: "u1", groupId: "g1", threadId: "t1", limit: 30, cursor: nil)
        }
    }

    // MARK: delete / restore

    func test_deleteGroupMessage_sendsDELETE_andReturnsServerUndoWindow() async throws {
        ThreadsStubURLProtocol.routes["DELETE \(base)/messages/m1"] = (200, #"{"id":"m1","undo_seconds":7}"#)
        let r = try await svc.deleteGroupMessage(userId: "u1", groupId: "g1", messageId: "m1")
        XCTAssertEqual(r, FSMessageDeleteResult(id: "m1", undoSeconds: 7))
        XCTAssertEqual(ThreadsStubURLProtocol.log.last!.method, "DELETE")
    }

    func test_deleteGroupMessage_defaultsToTenSecondsWhenServerOmitsWindow() async throws {
        ThreadsStubURLProtocol.routes["DELETE \(base)/messages/m1"] = (200, #"{"id":"m1"}"#)
        let r = try await svc.deleteGroupMessage(userId: "u1", groupId: "g1", messageId: "m1")
        XCTAssertEqual(r.undoSeconds, 10)
        XCTAssertEqual(NetworkService.defaultUndoSeconds, 10)
    }

    func test_deleteGroupMessage_errors() async {
        ThreadsStubURLProtocol.routes["DELETE \(base)/messages/m1"] = (403, #"{"detail":"Not your message"}"#)
        await expectError(.failed("Not your message")) {
            _ = try await svc.deleteGroupMessage(userId: "u1", groupId: "g1", messageId: "m1")
        }
        ThreadsStubURLProtocol.routes["DELETE \(base)/messages/m1"] = (404, "{}")
        await expectError(.notFound) { _ = try await svc.deleteGroupMessage(userId: "u1", groupId: "g1", messageId: "m1") }
        ThreadsStubURLProtocol.routes["DELETE \(base)/messages/m1"] = (200, #"{"x":1}"#)
        await expectError(.failed("Couldn't delete that message. Please try again.")) {
            _ = try await svc.deleteGroupMessage(userId: "u1", groupId: "g1", messageId: "m1")
        }
    }

    func test_restoreGroupMessage_postsToRestoreRoute_andThrowsAfterWindow() async throws {
        ThreadsStubURLProtocol.routes["POST \(base)/messages/m1/restore"] = (200, #"{"id":"m1"}"#)
        try await svc.restoreGroupMessage(userId: "u1", groupId: "g1", messageId: "m1")
        XCTAssertEqual(ThreadsStubURLProtocol.log.last!.method, "POST")
        ThreadsStubURLProtocol.routes["POST \(base)/messages/m1/restore"] = (410, #"{"detail":"Undo window over"}"#)
        await expectError(.failed("Undo window over")) {
            try await svc.restoreGroupMessage(userId: "u1", groupId: "g1", messageId: "m1")
        }
    }

    func test_pathSegments_arePercentEncoded() async throws {
        // Routes key on url.path (decoded); register the decoded form too.
        ThreadsStubURLProtocol.routes["DELETE /api/groups/u 1/g1/messages/m/1"] = (200, #"{"id":"x"}"#)
        _ = try await svc.deleteGroupMessage(userId: "u 1", groupId: "g1", messageId: "m/1")
        let url = ThreadsStubURLProtocol.log.last!.url
        XCTAssertTrue(url.contains("u%201"), url)
    }

    // MARK: frame mappers

    func test_threadFrame_and_restoredFrame_mapping() {
        let f = FSMessage(threadFrame: ["id": "x", "thread_id": "t", "sender": "bob", "body": "hey", "created_at": "2026-10-01T10:00:00Z"])
        XCTAssertEqual(f?.id, "x"); XCTAssertEqual(f?.sender, "bob"); XCTAssertEqual(f?.text, "hey"); XCTAssertEqual(f?.mine, false)
        XCTAssertNil(FSMessage(threadFrame: ["id": "x"]), "no thread id")
        XCTAssertNil(FSMessage(threadFrame: ["thread_id": "t"]), "no id")
        let r = FSMessage(restoredFrame: ["id": "r", "sender": "bob", "body": "back", "created_at": "2026-10-01T10:00:00Z"])
        XCTAssertEqual(r?.text, "back")
        XCTAssertNil(FSMessage(restoredFrame: ["body": "x"]))
    }
}
