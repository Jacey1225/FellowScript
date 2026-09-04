// AccountEventsDecodeFailureRegressionTests.swift — testing-gate coverage for
// task 20260903-account-events-not-loading, step 4 (testing), covering the
// frontend gate's step 4 fixes (NetworkService.fetchHeartbeats endpoint
// tagging, FSHeartbeat's lenient decode, and AccountViewModel.load()'s
// events-fetch failure now feeding statsMsg).
//
// Root cause (confirmed via read-only production SSH at intake): the
// production `agent_heartbeats` table was missing the `notes_public` column
// that `create_tables()`'s ALTER TABLE statement was supposed to have
// applied. `AgentManager.get_heartbeats` builds each row's JSON generically
// from the DB row (no Pydantic defaulting) — see
// test_heartbeats_notes_public_self_heal.py for the backend-side proof of
// this exact mechanism — so a missing column meant every heartbeat's JSON
// simply had NO `notes_public` key. iOS's `FSHeartbeat: Codable` declared
// `notes_public` as a required (non-Optional) key, so `JSONDecoder` threw
// `.keyNotFound` for every row, and since `NetworkService.decode([FSHeartbeat]...)`
// fails atomically for the whole array on any one throwing element, the
// user's real, actively-firing heartbeats vanished into the same silent `[]`
// fallback as "this agent really has zero events" — with zero
// `reportDecodeFailure`/CloudWatch signal, because `fetchHeartbeats` was the
// one sibling fetch `20260903-account-stats-not-loading`'s own fix missed.
//
// This file proves, against the real NetworkService/FSHeartbeat/
// AccountViewModel (not by reading the source):
//
//   1. THE CORE FIX (Models.swift): a response shaped exactly like the
//      reported bug — real heartbeat rows entirely missing `notes_public` —
//      now decodes the WHOLE array successfully, defaulting only that field,
//      instead of failing every row. Also covers a present-but-malformed
//      value (not just an absent key) degrading the same way.
//   2. fetchHeartbeats' decode() call is now tagged with `endpoint:`
//      (NetworkService.swift) — a genuine decode failure (e.g. a
//      fundamentally wrong top-level shape) now fires exactly one beacon,
//      matching the sibling fetchNotesCount/fetchHighlights/fetchAgents
//      pattern from AccountStatsDecodeFailureBeaconTests. Data-minimization:
//      the beacon never leaks raw prompt content.
//   3. Regression guard: the exact missing-notes_public shape from #1 must
//      NOT fire a beacon — it's now a fully successful decode (defaulted),
//      not a failure needing a beacon, distinguishing "gracefully defaulted"
//      from "genuinely broken".
//   4. AccountViewModel.load(): a genuine fetchHeartbeats failure on one
//      agent now surfaces statsMsg (extending its alert copy to mention
//      events, per the frontend gate's step 4), while a DIFFERENT agent's
//      real events still show — the failure doesn't wipe out data that
//      loaded successfully. A normal multi-agent success aggregates all
//      events and never shows the banner.
//
// Uses ThrowingTestDataService (defined in AppStateAuthAccountTests.swift,
// same test target), which this task's testing step extended with a
// fetchHeartbeats error/result/delay seam (previously a bare pass-through to
// MockDataService with no controllable seam at all) — coordinating with the
// existing double rather than duplicating a new one.

import XCTest
@testable import FellowScript

// MARK: - NetworkService / FSHeartbeat decode coverage

final class AccountEventsDecodeFailureRegressionTests: XCTestCase {

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
        // Drain window (contention-tolerant harness) — same rationale as
        // AccountStatsDecodeFailureBeaconTests: this test target can run
        // alongside another concurrently-invoked xcodebuild test suite
        // sharing the same simulator, and this file's own back-to-back
        // decode-failure tests each spawn a real fire-and-forget beacon Task.
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

    // MARK: 1 — THE CORE FIX: FSHeartbeat's lenient decode

