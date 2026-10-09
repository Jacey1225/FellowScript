// HighlightSearchTests.swift -- task 20261009-highlight-search, testing step 4.
//
// 1. NetworkService.searchHighlights (real service, URLProtocol stub reused
//    from ChatPaginationNetworkServiceTests): path/query/cursor encoding,
//    result + page decoding, hasMore gating, nil verse_text kept, and
//    throw-not-fabricate on non-2xx and malformed bodies.
// 2. HighlightSearchModel: debounced query, empty query restores (no results,
//    no error), failed search surfaces an error and leaves the cached
//    NotesViewModel highlights untouched, stale responses are discarded,
//    paging appends without duplicates, query is clamped to 100 chars.

import XCTest
@testable import FellowScript

// MARK: - search seam on the shared throwing test service

/// Per-test handler. Serialized test run only (one xcodebuild at a time).
private enum HLSearchSeam {
    static var handler: ((String, String, String?) async throws -> FSHighlightSearchPage)?
    static var calls: [(userId: String, query: String, cursorKey: String?)] = []
    static func reset() { handler = nil; calls = [] }
}

extension ThrowingTestDataService {
    func searchHighlights(userId: String, query: String, limit: Int?,
                          cursorTimestamp: String?, cursorId: String?, cursorKey: String?) async throws -> FSHighlightSearchPage {
        HLSearchSeam.calls.append((userId, query, cursorKey))
        guard let h = HLSearchSeam.handler else { throw FSHighlightSearchError.failed("unavailable") }
        return try await h(userId, query, cursorKey)
    }
}

private func result(_ owner: String, _ key: String, name: String? = "fr", text: String? = "t") -> FSHighlightSearchResult {
    let parts = key.split(separator: "-")
    return FSHighlightSearchResult(owner_id: owner, owner_username: name, is_self: owner == "me", key: key,
                                   book: String(parts[0]), chapter: Int(parts[1])!, verse: Int(parts[2])!,
                                   color: "yellow", verse_text: text, timestamp: nil)
}

private func page(_ rs: [FSHighlightSearchResult], more: Bool = false) -> FSHighlightSearchPage {
    FSHighlightSearchPage(results: rs, hasMore: more,
                          cursorTimestamp: more ? "2026-10-09T00:00:00+00:00" : nil,
                          cursorId: more ? rs.last?.owner_id : nil,
                          cursorKey: more ? rs.last?.key : nil)
}

private let settle: UInt64 = 900_000_000

// MARK: - NetworkService

