// VoipCallManagerLifecycleTests.swift — testing-gate coverage for task
// 20260916-callkit-voip-ring, step 4 (testing).
//
// Covers what frontend.json (step 2) implemented and security.json (step 3)
// reviewed on the iOS side: PKPushRegistry/CXProvider wiring
// (Services/VoipCallManager.swift), the two new AppState methods it drives
// (registerVoipDeviceToken(_:), registerCachedVoipTokenIfNeeded()), and
// CallController's new ringDeliveryNotice fallback toast.
//
// Directly-driven behavioral tests (real production types, no source-pinning)
// cover everything reachable without needing a genuine PKPushCredentials or
// CallKit-assigned call UUID -- neither of which this task's own code (nor
// Apple's frameworks) exposes a way to construct/observe from a test target:
//   1. AppState.registerVoipDeviceToken(_:) — calls through with the right
//      (userId, token); a rejected/failed registration doesn't crash/hang the
//      fire-and-forget Task (mirrors AppStateRegisterDeviceTokenErrorHandling-
//      Tests' coverage of the plain-APNs sibling exactly); no-op when signed
//      out.
//   2. CallController.showRingDeliveryNotice(_:) — the custom fallback toast
//      for "CallKit itself failed to report the incoming call" (per UI/UX
//      Q12.1/Q12.3 — CallKit's own ring UI is system-provided, but this
//      fallback is not) — sets then self-clears, mirroring
//      showSummarizeNotice's already-tested shape.
//
// Source-pinning tests (this codebase's established technique — see
// ChatPushDeepLinkTapTests.swift/ChimeCallBackgroundPersistenceRegressionTests
// .swift's own headers — for logic that can't be constructed/driven directly
// in XCTest: here, `PKPushCredentials` has no public initializer anywhere in
// PushKit, and the CallKit-assigned call `UUID` `VoipCallManager` generates
// internally on a real incoming push is never exposed to a caller, so a test
// target cannot mint the exact identity needed to drive
// `provider(_:perform: CXAnswerCallAction)`'s real happy path from outside)
// cover the fail-closed/no-orphaned-state guarantees this step's charter asks
// for directly on the source:
//   3. A malformed VoIP push payload (missing devotion_id/group_id) reports a
//      placeholder call and immediately ends it with reason `.failed` —
//      never lets the payload's own claims (caller name, etc.) drive what's
//      displayed/actionable, and is never added to `activeCalls` at all, so a
//      subsequent CXAnswerCallAction for that UUID can find nothing to act on.
//   4. A well-formed payload records the ring target BEFORE calling
//      `reportNewIncomingCall` (so a race between the report's completion and
//      an answer can't miss it), and only schedules the ring-timeout timer
//      once CallKit's own report succeeded (never on a reporting failure).
//   5. `provider(_:perform: CXAnswerCallAction)` posts `.ringPushTapped`
//      (reusing AppState.joinRingedCall's EXISTING join path — no new/
//      parallel join logic) and clears both the timeout timer and the
//      activeCalls entry for that UUID.
//   6. `provider(_:perform: CXEndCallAction)` (covers both an explicit
//      decline and the self-issued ring-timeout end) and `providerDidReset`
//      both clear all bookkeeping — the "no orphaned CXProvider call state
//      left behind in any outcome" bar this step's charter names explicitly.
//   7. A CallKit reporting failure (reportNewIncomingCall's completion error)
//      surfaces via CallController.showRingDeliveryNotice, not a crash and
//      not a second, competing system-style notification.
//   8. Info.plist still declares BOTH `audio` (from
//      20260916-call-background-persistence) and the new `voip` background
//      mode — additive, neither entry silently dropped for the other.
//   9. FellowScriptApp's `.onReceive(.voipTokenReceived)` wiring calls
//      `appState.registerVoipDeviceToken(_:)`, and AppDelegate constructs
//      `VoipCallManager.shared` eagerly at launch (not deferred behind the
//      lazy push-permission flow — PushKit needs no user-permission prompt).

import XCTest
@testable import FellowScript

@MainActor
final class VoipCallManagerLifecycleTests: XCTestCase {

    override func tearDown() async throws {
        let call = CallController.shared
        call.ringDeliveryNotice = nil
        try await super.tearDown()
    }

    private func makeSignedInAppState(service: ThrowingTestDataService, userId: String = "user-123") -> AppState {
        let appState = AppState(service: service)
        appState.currentUser = FSUser(user_id: userId, username: "alice", email: "alice@example.com")
        appState.isAuthenticated = true
        return appState
    }

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func voipCallManagerSource() throws -> String {
        try readSource("FellowScript/Services/VoipCallManager.swift")
    }

    // MARK: 1 — AppState.registerVoipDeviceToken(_:)