    /// Reproduces the exact reported bug's response shape: real heartbeat
    /// rows entirely missing `notes_public` (mirrors the user's 3 real
    /// configured heartbeats from the intake spec — Colossians/Ephesians
    /// devotion prompts, "Give me simple prompts...").
    func test_FSHeartbeat_missingNotesPublicKey_stillDecodesWholeArray_bothRootCauseAndFix() throws {
        let json = #"""
        [
          {"_id": "hb-1", "agent_id": "agent-1", "user_id": "user-1", "timestamps": [], "prompt": "Reflect on Colossians and how it applies today."},
          {"_id": "hb-2", "agent_id": "agent-1", "user_id": "user-1", "timestamps": [], "prompt": "Reflect on Ephesians."},
          {"_id": "hb-3", "agent_id": "agent-1", "user_id": "user-1", "timestamps": [], "prompt": "Give me simple prompts to reflect on today."}
        ]
        """#.data(using: .utf8)!

        let heartbeats = try JSONDecoder().decode([FSHeartbeat].self, from: json)

        XCTAssertEqual(heartbeats.count, 3,
                        "THE FIX: all 3 real heartbeats must decode successfully even though every row omits notes_public entirely -- this is exactly the reported bug's response shape, which previously failed the WHOLE array on a single required-key miss")
        XCTAssertEqual(heartbeats.map(\.notes_public), [false, false, false],
                        "a missing notes_public must degrade to the struct's own default (false), not crash decoding")
        XCTAssertEqual(heartbeats.map(\.prompt),
                        ["Reflect on Colossians and how it applies today.", "Reflect on Ephesians.", "Give me simple prompts to reflect on today."],
                        "every other field on every row must still decode normally")
    }

    /// Not just an ABSENT key — a PRESENT but wrong-typed value must also
    /// degrade to the default rather than failing the array, matching
    /// decodeLenient's documented behavior (any DecodingError, not just
    /// .keyNotFound).
    func test_FSHeartbeat_malformedNotesPublicType_degradesToDefault_notWholeArrayFailure() throws {
        let json = #"""
        [{"_id": "hb-1", "agent_id": "agent-1", "user_id": "user-1", "timestamps": [], "prompt": "P", "notes_public": "not-a-bool"}]
        """#.data(using: .utf8)!

        let heartbeats = try JSONDecoder().decode([FSHeartbeat].self, from: json)

        XCTAssertEqual(heartbeats.count, 1)
        XCTAssertEqual(heartbeats.first?.notes_public, false,
                        "a present-but-malformed notes_public must also degrade to the default, not throw")
    }

    // MARK: 2 — fetchHeartbeats endpoint-tagged decode telemetry

    func test_fetchHeartbeats_genuinelyMalformedShape_decodeFails_returnsEmptyArray_andFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        // Real shape is a top-level array; a top-level object has no
        // unkeyed container for [FSHeartbeat] to decode into at all -- a
        // genuine structural failure, not a per-field-defaultable one.
        StubURLProtocol.stubBody = #"{"unexpected": "shape"}"#.data(using: .utf8)!

        let heartbeats = try await NetworkService.shared.fetchHeartbeats(userId: "user-1", agentId: "agent-1")

        XCTAssertTrue(heartbeats.isEmpty, "an undecodable heartbeats response must still fall back to an empty array")

        await waitForBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1,
                        "THE FIX: a fetchHeartbeats decode failure must no longer be silently swallowed -- it must fire exactly one beacon (this was the one sibling fetch 20260903-account-stats-not-loading's own fix missed)")
        XCTAssertEqual(beacons.first?.bodyJSON?["endpoint"] as? String,
                        "GET /agent/{user_id}/{agent_id}/heartbeats")
    }

    func test_fetchHeartbeats_wellFormedResponse_decodesCorrectly_andNeverFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        [{"_id": "hb-1", "agent_id": "agent-1", "user_id": "user-1", "timestamps": [], "prompt": "Reflect.", "notes_public": true}]
        """#.data(using: .utf8)!

        let heartbeats = try await NetworkService.shared.fetchHeartbeats(userId: "user-1", agentId: "agent-1")

        XCTAssertEqual(heartbeats.count, 1, "a well-formed heartbeats response must decode correctly")
        XCTAssertEqual(heartbeats.first?.notes_public, true)

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty, "a successful decode must never fire the beacon")
    }

    // MARK: 3 — regression guard: gracefully-defaulted != genuinely broken

    /// The exact missing-notes_public shape from test #1 above must NOT be
    /// treated as a decode failure at the NetworkService layer either -- it
    /// decodes fully successfully (per-field defaulted), so no beacon should
    /// fire. This is the behavioral proof that the fix changes the OUTCOME
    /// (real data shows, silently) not just adds logging on top of the same
    /// broken behavior.
    func test_fetchHeartbeats_missingNotesPublicColumnShape_decodesSuccessfully_neverFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        [
          {"_id": "hb-1", "agent_id": "agent-1", "user_id": "user-1", "timestamps": [], "prompt": "Colossians reflection"},
          {"_id": "hb-2", "agent_id": "agent-1", "user_id": "user-1", "timestamps": [], "prompt": "Ephesians reflection"},
          {"_id": "hb-3", "agent_id": "agent-1", "user_id": "user-1", "timestamps": [], "prompt": "Give me simple prompts..."}
        ]
        """#.data(using: .utf8)!

        let heartbeats = try await NetworkService.shared.fetchHeartbeats(userId: "user-1", agentId: "agent-1")

        XCTAssertEqual(heartbeats.count, 3,
                        "the real reported-bug response shape must now decode fully via fetchHeartbeats end to end")

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty,
                       "a missing-but-defaultable field must decode silently -- it is no longer a decode failure needing a beacon, distinguishing this from a genuinely broken response")
    }

    /// Data minimization (security preference profile): the beacon must
    /// never leak raw prompt content even when reporting a genuine failure
    /// on this endpoint.
    func test_fetchHeartbeats_decodeFailureBeacon_neverLeaksRawPromptContent() async throws {
        StubURLProtocol.stubStatusCode = 200
        // A top-level array of bare strings -- each element needs a keyed
        // container to become an FSHeartbeat, so this is a genuine
        // structural failure (not a per-field-defaultable one).
        StubURLProtocol.stubBody = #"["SECRET_PROMPT_CONTENT_MARKER"]"#.data(using: .utf8)!

        _ = try await NetworkService.shared.fetchHeartbeats(userId: "user-1", agentId: "agent-1")

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
            XCTAssertFalse(bodyString.contains("SECRET_PROMPT_CONTENT_MARKER"),
                            "the beacon must never include the raw response body content (e.g. a heartbeat's prompt text)")
        }
    }
}

// MARK: - AccountViewModel.load() events-failure coverage

@MainActor
final class AccountEventsLoadRegressionTests: XCTestCase {

    private func makeUser(_ id: String) -> FSUser {
        FSUser(user_id: id, username: "alice", email: "alice@example.com")
    }

    /// Before this task's fix, `(try? await service.fetchHeartbeats(...)) ?? []`
    /// silently swallowed a genuine per-agent fetch/decode failure exactly
    /// like the pre-fix notes/highlights/agents fetches did. This proves a
    /// real throw now feeds the same `statsFailed`/`statsMsg` path.
    func test_load_genuineHeartbeatsFetchFailure_setsStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-fail-user-1")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [
            FSAgent(id: "agent-1", user_id: user.user_id, name: "Guide", role: "guide", enabled: true, chats: [])
        ]
        service.fetchHeartbeatsErrorsByAgent["agent-1"] = AppError.networkError("simulated heartbeats fetch failure")

        await vm.load(service: service, user: user)

        XCTAssertNotNil(vm.statsMsg,
                         "THE FIX: a genuine fetchHeartbeats failure -- the one fetch 20260903-account-stats-not-loading's own fix missed -- must now surface statsMsg instead of looking identical to \"no events configured\"")
    }

    /// The extended alert copy (frontend gate step 4) must actually mention
    /// events, not just silently reuse the old notes/highlights/agents-only
    /// wording.
    func test_load_genuineHeartbeatsFailure_alertCopyMentionsEvents() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-copy-user-1")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [
            FSAgent(id: "agent-1", user_id: user.user_id, name: "Guide", role: "guide", enabled: true, chats: [])
        ]
        service.fetchHeartbeatsErrorsByAgent["agent-1"] = AppError.networkError("simulated failure")

        await vm.load(service: service, user: user)

        XCTAssertTrue(vm.statsMsg?.lowercased().contains("event") ?? false,
                       "the alert copy extended for this task must actually mention events, got: \(vm.statsMsg ?? "nil")")
    }

    /// A failure on ONE agent's heartbeats must not wipe out another
    /// agent's real, successfully-fetched events -- proves the per-agent
    /// withTaskGroup failure handling is additive (flags statsFailed), not
    /// destructive to the whole `events` array.
    func test_load_partialHeartbeatsFailure_stillShowsSucceedingAgentsRealEvents() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-partial-user-1")
        let agentOK  = FSAgent(id: "agent-ok",  user_id: user.user_id, name: "Guide A", role: "guide", enabled: true, chats: [])
        let agentBad = FSAgent(id: "agent-bad", user_id: user.user_id, name: "Guide B", role: "guide", enabled: true, chats: [])
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agentOK, agentBad]
        let realHeartbeat = FSHeartbeat(
            id: "hb-real", agent_id: "agent-ok", user_id: user.user_id,
            timestamps: Array(repeating: "13:00", count: 31),
            prompt: "Reflect on Colossians.", group_id: nil
        )
        service.fetchHeartbeatsResultsByAgent["agent-ok"] = [realHeartbeat]
        service.fetchHeartbeatsErrorsByAgent["agent-bad"] = AppError.networkError("simulated failure")

        await vm.load(service: service, user: user)

        XCTAssertNotNil(vm.statsMsg, "the failing agent's events fetch must still surface statsMsg")
        XCTAssertEqual(vm.events.map(\.id), ["hb-real"],
                        "the SUCCEEDING agent's real event must still show -- a partial per-agent failure must not wipe data that loaded fine")
    }

    /// Regression / no-false-positive: a completely normal multi-agent load
    /// must aggregate every agent's events and never show the failure
    /// banner.
    func test_load_normalMultiAgentSuccess_aggregatesAllEvents_neverSetsStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-success-user-1")
        let agentA = FSAgent(id: "agent-a", user_id: user.user_id, name: "Guide A", role: "guide", enabled: true, chats: [])
        let agentB = FSAgent(id: "agent-b", user_id: user.user_id, name: "Guide B", role: "guide", enabled: true, chats: [])
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agentA, agentB]
        service.fetchHeartbeatsResultsByAgent["agent-a"] = [
            FSHeartbeat(id: "hb-a1", agent_id: "agent-a", user_id: user.user_id, prompt: "P1")
        ]
        service.fetchHeartbeatsResultsByAgent["agent-b"] = [
            FSHeartbeat(id: "hb-b1", agent_id: "agent-b", user_id: user.user_id, prompt: "P2"),
            FSHeartbeat(id: "hb-b2", agent_id: "agent-b", user_id: user.user_id, prompt: "P3"),
        ]

        await vm.load(service: service, user: user)

        XCTAssertNil(vm.statsMsg, "a normal successful multi-agent load must never show the failure banner")
        XCTAssertEqual(Set(vm.events.map(\.id)), Set(["hb-a1", "hb-b1", "hb-b2"]),
                        "events across every agent must aggregate into a single list")
    }

    /// Regression: an account with agents but genuinely zero configured
    /// events (real empty array from every agent, no error) must still
    /// render as empty -- proves the fix didn't turn a real "no events"
    /// account into a false failure banner.
    func test_load_realZeroEvents_noAgentFailure_showsEmptyWithNoBanner() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-zero-user-1")
        let agent = FSAgent(id: "agent-1", user_id: user.user_id, name: "Guide", role: "guide", enabled: true, chats: [])
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent]
        service.fetchHeartbeatsResultsByAgent["agent-1"] = []

        await vm.load(service: service, user: user)

        XCTAssertNil(vm.statsMsg, "a real zero-events account must not show the failure banner")
        XCTAssertTrue(vm.events.isEmpty)
    }
}
