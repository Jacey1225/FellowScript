// ChatPaginationNetworkServiceTests.swift -- task 20261001-chat-pagination,
// testing step 10. Exercises the REAL NetworkService (via a path-routed
// URLProtocol stub) for: page decoding with / without the page block, legacy
// fallback, the limit gate, cursor query encoding, throw-not-fabricate on
// older-page failures, and fetchContacts limit=1 previews gated by the
// capabilities client.

import XCTest
@testable import FellowScript

final class PagingStubURLProtocol: URLProtocol {
    /// path (no query) -> (status, body). Unlisted paths 404.
    static var routes: [String: (Int, String)] = [:]
    static var urls: [String] = []

    static func reset() { routes = [:]; urls = [] }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fellowscript.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.urls.append(url.absoluteString)
        let route = Self.routes[url.path] ?? (404, #"{"detail":"nf"}"#)
        let resp = HTTPURLResponse(url: url, statusCode: route.0, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.1.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ChatPaginationNetworkServiceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(PagingStubURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(PagingStubURLProtocol.self)
        super.tearDown()
    }
    override func setUp() { PagingStubURLProtocol.reset() }

    private let svc = NetworkService.shared

    private let pagedBody = """
    {"messages":[
      {"id":"m1","text":"one","from_user":"alice","mine":false,"timestamp":"2026-10-01T10:00:00Z"},
      {"id":"m2","text":"two","from_user":"me","mine":true,"timestamp":"2026-10-01T10:01:00Z"}],
     "page":{"limit":2,"has_more":true,"next_cursor_timestamp":"2026-10-01T10:00:00+00:00","next_cursor_seq":7,"next_cursor_id":"m1"}}
    """

    // MARK: page decoding

    func test_paged_response_decodes_page_cursor_and_mine() async throws {
        PagingStubURLProtocol.routes["/api/groups/u1/g1"] = (200, pagedBody)
        let h = try await svc.fetchMessageHistory(userId: "u1", contactId: "g1", isGroup: true, limit: 2)
        guard case .paged(let page) = h else { return XCTFail("expected paged") }
        XCTAssertEqual(page.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(page.messages.map(\.mine), [false, true])
        XCTAssertEqual(page.messages[0].sender, "alice")
        XCTAssertEqual(page.messages[1].sender, "", "own message carries no sender label")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.cursor, FSMessageCursor(timestamp: "2026-10-01T10:00:00+00:00", seq: 7, id: "m1"))
        XCTAssertTrue(PagingStubURLProtocol.urls.last!.hasSuffix("/groups/u1/g1?limit=2"))
    }

    func test_paged_hasMoreFalse_hasNoCursor() async throws {
        PagingStubURLProtocol.routes["/api/friends/u1/f1"] = (200, #"{"messages":[],"page":{"limit":30,"has_more":false}}"#)
        let h = try await svc.fetchMessageHistory(userId: "u1", contactId: "f1", isGroup: false, limit: 30)
        guard case .paged(let page) = h else { return XCTFail("expected paged") }
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.cursor)
        XCTAssertTrue(PagingStubURLProtocol.urls.last!.contains("/friends/u1/f1?limit=30"))
    }

    func test_hasMore_withoutUsableCursor_isTreatedAsEnd() async throws {
        PagingStubURLProtocol.routes["/api/groups/u1/g1"] =
            (200, #"{"messages":[{"id":"a","text":"x","timestamp":"t"}],"page":{"has_more":true}}"#)
        let h = try await svc.fetchMessageHistory(userId: "u1", contactId: "g1", isGroup: true, limit: 30)
        guard case .paged(let page) = h else { return XCTFail("expected paged") }
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.cursor)
    }

    // MARK: legacy fallback

    func test_nilLimit_sendsNoLimitParam_andIsLegacy() async throws {
        PagingStubURLProtocol.routes["/api/groups/u1/g1"] = (200, """
        {"host_msgs":[{"id":"h1","text":"mine","timestamp":"2026-10-01T10:02:00Z"}],
         "other_msgs":[{"id":"o1","text":"theirs","from_user":"bob","timestamp":"2026-10-01T10:01:00Z"}]}
        """)
        let h = try await svc.fetchMessageHistory(userId: "u1", contactId: "g1", isGroup: true, limit: nil)
        guard case .legacy(let msgs) = h else { return XCTFail("expected legacy") }
        XCTAssertEqual(msgs.map(\.id), ["o1", "h1"], "legacy keeps the timestamp sort")
        XCTAssertFalse(PagingStubURLProtocol.urls.last!.contains("limit"))
    }

    func test_limitSent_butNoPageBlock_decodesLegacyShape_neverBlank() async throws {
        PagingStubURLProtocol.routes["/api/friends/u1/f1"] = (200, """
        {"host_msgs":[{"id":"h1","text":"mine","timestamp":"2026-10-01T10:02:00Z"}],
         "other_msgs":[{"id":"o1","text":"theirs","from_user":"f1","timestamp":"2026-10-01T10:01:00Z"}]}
        """)
        let h = try await svc.fetchMessageHistory(userId: "u1", contactId: "f1", isGroup: false, limit: 30)
        guard case .legacy(let msgs) = h else { return XCTFail("a body with no page block must be legacy") }
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs.first(where: { $0.id == "h1" })?.mine, true)
        XCTAssertEqual(msgs.first(where: { $0.id == "o1" })?.sender, "f1")
    }

    func test_fetchMessageHistory_throwsOnHttpError() async {
        PagingStubURLProtocol.routes["/api/groups/u1/g1"] = (500, #"{"detail":"boom"}"#)
        do {
            _ = try await svc.fetchMessageHistory(userId: "u1", contactId: "g1", isGroup: true, limit: 30)
            XCTFail("must throw")
        } catch {}
    }

    // MARK: older pages

    func test_fetchOlder_buildsCursorQuery_encodesPlus_andOmitsNilSeq() async throws {
        PagingStubURLProtocol.routes["/api/groups/u1/g1/messages"] = (200, pagedBody)
        _ = try await svc.fetchOlderMessages(userId: "u1", contactId: "g1", isGroup: true, limit: 30,
                                              cursor: FSMessageCursor(timestamp: "2026-10-01T10:00:00+00:00", seq: 7, id: "m 1"))
        let url = PagingStubURLProtocol.urls.last!
        XCTAssertTrue(url.contains("/groups/u1/g1/messages?"))
        XCTAssertTrue(url.contains("limit=30"))
        XCTAssertTrue(url.contains("cursor_timestamp=2026-10-01T10:00:00%2B00:00"), "'+' must be percent-encoded: \(url)")
        XCTAssertTrue(url.contains("cursor_seq=7"))
        XCTAssertTrue(url.contains("cursor_id=m%201"))

        _ = try await svc.fetchOlderMessages(userId: "u1", contactId: "g1", isGroup: true, limit: 30,
                                              cursor: FSMessageCursor(timestamp: "t", seq: nil, id: "m1"))
        XCTAssertFalse(PagingStubURLProtocol.urls.last!.contains("cursor_seq"))
    }

    func test_fetchOlder_dmUsesFriendsRoute() async throws {
        PagingStubURLProtocol.routes["/api/friends/u1/f1/messages"] = (200, pagedBody)
        _ = try await svc.fetchOlderMessages(userId: "u1", contactId: "f1", isGroup: false, limit: 30,
                                              cursor: FSMessageCursor(timestamp: "t", seq: 1, id: "x"))
        XCTAssertTrue(PagingStubURLProtocol.urls.last!.contains("/friends/u1/f1/messages?"))
    }

    func test_fetchOlder_throwsOn404_flagOff() async {
        // route unlisted -> 404
        do {
            _ = try await svc.fetchOlderMessages(userId: "u1", contactId: "g1", isGroup: true, limit: 30,
                                                  cursor: FSMessageCursor(timestamp: "t", seq: 1, id: "x"))
            XCTFail("must throw, never fabricate an empty page")
        } catch {}
    }

    func test_fetchOlder_throwsWhenBodyHasNoPageBlock() async {
        PagingStubURLProtocol.routes["/api/groups/u1/g1/messages"] = (200, #"{"host_msgs":[],"other_msgs":[]}"#)
        do {
            _ = try await svc.fetchOlderMessages(userId: "u1", contactId: "g1", isGroup: true, limit: 30,
                                                  cursor: FSMessageCursor(timestamp: "t", seq: 1, id: "x"))
            XCTFail("a 200 without a page block must throw")
        } catch {}
    }

    // MARK: fetchContacts previews

    private func routeContacts() {
        PagingStubURLProtocol.routes["/api/user/me"] =
            (200, #"{"user_id":"me","username":"Me","email":"m@x.com","friends":["f1"],"groups":["g1"]}"#)
        PagingStubURLProtocol.routes["/api/user/f1"] =
            (200, #"{"user_id":"f1","username":"Friend","email":"f@x.com"}"#)
    }

    private let pagedPreviewDM = """
    {"payload":{"messages":[{"id":"d1","text":"hey","from_user":"Me","mine":true,"timestamp":"2026-10-01T09:00:00Z"}],"page":{"limit":1,"has_more":true,"next_cursor_timestamp":"t","next_cursor_id":"d1"}}}
    """
    private let pagedPreviewGroup = """
    {"group":{"title":"G","users":["me","x"]},"members":["X"],
     "messages":[{"id":"p1","text":"latest","from_user":"x-name","mine":false,"timestamp":"2026-10-01T09:30:00Z"}],
     "page":{"limit":1,"has_more":true,"next_cursor_timestamp":"t","next_cursor_id":"p1"}}
    """

    func test_fetchContacts_flagsOn_usesLimit1_andOwnMessageSenderIsCurrentUser() async throws {
        routeContacts()
        PagingStubURLProtocol.routes["/api/message/messages/me"] = (200, pagedPreviewDM)
        PagingStubURLProtocol.routes["/api/groups/me/g1"] = (200, pagedPreviewGroup)
        let caps = FSCapabilities(features: ["chat_pagination": true, "chat_pagination_dm": true], exploreLink: nil, termsCurrent: true)
        let (contacts, groups) = try await svc.fetchContacts(userId: "me", capabilities: caps)

        XCTAssertTrue(PagingStubURLProtocol.urls.contains { $0.contains("/message/messages/me/") && $0.contains("guest_user=f1") && $0.contains("limit=1") })
        XCTAssertTrue(PagingStubURLProtocol.urls.contains { $0.hasSuffix("/groups/me/g1?limit=1") })
        let dm = try XCTUnwrap(contacts.first { $0.id == "f1" })
        XCTAssertEqual(dm.preview, "hey")
        XCTAssertEqual(dm.lastMessageAt, "2026-10-01T09:00:00Z")
        XCTAssertEqual(dm.lastMessageSenderId, "me", "paged own message must keep self-sent unread suppression")
        let g = try XCTUnwrap(contacts.first { $0.id == "g1" })
        XCTAssertEqual(g.preview, "latest")
        XCTAssertEqual(g.lastMessageSenderId, "x-name")
        XCTAssertEqual(groups["g1"]?.title, "G")
    }

    func test_fetchContacts_flagsOff_noLimitParam_legacyDecode() async throws {
        routeContacts()
        PagingStubURLProtocol.routes["/api/message/messages/me"] = (200, """
        {"payload":{"host_msgs":[{"id":"a","text":"old","timestamp":"2026-10-01T08:00:00Z"}],
                    "other_msgs":[{"id":"b","text":"newer","from_user":"f1","timestamp":"2026-10-01T08:05:00Z"}]}}
        """)
        PagingStubURLProtocol.routes["/api/groups/me/g1"] = (200, """
        {"group":{"title":"G","users":["me"]},"host_msgs":[],"other_msgs":[{"id":"c","text":"gm","from_user":"x","timestamp":"2026-10-01T08:10:00Z"}]}
        """)
        for caps in [FSCapabilities.allOff,
                     FSCapabilities(features: ["chat_pagination": false, "chat_pagination_dm": false], exploreLink: nil, termsCurrent: true)] {
            PagingStubURLProtocol.urls = []
            let (contacts, _) = try await svc.fetchContacts(userId: "me", capabilities: caps)
            XCTAssertFalse(PagingStubURLProtocol.urls.contains { $0.contains("limit=") }, "false/missing capability must send no limit")
            XCTAssertEqual(contacts.first { $0.id == "f1" }?.preview, "newer")
            XCTAssertEqual(contacts.first { $0.id == "g1" }?.preview, "gm")
        }
    }

    func test_fetchContacts_dmFlagOnly_gatesPerKind() async throws {
        routeContacts()
        PagingStubURLProtocol.routes["/api/message/messages/me"] = (200, pagedPreviewDM)
        PagingStubURLProtocol.routes["/api/groups/me/g1"] = (200, #"{"group":{"title":"G","users":["me"]},"host_msgs":[],"other_msgs":[]}"#)
        let caps = FSCapabilities(features: ["chat_pagination_dm": true], exploreLink: nil, termsCurrent: true)
        _ = try await svc.fetchContacts(userId: "me", capabilities: caps)
        XCTAssertTrue(PagingStubURLProtocol.urls.contains { $0.contains("/message/messages/me/") && $0.contains("limit=1") })
        XCTAssertFalse(PagingStubURLProtocol.urls.contains { $0.contains("/groups/me/g1") && $0.contains("limit") })
    }

    func test_fetchContacts_flagOn_butLegacyBody_fallsBack() async throws {
        routeContacts()
        PagingStubURLProtocol.routes["/api/message/messages/me"] = (200, """
        {"payload":{"host_msgs":[],"other_msgs":[{"id":"b","text":"legacy","from_user":"f1","timestamp":"2026-10-01T08:05:00Z"}]}}
        """)
        PagingStubURLProtocol.routes["/api/groups/me/g1"] = (200, #"{"group":{"title":"G","users":["me"]},"host_msgs":[],"other_msgs":[]}"#)
        let caps = FSCapabilities(features: ["chat_pagination_dm": true], exploreLink: nil, termsCurrent: true)
        let (contacts, _) = try await svc.fetchContacts(userId: "me", capabilities: caps)
        XCTAssertEqual(contacts.first { $0.id == "f1" }?.preview, "legacy")
        XCTAssertEqual(contacts.first { $0.id == "f1" }?.lastMessageSenderId, "f1")
    }
}