    func test_registerVoipDeviceToken_callsService_withCorrectArgs() async throws {
        let service = ThrowingTestDataService()
        let appState = makeSignedInAppState(service: service)

        appState.registerVoipDeviceToken("voip-token-abc")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(service.registerVoipDeviceTokenCallCount, 1)
        XCTAssertEqual(service.lastRegisterVoipDeviceTokenArgs?.userId, "user-123")
        XCTAssertEqual(service.lastRegisterVoipDeviceTokenArgs?.token, "voip-token-abc")
    }

    func test_registerVoipDeviceToken_doesNotCrash_whenServerCallFails() async throws {
        let service = ThrowingTestDataService()
        service.registerVoipDeviceTokenError = AppError.networkError("Failed to save VoIP token")
        let appState = makeSignedInAppState(service: service)

        appState.registerVoipDeviceToken("voip-token-xyz")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(service.registerVoipDeviceTokenCallCount, 1,
                       "the failing registration attempt must still have been made, not skipped")
        XCTAssertEqual(service.lastRegisterVoipDeviceTokenArgs?.token, "voip-token-xyz")
        // Reaching this point without a crash/hang is itself the assertion
        // that matters most for this fire-and-forget, no-UI-surface path.
    }

    func test_registerVoipDeviceToken_isNoOp_whenNotSignedIn() async throws {
        let service = ThrowingTestDataService()
        let appState = AppState(service: service)
        appState.currentUser = nil

        appState.registerVoipDeviceToken("voip-token-should-not-send")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(service.registerVoipDeviceTokenCallCount, 0)
    }

    // MARK: 2 — CallController.showRingDeliveryNotice(_:) self-dismissing toast

    func test_showRingDeliveryNotice_setsThenSelfClearsAfterDelay() async throws {
        let call = CallController.shared
        call.ringDeliveryNotice = nil

        call.showRingDeliveryNotice("Someone tried to ring you, but the call screen couldn't be shown.")
        XCTAssertEqual(call.ringDeliveryNotice, "Someone tried to ring you, but the call screen couldn't be shown.")

        // Mirrors CallControllerSummarizeRegressionTests' own real-sleep
        // pattern for showSummarizeNotice's identical 4-second self-clear.
        try await Task.sleep(nanoseconds: 4_500_000_000)
        XCTAssertNil(call.ringDeliveryNotice, "the notice must self-clear after its display window")
    }

    func test_showRingDeliveryNotice_fastSecondNotice_isNotClobberedByFirstsTimer() async throws {
        let call = CallController.shared
        call.ringDeliveryNotice = nil

        call.showRingDeliveryNotice("first notice")
        // A comfortable 2s gap before the second call, so the two 4s
        // self-clear windows (first: ~[0,4s], second: ~[2s,6s]) don't
        // overlap at the single instant this test samples them.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        call.showRingDeliveryNotice("second notice")

        // Sampled at ~4.5s from the FIRST call (~2.5s from the second) --
        // strictly after the first notice's own 4s timer would have fired
        // (and must NOT have cleared the second, still-current notice), and
        // strictly before the second notice's own 4s timer fires (~6s from
        // the first call).
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(call.ringDeliveryNotice, "second notice")
    }

    // MARK: 3 — Malformed payload: fail-closed report-then-immediately-end,
    // never added to activeCalls (source-pinned — see file header).

    func test_didReceiveIncomingPush_malformedPayload_reportsThenImmediatelyEndsCall_neverTrustsPayloadClaims() throws {
        let source = try voipCallManagerSource()
        guard let range = source.range(of: "func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload") else {
            XCTFail("didReceiveIncomingPushWith not found"); return
        }
        let body = String(source[range.upperBound...])

        guard let guardRange = body.range(of: "guard let devotionId, let groupId, !devotionId.isEmpty, !groupId.isEmpty else {") else {
            XCTFail("malformed-payload guard clause not found"); return
        }
        let afterGuard = String(body[guardRange.upperBound...])
        let guardBlockEnd = afterGuard.range(of: "\n        }\n\n        activeCalls[uuid]")?.lowerBound ?? afterGuard.endIndex
        let guardBlockBody = String(afterGuard[..<guardBlockEnd])

        XCTAssertTrue(guardBlockBody.contains("reportNewIncomingCall"),
                      "Apple's hard contract: every VoIP push must result in exactly one reportNewIncomingCall, even for an unparseable payload")
        XCTAssertTrue(guardBlockBody.contains("reportCall(with: uuid, endedAt: nil, reason: .failed)"),
                      "a malformed payload must be ended immediately, not left ringing on a placeholder call")
        XCTAssertFalse(guardBlockBody.contains("activeCalls[uuid] ="),
                       "a malformed/unrecognized payload must NEVER be added to activeCalls -- fail-closed means "
                       + "nothing from an unverified payload can later be 'answered' into the join flow")

        // The activeCalls assignment must happen strictly AFTER (not inside)
        // the malformed-payload early-return branch.
        guard let activeCallsAssignRange = body.range(of: "activeCalls[uuid] = RingPushTarget(") else {
            XCTFail("well-formed-path activeCalls assignment not found"); return
        }
        XCTAssertTrue(guardRange.upperBound < activeCallsAssignRange.lowerBound,
                      "the well-formed activeCalls bookkeeping must be reachable only after the malformed-payload guard")
    }