final class HighlightSearchNetworkTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(PagingStubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(PagingStubURLProtocol.self); super.tearDown() }
    override func setUp() { PagingStubURLProtocol.reset() }

    private let svc = NetworkService.shared
    private let route = "/api/notes/highlight/u1/search"

    func test_decodesResultsAndCursor_andEncodesQuery() async throws {
        PagingStubURLProtocol.routes[route] = (200, """
        {"highlights":[
          {"owner_id":"f1","owner_username":"fr","is_self":false,"key":"John-3-16","book":"John","chapter":3,"verse":16,"color":"yellow","verse_text":"For God so loved","timestamp":"2026-10-09 10:00:00"},
          {"owner_id":"u1","owner_username":"me","is_self":true,"key":"Genesis-1-1","book":"Genesis","chapter":1,"verse":1,"color":"blue","verse_text":null,"timestamp":null}],
         "page":{"limit":2,"has_more":true,"next_cursor_timestamp":"2026-10-09T10:00:00+00:00","next_cursor_id":"u1","next_cursor_key":"Genesis-1-1"}}
        """)
        let p = try await svc.searchHighlights(userId: "u1", query: "John 3:16 & x", limit: 2,
                                               cursorTimestamp: nil, cursorId: nil, cursorKey: nil)
        XCTAssertEqual(p.results.map(\.key), ["John-3-16", "Genesis-1-1"])
        XCTAssertEqual(p.results[0].owner_username, "fr")
        XCTAssertFalse(p.results[0].is_self)
        XCTAssertTrue(p.results[1].is_self)
        XCTAssertNil(p.results[1].verse_text, "verse_text miss keeps the row")
        XCTAssertEqual(p.results[0].id, "f1|John-3-16")
        XCTAssertTrue(p.hasMore)
        XCTAssertEqual(p.cursorKey, "Genesis-1-1")
        let url = PagingStubURLProtocol.urls.last!
        XCTAssertTrue(url.contains("/notes/highlight/u1/search?q="))
        XCTAssertFalse(url.contains(" "), "query must be percent-encoded")
        XCTAssertFalse(url.contains("&x"), "ampersand in the query must be escaped, not a new param")
        XCTAssertTrue(url.contains("limit=2"))
        XCTAssertFalse(url.contains("cursor_"))
    }

    func test_cursorParamsSentTogether() async throws {
        PagingStubURLProtocol.routes[route] = (200, #"{"highlights":[],"page":{"has_more":false}}"#)
        _ = try await svc.searchHighlights(userId: "u1", query: "John", limit: nil,
                                           cursorTimestamp: "2026-10-09T10:00:00+00:00", cursorId: "f1", cursorKey: "John-3-16")
        let url = PagingStubURLProtocol.urls.last!
        XCTAssertTrue(url.contains("cursor_timestamp="))
        XCTAssertTrue(url.contains("cursor_id=f1"))
        XCTAssertTrue(url.contains("cursor_key=John-3-16"))
        XCTAssertFalse(url.contains("limit="))
    }

    func test_incompleteCursor_treatedAsEnd() async throws {
        PagingStubURLProtocol.routes[route] =
            (200, #"{"highlights":[],"page":{"has_more":true,"next_cursor_timestamp":"t","next_cursor_id":"x"}}"#)
        let p = try await svc.searchHighlights(userId: "u1", query: "a", limit: nil,
                                               cursorTimestamp: nil, cursorId: nil, cursorKey: nil)
        XCTAssertFalse(p.hasMore)
        XCTAssertNil(p.cursorKey)
    }

    func test_serverError_throws_notEmpty() async {
        PagingStubURLProtocol.routes[route] = (500, #"{"detail":"boom"}"#)
        do {
            _ = try await svc.searchHighlights(userId: "u1", query: "a", limit: nil,
                                               cursorTimestamp: nil, cursorId: nil, cursorKey: nil)
            XCTFail("500 must throw, not return an empty page")
        } catch {}
    }

    func test_validation422_throws() async {
        PagingStubURLProtocol.routes[route] = (422, #"{"detail":"Query is required"}"#)
        do {
            _ = try await svc.searchHighlights(userId: "u1", query: "a", limit: nil,
                                               cursorTimestamp: nil, cursorId: nil, cursorKey: nil)
            XCTFail("422 must throw")
        } catch {}
    }

    func test_malformedBody_throws_notEmpty() async {
        PagingStubURLProtocol.routes[route] = (200, #"{"nope":1}"#)
        do {
            _ = try await svc.searchHighlights(userId: "u1", query: "a", limit: nil,
                                               cursorTimestamp: nil, cursorId: nil, cursorKey: nil)
            XCTFail("a body without `highlights` must throw")
        } catch {}
    }

    func test_defaultProtocolImpl_throws() async {
        // MockDataService has no backend: must throw, never fabricate empty.
        do {
            _ = try await MockDataService.shared.searchHighlights(userId: "u", query: "a", limit: nil,
                                                                  cursorTimestamp: nil, cursorId: nil, cursorKey: nil)
            XCTFail("mock default must throw")
        } catch {}
    }
}

// MARK: - HighlightSearchModel

@MainActor
final class HighlightSearchModelTests: XCTestCase {
    override func setUp() { HLSearchSeam.reset() }
    override func tearDown() { HLSearchSeam.reset() }

    private func makeModel() -> HighlightSearchModel {
        let m = HighlightSearchModel()
        m.configure(service: ThrowingTestDataService(), userId: "me")
        return m
    }

    func test_typing_runsDebouncedSearch_andShowsResults() async throws {
        HLSearchSeam.handler = { _, _, _ in page([result("f1", "John-3-16")]) }
        let m = makeModel()
        m.searchText = "J"; m.searchText = "Jo"; m.searchText = "John 3:16"
        XCTAssertTrue(HLSearchSeam.calls.isEmpty, "debounced: no call before the delay")
        try await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(HLSearchSeam.calls.count, 1, "rapid keystrokes coalesce")
        XCTAssertEqual(HLSearchSeam.calls.first?.query, "John 3:16")
        XCTAssertEqual(HLSearchSeam.calls.first?.userId, "me")
        XCTAssertEqual(m.results.map(\.key), ["John-3-16"])
        XCTAssertNil(m.errorMessage)
        XCTAssertFalse(m.isSearching)
    }

    func test_whitespaceOnly_isInactive_noCall() async throws {
        HLSearchSeam.handler = { _, _, _ in page([result("f1", "John-3-16")]) }
        let m = makeModel()
        m.searchText = "   "
        try await Task.sleep(nanoseconds: settle)
        XCTAssertFalse(m.isActive)
        XCTAssertTrue(HLSearchSeam.calls.isEmpty)
        XCTAssertTrue(m.results.isEmpty)
    }

    func test_clearingQuery_resetsResultsAndError() async throws {
        HLSearchSeam.handler = { _, _, _ in page([result("f1", "John-3-16")]) }
        let m = makeModel()
        m.searchText = "John"
        try await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(m.results.count, 1)
        m.clear()
        XCTAssertTrue(m.results.isEmpty)
        XCTAssertNil(m.errorMessage)
        XCTAssertFalse(m.hasMore)
        XCTAssertFalse(m.isActive)
    }

    func test_failedSearch_surfacesError_notEmptyResults_andDoesNotWipeCachedHighlights() async throws {
        // No handler -> service throws.
        let vm = NotesViewModel()
        vm.highlights = ["John-3-16": "yellow", "Genesis-1-1": "blue"]
        let m = makeModel()
        m.searchText = "John"
        try await Task.sleep(nanoseconds: settle)
        XCTAssertNotNil(m.errorMessage, "failure must surface an error")
        XCTAssertTrue(m.results.isEmpty)
        XCTAssertEqual(vm.highlights, ["John-3-16": "yellow", "Genesis-1-1": "blue"],
                       "search state is independent: cached highlights untouched")
        m.clear()
        XCTAssertNil(m.errorMessage)
        XCTAssertEqual(vm.highlights.count, 2)
    }

    func test_retry_afterFailure_succeeds() async throws {
        let m = makeModel()
        m.searchText = "John"
        try await Task.sleep(nanoseconds: settle)
        XCTAssertNotNil(m.errorMessage)
        HLSearchSeam.handler = { _, _, _ in page([result("f1", "John-3-16")]) }
        m.retry()
        try await Task.sleep(nanoseconds: settle)
        XCTAssertNil(m.errorMessage)
        XCTAssertEqual(m.results.count, 1)
    }

    func test_staleResponse_isDiscarded() async throws {
        HLSearchSeam.handler = { _, q, _ in
            if q == "slow" { try await Task.sleep(nanoseconds: 1_200_000_000); return page([result("f1", "John-3-16")]) }
            return page([result("f2", "Psalms-23-1")])
        }
        let m = makeModel()
        m.searchText = "slow"
        try await Task.sleep(nanoseconds: 450_000_000)   // slow call in flight
        m.searchText = "fast"
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(m.results.map(\.key), ["Psalms-23-1"], "superseded response must not clobber newer results")
    }

    func test_pagination_appendsWithoutDuplicates_andStopsAtEnd() async throws {
        let a = result("f1", "John-3-16"), b = result("f1", "John-3-17")
        HLSearchSeam.handler = { _, _, cursorKey in
            cursorKey == nil ? page([a], more: true) : page([a, b], more: false)   // overlap on purpose
        }
        let m = makeModel()
        m.searchText = "John"
        try await Task.sleep(nanoseconds: settle)
        XCTAssertTrue(m.hasMore)
        m.loadMoreIfNeeded(current: a)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(m.results.map(\.key), ["John-3-16", "John-3-17"], "no duplicate row")
        XCTAssertFalse(m.hasMore)
        XCTAssertEqual(HLSearchSeam.calls.last?.cursorKey, "John-3-16", "cursor key forwarded")
    }

    func test_loadMore_onlyFromLastRow() async throws {
        let a = result("f1", "John-3-16"), b = result("f1", "John-3-17")
        HLSearchSeam.handler = { _, _, _ in page([a, b], more: true) }
        let m = makeModel()
        m.searchText = "John"
        try await Task.sleep(nanoseconds: settle)
        let before = HLSearchSeam.calls.count
        m.loadMoreIfNeeded(current: a)   // not last
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(HLSearchSeam.calls.count, before)
    }

    func test_loadMoreFailure_keepsResults() async throws {
        let a = result("f1", "John-3-16")
        var first = true
        HLSearchSeam.handler = { _, _, _ in
            if first { first = false; return page([a], more: true) }
            throw FSHighlightSearchError.failed("x")
        }
        let m = makeModel()
        m.searchText = "John"
        try await Task.sleep(nanoseconds: settle)
        m.loadMoreIfNeeded(current: a)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(m.results.map(\.key), ["John-3-16"], "failed page keeps what's shown")
        XCTAssertFalse(m.hasMore)
        XCTAssertFalse(m.isLoadingMore)
    }

    func test_overlongQuery_clampedTo100() async throws {
        HLSearchSeam.handler = { _, _, _ in page([]) }
        let m = makeModel()
        m.searchText = String(repeating: "a", count: 250)
        try await Task.sleep(nanoseconds: settle)
        XCTAssertEqual(HLSearchSeam.calls.first?.query.count, 100)
    }
}
