// AccountStatsDecodeFailureBeaconTests.swift — testing-gate coverage for task
// 20260903-account-stats-not-loading, step 2 (testing), covering the
// frontend gate's step 1 fix to NetworkService.fetchNotesCount/
// fetchHighlights/fetchAgents.
//
// Per the intake spec: these three were the only fetch* functions on
// NetworkService still calling the shared `decode(...)` helper WITHOUT its
// `endpoint:` argument (unlike siblings such as fetchGroupNotes/searchNotes/
// fetchReplies) -- so a decode failure on exactly these three produced zero
// server-side signal: it was only `print`-logged locally and never beaconed
// via `reportDecodeFailure`, indistinguishable from a real zero-notes/
// zero-highlights/zero-agents account. The frontend gate added the missing
// `endpoint:` tags.
//
// Exercised against the real NetworkService (not MockDataService) via the
// StubURLProtocol harness (defined in NetworkServiceGetErrorHandlingTests.swift,
// same test target, and already extended with beacon-observing request
// logging by NotesLoadFailureHardeningTests.swift) -- the bug and the fix
// both live in NetworkService's own decode() call sites, which no mock
// exercises.
//
// Covers, per function (fetchNotesCount / fetchHighlights / fetchAgents):
//   1. A malformed response that fails to decode still falls back to the
//      documented safe default (0 / [:] / []) -- the pre-existing
//      "best-effort read" behavior must be unchanged.
//   2. THE FIX: that same decode failure now fires exactly one beacon
//      (POST /monitoring/client-error) tagged with the correct templated
//      endpoint path.
//   3. Happy-path regression guard: a well-formed response never fires the
//      beacon (no false-positive noise on every normal Account screen load).
//   4. Data-minimization: the beacon body carries only the documented
//      minimal fields and never leaks the raw response content (highlight
//      colors / agent names), per the security preference profile.

import XCTest
@testable import FellowScript