    // MARK: 4 — Well-formed payload: activeCalls recorded before reporting;
    // timeout scheduled only on a successful report (source-pinned).

    func test_didReceiveIncomingPush_wellFormedPayload_recordsTargetBeforeReporting_andSchedulesTimeoutOnlyOnSuccess() throws {
        let source = try voipCallManagerSource()
        guard let assignRange = source.range(of: "activeCalls[uuid] = RingPushTarget(devotionId: devotionId, groupId: groupId)") else {
            XCTFail("activeCalls assignment not found"); return
        }
        guard let reportRange = source.range(of: "reportNewIncomingCall(with: uuid, update: update) { [weak self] error in") else {
            XCTFail("reportNewIncomingCall call (well-formed path) not found"); return
        }
        XCTAssertTrue(assignRange.upperBound < reportRange.lowerBound,
                      "activeCalls must be populated BEFORE reportNewIncomingCall is called, so a race between "
                      + "the report's completion and an answer can never miss the target")

        let afterReport = String(source[reportRange.upperBound...])
        guard let errorBranchEnd = afterReport.range(of: "self.scheduleRingTimeout")?.lowerBound else {
            XCTFail("scheduleRingTimeout call not found"); return
        }
        let errorBranchBody = String(afterReport[..<errorBranchEnd])
        XCTAssertTrue(errorBranchBody.contains("if let error"),
                      "must branch on the report completion's error before deciding whether to schedule a timeout")
        XCTAssertTrue(errorBranchBody.contains("self.activeCalls[uuid] = nil"),
                      "a genuine CallKit reporting failure must clear the just-added activeCalls entry -- no "
                      + "orphaned bookkeeping for a call CallKit itself never actually presented")
        XCTAssertTrue(errorBranchBody.contains("showRingDeliveryNotice"),
                      "a CallKit reporting failure must surface via the custom fallback notice (UI/UX Q12.1/Q12.3)")
        XCTAssertTrue(errorBranchBody.contains("return"),
                      "the error branch must return before falling through to schedule a timeout for a call that "
                      + "was never actually presented")
    }

    // MARK: 5 — CXAnswerCallAction: posts .ringPushTapped (existing join path), clears bookkeeping

    func test_performAnswerCallAction_postsRingPushTapped_andClearsBookkeeping() throws {
        let source = try voipCallManagerSource()
        guard let range = source.range(of: "func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {") else {
            XCTFail("CXAnswerCallAction handler not found"); return
        }
        let end = source.range(of: "\n    }\n\n    func provider(_ provider: CXProvider, perform action: CXEndCallAction)", range: range.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[range.upperBound..<end])

        XCTAssertTrue(body.contains(".ringPushTapped"),
                      "answering must reuse the EXISTING .ringPushTapped notification/join path "
                      + "(AppState.joinRingedCall -> CallController.start) -- no new/parallel join logic")
        XCTAssertFalse(body.contains("CallController.shared.start"),
                       "must not call CallController.start directly -- must go through the SAME "
                       + ".ringPushTapped -> AppState.joinRingedCall route a tapped plain-push ring already uses")
        XCTAssertTrue(body.contains("ringTimeoutTimers[action.callUUID]?.invalidate()"),
                      "answering must invalidate any pending ring-timeout timer for this call")
        XCTAssertTrue(body.contains("activeCalls[action.callUUID] = nil"),
                      "answering must clear the activeCalls entry -- no orphaned bookkeeping after answer")
        XCTAssertTrue(body.contains("action.fulfill()"),
                      "must fulfill the CXAnswerCallAction -- CallKit requires this for every action")
    }

    // MARK: 6 — CXEndCallAction (decline + self-issued timeout) and
    // providerDidReset both fully clear bookkeeping (no orphaned state).

