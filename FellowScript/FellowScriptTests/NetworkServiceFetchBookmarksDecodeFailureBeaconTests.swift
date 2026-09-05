// NetworkServiceFetchBookmarksDecodeFailureBeaconTests.swift — testing-gate
// coverage for task 20260904-compliance-error-handling-consistency
// (readability #7): fetchBookmarks was the one sibling of fetchHighlights/
// fetchNotesCount/fetchAgents/fetchHeartbeats not tagged with an `endpoint:`
// argument on its decode() call, so a bookmarks decode failure previously
// degraded silently to "[:]" (indistinguishable from a genuine empty
// bookmark list) with zero reportDecodeFailure/CloudWatch signal, unlike
// every other read this file's prior decode-failure-visibility passes
// tagged. The frontend gate tagged it for symmetry.
//
// Same StubURLProtocol harness and beacon-polling pattern as
// AccountStatsDecodeFailureBeaconTests.swift (fetchHighlights/fetchAgents/
// fetchNotesCount's equivalent coverage) -- this file only adds the missing
// sibling, fetchBookmarks.

import XCTest
@testable import FellowScript

final class NetworkServiceFetchBookmarksDecodeFailureBeaconTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        // See AccountStatsDecodeFailureBeaconTests for why this drain window
        // exists: this test target may run alongside another concurrently-
        // invoked xcodebuild test suite sharing the same simulator, and each
        // decode-failure test here spawns a real fire-and-forget beacon Task.
        try await Task.sleep(nanoseconds: 700_000_000)
        StubURLProtocol.resetRequestLog()
    }

    private func waitForFireAndForgetBeacon() async throws {
        try await Task.sleep(nanoseconds: 900_000_000)
    }

    private func waitForBeacon(timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while beaconRequests().isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func beaconRequests() -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.path.contains("/monitoring/client-error") }
    }

    func test_fetchBookmarks_malformedShape_decodeFails_returnsEmptyDictionary_andFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        // Real shape is a flat {"Genesis-1": "label"}; nested objects as
        // values fail the [String: String] decode.
        StubURLProtocol.stubBody = #"{"Genesis-1": {"unexpected": "shape"}}"#.data(using: .utf8)!

        let bookmarks = try await NetworkService.shared.fetchBookmarks(userId: "user-1")

        XCTAssertTrue(bookmarks.isEmpty, "an undecodable bookmarks response must still fall back to an empty dictionary, matching the pre-existing best-effort-read behavior")

        await waitForBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1,
                        "THE FIX: a fetchBookmarks decode failure must no longer be silently swallowed -- it must fire exactly one beacon")
        XCTAssertEqual(beacons.first?.bodyJSON?["endpoint"] as? String, "GET /notes/bookmark/{user_id}")
    }

    func test_fetchBookmarks_wellFormedResponse_decodesCorrectly_andNeverFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"Genesis-1": "My favorite chapter", "John-3": ""}"#.data(using: .utf8)!

        let bookmarks = try await NetworkService.shared.fetchBookmarks(userId: "user-1")

        XCTAssertEqual(bookmarks.count, 2, "a well-formed bookmarks response must decode correctly")
        XCTAssertEqual(bookmarks["Genesis-1"], "My favorite chapter")

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty, "a successful decode must never fire the beacon")
    }

    /// Data minimization (security preference profile): the beacon must
    /// never leak raw bookmark content (e.g. a user's custom label) even
    /// when reporting a failure on this endpoint.
    func test_fetchBookmarks_decodeFailureBeacon_neverLeaksRawBookmarkContent() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"["SECRET_BOOKMARK_LABEL_MARKER"]"#.data(using: .utf8)!

        _ = try await NetworkService.shared.fetchBookmarks(userId: "user-1")

        await waitForBeacon()
        guard let beacon = beaconRequests().first else {
            XCTFail("expected exactly one beacon")
            return
        }
        let allowedKeys: Set<String> = ["endpoint", "client_app_version", "error_summary", "http_status"]
        let actualKeys: Set<String> = Set(beacon.bodyJSON?.keys.map { $0 } ?? [])
        XCTAssertTrue(actualKeys.isSubset(of: allowedKeys),
                      "beacon body must not carry any field beyond the documented minimal set, got keys: \(actualKeys)")
        if let bodyData = beacon.bodyData, let bodyString = String(data: bodyData, encoding: .utf8) {
            XCTAssertFalse(bodyString.contains("SECRET_BOOKMARK_LABEL_MARKER"),
                            "the beacon must never include the raw response body content (e.g. a bookmark label)")
        }
    }
}