final class AccountStatsDecodeFailureBeaconTests: XCTestCase {

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
        // Drain window (contention-tolerant harness): this test target can
        // run alongside another concurrently-invoked xcodebuild test suite
        // sharing the same simulator (see this task's testing-step
        // instructions), and this file's own back-to-back decode-failure
        // tests each spawn a real fire-and-forget beacon Task
        // (NetworkService.reportDecodeFailure). Under CPU contention that
        // Task can land well after its own test method already returned --
        // resetting the shared StubURLProtocol.requestLog immediately would
        // let that straggler bleed into (and inflate the count for) the
        // NEXT test. Waiting here first gives any straggler from the test
        // that just finished a real chance to land before this test
        // establishes its own clean baseline.
        try await Task.sleep(nanoseconds: 700_000_000)
        StubURLProtocol.resetRequestLog()
    }

    /// Fire-and-forget beacon -- give it a beat to actually run before
    /// asserting on the request log (same base pattern as
    /// NotesLoadFailureHardeningTests). Used only by the happy-path "never
    /// fires" tests below, where there's nothing to poll for -- a fixed
    /// window is the only option when proving an absence.
    private func waitForFireAndForgetBeacon() async throws {
        try await Task.sleep(nanoseconds: 900_000_000)
    }

    /// Polls (rather than a single fixed sleep) until at least one beacon
    /// has landed or `timeout` elapses. This test target shares a real
    /// simulator with other concurrently-running xcodebuild test invocations
    /// (see this task's testing-step instructions), and this file's own
    /// back-to-back decode-failure tests each fire a real fire-and-forget
    /// Task -- under CPU contention a fixed short sleep is sometimes too
    /// short for the CURRENT test's own beacon, which then lands during the
    /// NEXT test's window instead and corrupts its count. Polling returns as
    /// soon as the beacon actually lands (fast in the common case) while
    /// tolerating real contention up to `timeout`, which also minimizes how
    /// long a just-finished test can still have work in flight when the next
    /// test's setUp() resets the shared log.
    private func waitForBeacon(timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while beaconRequests().isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func beaconRequests() -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.path.contains("/monitoring/client-error") }
    }

    // MARK: fetchNotesCount

    func test_fetchNotesCount_malformedShape_decodeFails_returnsZero_andFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        // Real shape is {"count": N}; an array has no "count" key at all.
        StubURLProtocol.stubBody = "[1, 2, 3]".data(using: .utf8)!

        let count = try await NetworkService.shared.fetchNotesCount(userId: "user-1")

        XCTAssertEqual(count, 0, "an undecodable notes-count response must still fall back to 0, not throw or crash")

        await waitForBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1,
                        "THE FIX: a fetchNotesCount decode failure must no longer be silently swallowed -- it must fire exactly one beacon")
        XCTAssertEqual(beacons.first?.bodyJSON?["endpoint"] as? String, "GET /notes/{user_id}/count")
    }

    func test_fetchNotesCount_wellFormedResponse_decodesCorrectly_andNeverFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"count": 133}"#.data(using: .utf8)!

        let count = try await NetworkService.shared.fetchNotesCount(userId: "user-1")

        XCTAssertEqual(count, 133, "a well-formed count response must decode correctly")

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty, "a successful decode must never fire the beacon")
    }

    // MARK: fetchHighlights

    func test_fetchHighlights_malformedShape_decodeFails_returnsEmptyDictionary_andFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        // Real shape is a flat {key: hexColorString}; nested objects as
        // values fail the [String: String] decode.
        StubURLProtocol.stubBody = #"{"Genesis_1_1_gold": {"unexpected": "shape"}}"#.data(using: .utf8)!

        let highlights = try await NetworkService.shared.fetchHighlights(userId: "user-1")

        XCTAssertTrue(highlights.isEmpty, "an undecodable highlights response must still fall back to an empty dictionary")

        await waitForBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1,
                        "THE FIX: a fetchHighlights decode failure must no longer be silently swallowed -- it must fire exactly one beacon")
        XCTAssertEqual(beacons.first?.bodyJSON?["endpoint"] as? String, "GET /notes/highlight/{user_id}")
    }

    func test_fetchHighlights_wellFormedResponse_decodesCorrectly_andNeverFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = ##"{"Genesis_1_1_gold": "#FFD700", "John_3_16_blue": "#3366FF"}"##.data(using: .utf8)!

        let highlights = try await NetworkService.shared.fetchHighlights(userId: "user-1")

        XCTAssertEqual(highlights.count, 2, "a well-formed highlights response must decode correctly")

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty, "a successful decode must never fire the beacon")
    }

    /// Data minimization (security preference profile): the beacon must
    /// never leak raw highlight content (e.g. verse keys or colors) even
    /// when reporting a failure on this endpoint. Uses a top-level shape
    /// mismatch (array instead of the expected dictionary) rather than a
    /// per-key mismatch, so the assertion isn't testing an artifact of
    /// Foundation's DecodingError including a dictionary KEY in its coding
    /// path (which is a structural verse identifier, not sensitive content,
    /// and isn't what this check is about) -- this proves the actual
    /// response VALUE content never appears in the beacon.
    func test_fetchHighlights_decodeFailureBeacon_neverLeaksRawHighlightContent() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"["SECRET_HIGHLIGHT_COLOR_MARKER"]"#.data(using: .utf8)!

        _ = try await NetworkService.shared.fetchHighlights(userId: "user-1")

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
            XCTAssertFalse(bodyString.contains("SECRET_HIGHLIGHT_COLOR_MARKER"),
                            "the beacon must never include the raw response body content (e.g. a highlight color value)")
        }
    }

    // MARK: fetchAgents

    func test_fetchAgents_malformedShape_decodeFails_returnsEmptyArray_andFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        // Real shape is {uuid: {user_id, role, name, ...}}; a top-level
        // array has no keyed container for [String: FSAgent] to decode.
        StubURLProtocol.stubBody = "[1, 2, 3]".data(using: .utf8)!

        let agents = try await NetworkService.shared.fetchAgents(userId: "user-1")

        XCTAssertTrue(agents.isEmpty, "an undecodable agents response must still fall back to an empty array")

        await waitForBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1,
                        "THE FIX: a fetchAgents decode failure must no longer be silently swallowed -- it must fire exactly one beacon")
        XCTAssertEqual(beacons.first?.bodyJSON?["endpoint"] as? String, "GET /agent/{user_id}")
    }

    func test_fetchAgents_wellFormedResponse_decodesCorrectly_andNeverFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "77777777-7777-7777-7777-777777777777": {
            "user_id": "user-1", "name": "Prayer Guide", "role": "You are a spiritual guide.",
            "enabled": true, "chats": []
          }
        }
        """#.data(using: .utf8)!

        let agents = try await NetworkService.shared.fetchAgents(userId: "user-1")

        XCTAssertEqual(agents.count, 1, "a well-formed agents response must decode correctly")
        XCTAssertEqual(agents.first?.id, "77777777-7777-7777-7777-777777777777",
                        "the agent id must be stamped from the dict key")

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty, "a successful decode must never fire the beacon")
    }

    /// Data minimization: an agent's name/role must never leak into the
    /// beacon on a decode failure.
    func test_fetchAgents_decodeFailureBeacon_neverLeaksRawAgentContent() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"["SECRET_AGENT_NAME_MARKER"]"#.data(using: .utf8)!

        _ = try await NetworkService.shared.fetchAgents(userId: "user-1")

        await waitForBeacon()
        guard let beacon = beaconRequests().first else {
            XCTFail("expected exactly one beacon")
            return
        }
        if let bodyData = beacon.bodyData, let bodyString = String(data: bodyData, encoding: .utf8) {
            XCTAssertFalse(bodyString.contains("SECRET_AGENT_NAME_MARKER"),
                            "the beacon must never include the raw response body content")
        }
    }
}