    func test_performEndCallAction_clearsAllBookkeeping_coversBothDeclineAndTimeout() throws {
        let source = try voipCallManagerSource()
        guard let range = source.range(of: "func provider(_ provider: CXProvider, perform action: CXEndCallAction) {") else {
            XCTFail("CXEndCallAction handler not found"); return
        }
        let end = source.range(of: "\n    }\n\n    // No audio-session handling", range: range.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[range.upperBound..<end])

        XCTAssertTrue(body.contains("ringTimeoutTimers[action.callUUID]?.invalidate()"))
        XCTAssertTrue(body.contains("activeCalls[action.callUUID] = nil"))
        XCTAssertTrue(body.contains("action.fulfill()"))

        // This handler's own body must still document itself as the single
        // convergence point for BOTH outcomes -- regression guard against a
        // future change accidentally splitting decline/timeout into two
        // divergent code paths (which is exactly how orphaned state bugs
        // like this creep in).
        XCTAssertTrue(body.contains("Covers BOTH an explicit decline"),
                      "the both-decline-and-timeout convergence comment was removed or reworded -- re-verify "
                      + "CXEndCallAction still handles both outcomes in one place")
    }

    func test_providerDidReset_clearsAllTimersAndActiveCalls() throws {
        let source = try voipCallManagerSource()
        guard let range = source.range(of: "func providerDidReset(_ provider: CXProvider) {") else {
            XCTFail("providerDidReset not found"); return
        }
        let end = source.range(of: "\n    }\n\n    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction)", range: range.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[range.upperBound..<end])

        XCTAssertTrue(body.contains("ringTimeoutTimers.values.forEach { $0.invalidate() }"))
        XCTAssertTrue(body.contains("ringTimeoutTimers.removeAll()"))
        XCTAssertTrue(body.contains("activeCalls.removeAll()"))
    }

    // MARK: 7 — CallKit reporting failure surfaces via the custom fallback
    // toast, not a crash or a second competing notification mechanism.

    func test_reportingFailure_surfacesOnlyViaShowRingDeliveryNotice_notASecondNotificationPath() throws {
        let source = try voipCallManagerSource()
        guard let reportRange = source.range(of: "reportNewIncomingCall(with: uuid, update: update) { [weak self] error in") else {
            XCTFail("well-formed reportNewIncomingCall not found"); return
        }
        let afterReport = String(source[reportRange.upperBound...])
        guard let errorEnd = afterReport.range(of: "self.scheduleRingTimeout")?.lowerBound else {
            XCTFail("could not isolate the error branch"); return
        }
        let errorBranch = String(afterReport[..<errorEnd])

        XCTAssertTrue(errorBranch.contains("CallController.shared.showRingDeliveryNotice"))
        XCTAssertFalse(errorBranch.contains("NotificationCenter.default.post"),
                       "a CallKit reporting failure must not ALSO post a NotificationCenter event -- exactly one "
                       + "user-facing surface (the custom toast), not two competing mechanisms")
    }

    // MARK: 8 — Info.plist: `voip` added additively alongside `audio`

    func test_infoPlist_declaresVoipBackgroundMode_alongsideExistingAudioAndRemoteNotification() throws {
        let source = try readSource("FellowScript/Info.plist")
        guard let range = source.range(of: "<key>UIBackgroundModes</key>") else {
            XCTFail("UIBackgroundModes key not found in Info.plist"); return
        }
        let body = String(source[range.upperBound...].prefix(300))
        XCTAssertTrue(body.contains("<string>remote-notification</string>"))
        XCTAssertTrue(body.contains("<string>audio</string>"),
                      "the audio background mode from 20260916-call-background-persistence must not be dropped")
        XCTAssertTrue(body.contains("<string>voip</string>"),
                      "the new voip background mode this task adds must be declared")
    }

    // MARK: 9 — FellowScriptApp/AppDelegate wiring

    func test_appDelegate_didFinishLaunching_constructsVoipCallManagerEagerly() throws {
        let source = try readSource("FellowScript/FellowScriptApp.swift")
        guard let range = source.range(of: "didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {") else {
            XCTFail("didFinishLaunchingWithOptions not found"); return
        }
        let body = String(source[range.upperBound...].prefix(600))
        XCTAssertTrue(body.contains("VoipCallManager.shared"),
                      "VoipCallManager must be constructed eagerly at launch, not deferred behind the lazy "
                      + "push-permission flow -- PushKit needs no user-permission prompt")
    }

    func test_voipTokenReceived_onReceive_callsRegisterVoipDeviceToken() throws {
        let source = try readSource("FellowScript/FellowScriptApp.swift")
        guard let range = source.range(of: ".onReceive(NotificationCenter.default.publisher(for: .voipTokenReceived)) { note in") else {
            XCTFail(".onReceive(.voipTokenReceived) not found"); return
        }
        let body = String(source[range.upperBound...].prefix(200))
        XCTAssertTrue(body.contains("appState.registerVoipDeviceToken(token)"))
    }
}
