// HeartbeatManualTriggerTests.swift — regression coverage for
// task: 20260901-heartbeat-manual-trigger-button (testing step), updated for
// task: 20260901-heartbeat-manual-force-fire (testing step 4).
//
// Frontend step 1 added AccountViewModel.fireHeartbeatNow(_:), a per-row
// "execute now" trigger (EventRow's yellow play.fill button in
// AccountView.swift) wired to service.commitHeartbeat(userId:agentId:
// heartbeatId:prompt:). This suite proves the CLIENT correctly distinguishes
// commitHeartbeat's possible outcomes into this screen's existing alert
// conventions, rather than collapsing them into one generic message, plus
// the in-flight double-tap guard:
//
//   1. success                        -> eventFireMsg(.success, ...) +
//                                         refreshUsage() (proven via the new
//                                         fetchUsageCallCount seam above).
//   2. {"skipped": "a forced fire...  -> eventFireMsg(.warning, ...), a
//       already in progress"}            non-error banner, NOT limitMsg/
//                                         agentMsg, and does NOT refresh usage
//                                         (nothing was actually fired). As of
//                                         20260901-heartbeat-manual-force-fire,
//                                         this call site always sends
//                                         force:true (see MARK 7 below), so
//                                         the server's daily "already fired
//                                         today" claim can no longer produce
//                                         this outcome for a manual tap — the
//                                         only remaining {"skipped": ...} case
//                                         is the narrower same-instant
//                                         concurrent-forced-fire race
//                                         (backend.json's advisory-lock
//                                         guard). The client's copy for this
//                                         case ("Already firing — try again
//                                         in a moment.") was proposed in
//                                         frontend.json and approved by the
//                                         user as-is.
//   3. in-band {"error": "..."} (200)  -> agentMsg, not limitMsg/eventFireMsg.
//   4. AppError.limitReached (403)     -> limitMsg (the existing "Free Plan
//                                         Limit" alert createEvent also
//                                         uses), not agentMsg/eventFireMsg.
//   5. any other thrown error          -> agentMsg (the existing "Agent
//                                         Error" alert), not limitMsg.
//   6. two concurrent fires for the SAME heartbeat -> the service is only
//      actually called once; the second call is a synchronous no-op guarded
//      by firingHeartbeatIds, proven by racing two calls with async let.
//   7. NetworkService.commitHeartbeat's actual outgoing HTTP request body
//      really does include "force": true -> proven directly against
//      NetworkService (not the ThrowingTestDataService protocol fake used by
//      1-6, which has no `force` parameter to observe — force is hardcoded
//      inside NetworkService's implementation, so only a request-level
//      assertion via StubURLProtocol can see it).
//
// Uses the ThrowingTestDataService seam (defined in AppStateAuthAccountTests
// .swift): commitHeartbeatResult/commitHeartbeatError/commitHeartbeatCallCountForId,
// left in place from the now-removed client-side HeartbeatScheduler and still
// valid DataServiceProtocol conformance/seam for this feature's new caller.
//
// MARK 7 uses StubURLProtocol (defined in NetworkServiceGetErrorHandlingTests
// .swift, same test target) to intercept the real NetworkService request.

import XCTest
@testable import FellowScript

@MainActor
final class HeartbeatManualTriggerTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
    }

    private func makeProfile() -> FSUser {
        FSUser(user_id: MockDataService.mockUser.user_id,
               username: MockDataService.mockUser.username,
               email: MockDataService.mockUser.email)
    }

    private func makeEvent(id: String = "hb-1") -> FSHeartbeat {
        FSHeartbeat(id: id, agent_id: "agent-1", user_id: MockDataService.mockUser.user_id,
                    timestamps: Array(repeating: nil, count: 31), prompt: "Reflect on today.")
    }

    // MARK: 1 — success

    func test_fireHeartbeatNow_success_showsConfirmationAndRefreshesUsage() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.commitHeartbeatResult = ["success": "saved note"]
        vm.service = service

        let event = makeEvent()
        await vm.fireHeartbeatNow(event)

        XCTAssertEqual(vm.eventFireMsg?.type, .success, "a successful fire must show the success confirmation banner")
        XCTAssertEqual(service.fetchUsageCallCount, 1, "a successful fire must refresh usage, mirroring createEvent's refreshUsage() call")
        XCTAssertNil(vm.limitMsg, "success must not surface the Free Plan Limit alert")
        XCTAssertNil(vm.agentMsg, "success must not surface the Agent Error alert")
        XCTAssertFalse(vm.firingHeartbeatIds.contains(event.id), "the in-flight guard must clear once the request completes")
    }

    // MARK: 2 — {"skipped": "a forced fire for this event is already in progress"}
    //
    // Replaces the old "already fired today" skip scenario: that outcome can
    // no longer occur for this call site now that NetworkService.commitHeartbeat
    // always sends force:true (MARK 7 below) — the backend's daily claim is
    // bypassed entirely for a manual tap. The only skip reason the server can
    // still return here is its narrower same-instant concurrent-forced-fire
    // guard (backend.json's pg_try_advisory_lock path), so this test uses
    // that realistic server response and asserts the client's now-accurate
    // "Already firing — try again in a moment." copy (approved as-is by the
    // user, see frontend.json).

    func test_fireHeartbeatNow_forcedFireAlreadyInProgress_showsNonErrorBanner_notAlert() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.commitHeartbeatResult = ["skipped": "a forced fire for this event is already in progress"]
        vm.service = service

        let event = makeEvent()
        await vm.fireHeartbeatNow(event)

        XCTAssertEqual(vm.eventFireMsg?.type, .warning, "a same-instant forced-fire-in-progress skip must be a distinct, non-alarming banner state")
        XCTAssertEqual(vm.eventFireMsg?.text, "Already firing — try again in a moment.",
                       "the client's copy must reflect the new, narrower skip reason, not the old 'already fired today' wording, which is no longer an accurate or reachable outcome for this always-forced call site")
        XCTAssertNil(vm.limitMsg, "a skip must never be surfaced as a Free Plan Limit rejection")
        XCTAssertNil(vm.agentMsg, "a skip must never be surfaced as an Agent Error — it is not a failure")
        XCTAssertEqual(service.fetchUsageCallCount, 0, "nothing was actually fired on a skip, so usage must not be refreshed")
        XCTAssertFalse(vm.firingHeartbeatIds.contains(event.id))
    }

    // MARK: 3 — in-band {"error": ...} on a 200 response

    func test_fireHeartbeatNow_inBandServerError_surfacesAgentMsg_notLimitMsgOrBanner() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.commitHeartbeatResult = ["error": "Agent could not respond."]
        vm.service = service

        let event = makeEvent()
        await vm.fireHeartbeatNow(event)

        XCTAssertEqual(vm.agentMsg, "Agent could not respond.", "an in-band error body must surface through the existing Agent Error alert")
        XCTAssertNil(vm.limitMsg)
        XCTAssertNil(vm.eventFireMsg, "an in-band error is a failure, not the success/skip banner")
        XCTAssertFalse(vm.firingHeartbeatIds.contains(event.id))
    }

    // MARK: 4 — 403 notes-cap rejection

    func test_fireHeartbeatNow_notesCapExceeded_surfacesLimitMsg_notAgentMsg() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.commitHeartbeatError = AppError.limitReached(resource: "notes", used: 10, limit: 10)
        vm.service = service

        let event = makeEvent()
        await vm.fireHeartbeatNow(event)

        XCTAssertNotNil(vm.limitMsg, "a 403 notes-cap rejection must route through the existing limitMsg/'Free Plan Limit' alert")
        XCTAssertTrue(vm.limitMsg?.localizedCaseInsensitiveContains("free plan limit") ?? false)
        XCTAssertNil(vm.agentMsg, "a notes-cap rejection must not ALSO show as a generic Agent Error")
        XCTAssertNil(vm.eventFireMsg)
        XCTAssertFalse(vm.firingHeartbeatIds.contains(event.id), "the in-flight guard must clear even on failure")
    }

    // MARK: 5 — any other network/server error

    func test_fireHeartbeatNow_genericNetworkError_surfacesAgentMsg_notLimitMsg() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.commitHeartbeatError = AppError.networkError("Server error 500")
        vm.service = service

        let event = makeEvent()
        await vm.fireHeartbeatNow(event)

        XCTAssertNotNil(vm.agentMsg, "a generic failure must route through the existing Agent Error alert")
        XCTAssertNil(vm.limitMsg, "a generic failure must not be mistaken for the notes-cap rejection")
        XCTAssertNil(vm.eventFireMsg)
        XCTAssertFalse(vm.firingHeartbeatIds.contains(event.id))
    }

    /// Non-AppError failures (e.g. a raw URLError) must also fall through to
    /// agentMsg, matching every sibling method's `catch` fallback in this
    /// file (removeEvent/updateEvent/toggleAgent/etc.).
    func test_fireHeartbeatNow_nonAppErrorFailure_stillSurfacesAgentMsg() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.commitHeartbeatError = URLError(.badServerResponse)
        vm.service = service

        let event = makeEvent()
        await vm.fireHeartbeatNow(event)

        XCTAssertNotNil(vm.agentMsg)
        XCTAssertNil(vm.limitMsg)
    }

    // MARK: 6 — double-tap / in-flight guard

    func test_fireHeartbeatNow_concurrentCallsForSameHeartbeat_onlyFiresServiceOnce() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        // A real suspension inside the mocked network call (see this seam's
        // doc comment) so the two racing calls genuinely overlap instead of
        // serializing end-to-end — without it, the first call can finish and
        // clear firingHeartbeatIds before the second one ever starts, which
        // would make this test pass even with the guard deleted.
        service.commitHeartbeatDelayNanoseconds = 100_000_000
        vm.service = service

        let event = makeEvent()

        // Races two calls for the exact same heartbeat. fireHeartbeatNow's
        // guard-then-insert into firingHeartbeatIds happens synchronously
        // before its first `await`, so the second call (scheduled onto the
        // same MainActor) must observe the id already present and return
        // immediately without ever calling the service a second time.
        async let first: Void = vm.fireHeartbeatNow(event)
        async let second: Void = vm.fireHeartbeatNow(event)
        _ = await (first, second)

        XCTAssertEqual(service.commitHeartbeatCallCountForId[event.id], 1,
                        "a second fire for the same in-flight heartbeat must be a no-op, not race a duplicate request")
        XCTAssertFalse(vm.firingHeartbeatIds.contains(event.id), "the guard must clear once the single in-flight request completes")
    }

    /// Firing two DIFFERENT heartbeats concurrently must not interfere with
    /// each other — the guard is keyed per heartbeat id, not global.
    func test_fireHeartbeatNow_concurrentCallsForDifferentHeartbeats_bothFire() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        vm.service = service

        let eventA = makeEvent(id: "hb-a")
        let eventB = makeEvent(id: "hb-b")

        async let first: Void = vm.fireHeartbeatNow(eventA)
        async let second: Void = vm.fireHeartbeatNow(eventB)
        _ = await (first, second)

        XCTAssertEqual(service.commitHeartbeatCallCountForId["hb-a"], 1)
        XCTAssertEqual(service.commitHeartbeatCallCountForId["hb-b"], 1)
        XCTAssertEqual(vm.eventFireMsg?.type, .success)
    }

    // MARK: 7 — NetworkService.commitHeartbeat's real outgoing request body
    // includes "force": true.
    //
    // Tests 1-6 above exercise AccountViewModel.fireHeartbeatNow through the
    // ThrowingTestDataService protocol fake, which has no `force` parameter
    // for a test to inspect — force:true is hardcoded inside NetworkService's
    // own implementation (NetworkService.swift's commitHeartbeat), not
    // threaded through DataServiceProtocol. So this test bypasses the fake
    // entirely and calls the real NetworkService.shared.commitHeartbeat
    // against a stubbed HTTP layer, proving the actual bytes sent to the
    // server carry force:true unconditionally -- the concrete client-side
    // guarantee behind this task's force-fire contract.

    func test_networkServiceCommitHeartbeat_alwaysSendsForceTrue_inRequestBody() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"success": "saved note"}"#.data(using: .utf8)!

        _ = try await NetworkService.shared.commitHeartbeat(
            userId: "user-1", agentId: "agent-1", heartbeatId: "hb-1", prompt: "Reflect on today.")

        let last = try XCTUnwrap(StubURLProtocol.requestLog.last)
        XCTAssertEqual(last.path, "/api/agent/user-1/agent-1/hb-1/commit_heartbeat")
        XCTAssertEqual(last.method, "POST")
        let body = try XCTUnwrap(last.bodyJSON, "commitHeartbeat must send a JSON body")
        XCTAssertEqual(body["force"] as? Bool, true,
                       "the manual trigger's client is the sole caller of this method app-wide, and per this task must always force-fire, so every request it sends must carry force:true regardless of same-day claim state")
        XCTAssertEqual(body["prompt"] as? String, "Reflect on today.")
    }

    func test_networkServiceCommitHeartbeat_serverSkipsInProgressForcedFire_returnsSkippedKey() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"skipped": "a forced fire for this event is already in progress"}"#.data(using: .utf8)!

        let result = try await NetworkService.shared.commitHeartbeat(
            userId: "user-1", agentId: "agent-1", heartbeatId: "hb-1", prompt: "Reflect on today.")

        XCTAssertEqual(result["skipped"], "a forced fire for this event is already in progress",
                       "the real decode path must surface the server's new, narrower skip reason unchanged, still carrying force:true on the request that produced it")
        let last = try XCTUnwrap(StubURLProtocol.requestLog.last)
        XCTAssertEqual(last.bodyJSON?["force"] as? Bool, true)
    }
}
