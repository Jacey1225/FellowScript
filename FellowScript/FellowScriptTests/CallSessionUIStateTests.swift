// CallSessionUIStateTests.swift — testing-gate coverage for task
// 20261009-session-ui-redesign, step 4 (parts 1-3 + the receive side of
// screen share).
//
// Behavioral tests drive the real pure types from Chat/CallSessionUIState.swift
// (no Chime SDK, no SwiftUI hosting): the submenu state machine, field-vs-row
// layout selection and share-vs-prompts precedence, the bubble roster and
// attendee-to-name resolution, the breathing-background gating truth table and
// easing math, and content-share bookkeeping.
//
// The SwiftUI view bodies and the SDK-gated ChimeCallManager cannot be hosted
// in a unit test, so VoiceOver labels, the mute badge, the Reduce Motion /
// scene-phase wiring, and "a content-share tile is never a camera bubble" are
// pinned against the shipped source, following this project's established
// technique (see ChimeCallViewRedesignRegressionTests). Real Chime A/V and
// content-share receive are NOT simulator-verifiable; see testing.json for the
// manual two-device script.

import XCTest
import SwiftUI
@testable import FellowScript

// MARK: - Source helper

private func callSource(_ relativePath: String, file: StaticString = #filePath) throws -> String {
    let url = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()   // FellowScriptTests/
        .deletingLastPathComponent()   // project root
        .appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - A. Interactions (submenu) state machine

final class CallInteractionsStateTests: XCTestCase {

    func test_initialState_collapsedAndPromptsClosed() {
        let s = CallInteractionsState()
        XCTAssertFalse(s.isExpanded)
        XCTAssertFalse(s.promptsOpen)
    }

    func test_toggleExpanded_opensThenCloses() {
        var s = CallInteractionsState()
        s.toggleExpanded(); XCTAssertTrue(s.isExpanded)
        s.toggleExpanded(); XCTAssertFalse(s.isExpanded)
    }

    func test_collapse_closesButLeavesPromptsAlone() {
        var s = CallInteractionsState(isExpanded: true, promptsOpen: true)
        s.collapse()
        XCTAssertFalse(s.isExpanded)
        XCTAssertTrue(s.promptsOpen, "outside-tap dismissal must not close the prompts panel")
    }

    func test_muteAndCameraTaps_keepSubmenuOpen() {
        var s = CallInteractionsState(isExpanded: true)
        s.didTapToggleItem()
        XCTAssertTrue(s.isExpanded, "Mute/Camera keep the menu open so they stay quick to flip")
        s.didTapToggleItem()
        XCTAssertTrue(s.isExpanded)
    }

    func test_promptsTap_closesSubmenuAndFlipsPanel() {
        var s = CallInteractionsState(isExpanded: true)
        s.didTapPrompts()
        XCTAssertFalse(s.isExpanded, "Prompts closes the menu")
        XCTAssertTrue(s.promptsOpen)
        s.toggleExpanded()
        s.didTapPrompts()
        XCTAssertFalse(s.isExpanded)
        XCTAssertFalse(s.promptsOpen, "a second Prompts tap hides the panel again")
    }

    func test_shareAndRingTaps_closeSubmenu_withoutTouchingPrompts() {
        var s = CallInteractionsState(isExpanded: true, promptsOpen: true)
        s.didTapActionItem()
        XCTAssertFalse(s.isExpanded)
        XCTAssertTrue(s.promptsOpen)
    }

    func test_closePrompts_closesPanelOnly() {
        var s = CallInteractionsState(isExpanded: true, promptsOpen: true)
        s.closePrompts()
        XCTAssertFalse(s.promptsOpen)
        XCTAssertTrue(s.isExpanded)
    }
}

// MARK: - B. Layout selection + share-vs-prompts precedence

final class CallLayoutStateTests: XCTestCase {

    func test_noContent_isField() {
        XCTAssertEqual(CallLayoutState.mode(promptsOpen: false, contentShareTileId: nil), .field)
        XCTAssertEqual(CallLayoutState.contentKind(promptsOpen: false, contentShareTileId: nil), .none)
    }

    func test_promptsOpen_isRowWithPromptsContent() {
        XCTAssertEqual(CallLayoutState.mode(promptsOpen: true, contentShareTileId: nil), .row)
        XCTAssertEqual(CallLayoutState.contentKind(promptsOpen: true, contentShareTileId: nil), .prompts)
    }

    func test_shareActive_isRowWithShareContent() {
        XCTAssertEqual(CallLayoutState.mode(promptsOpen: false, contentShareTileId: 7), .row)
        XCTAssertEqual(CallLayoutState.contentKind(promptsOpen: false, contentShareTileId: 7), .share)
    }

    /// Tile id 0 is a valid Chime tile id; "active" must be nil-ness, not truthiness.
    func test_shareTileIdZero_stillCountsAsAShare() {
        XCTAssertEqual(CallLayoutState.mode(promptsOpen: false, contentShareTileId: 0), .row)
        XCTAssertEqual(CallLayoutState.contentKind(promptsOpen: false, contentShareTileId: 0), .share)
    }

    func test_shareWinsOverPrompts_andPromptsReturnWhenShareStops() {
        XCTAssertEqual(CallLayoutState.contentKind(promptsOpen: true, contentShareTileId: 3), .share,
                       "the share takes the content area when both could show")
        XCTAssertEqual(CallLayoutState.mode(promptsOpen: true, contentShareTileId: 3), .row)
        // Share stops: promptsOpen was preserved, so prompts come back.
        XCTAssertEqual(CallLayoutState.contentKind(promptsOpen: true, contentShareTileId: nil), .prompts)
        XCTAssertEqual(CallLayoutState.mode(promptsOpen: true, contentShareTileId: nil), .row)
    }

    func test_shareStopsWithPromptsClosed_returnsToField() {
        XCTAssertEqual(CallLayoutState.mode(promptsOpen: false, contentShareTileId: nil), .field)
    }

    /// Full truth table: row iff (prompts || share).
    func test_modeTruthTable() {
        for prompts in [false, true] {
            for share in [nil, 4] as [Int?] {
                let expected: CallLayoutMode = (prompts || share != nil) ? .row : .field
                XCTAssertEqual(CallLayoutState.mode(promptsOpen: prompts, contentShareTileId: share), expected)
            }
        }
    }
}

// MARK: - C. Prompts data source (session.prompts, local-only)

final class CallPromptsSourceTests: XCTestCase {

    func test_nilSession_isEmpty() {
        XCTAssertEqual(CallPromptsSource.prompts(from: nil), [])
    }

    func test_returnsSessionPromptsInOrder() {
        var session = FSSession(); session.prompts = ["Who is Jesus?", "What stood out?"]
        XCTAssertEqual(CallPromptsSource.prompts(from: session), ["Who is Jesus?", "What stood out?"])
    }

    func test_blankAndWhitespaceOnlyPromptsAreDropped() {
        var session = FSSession(); session.prompts = ["", "  \n", "Real prompt", "\t"]
        XCTAssertEqual(CallPromptsSource.prompts(from: session), ["Real prompt"])
    }

    func test_emptyPrompts_isEmpty_soPanelShowsEmptyState() {
        XCTAssertEqual(CallPromptsSource.prompts(from: FSSession()), [])
    }

    func test_viewReadsPromptsFromCallSession_notFromAnyNewSource() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("CallPromptsSource.prompts(from: call.session)"))
        let session = try callSource("FellowScript/Chat/ChimeCallView+Session.swift")
        XCTAssertTrue(session.contains("No discussion prompts"),
                      "an empty list renders a minimal empty state rather than hiding the button")
    }
}

// MARK: - D. Screen-share flag + content-share bookkeeping (receive side)

final class ContentShareStateTests: XCTestCase {

    func test_flag_failsClosed() {
        XCTAssertFalse(ScreenShareFlag.isEnabled(.allOff))
        XCTAssertEqual(ScreenShareFlag.flagName, "screen_share_enabled")
        var caps = FSCapabilities.allOff
        caps.features["screen_share_enabled"] = false
        XCTAssertFalse(ScreenShareFlag.isEnabled(caps))
        caps.features["screen_share_enabled"] = true
        XCTAssertTrue(ScreenShareFlag.isEnabled(caps))
    }

    func test_sendingIsImplemented_butProductionStaysDarkViaTheServerFlag() {
        // Step 5 shipped the send path. The Share row is still hidden unless the
        // server flag is on, and the flag fails closed.
        XCTAssertTrue(ScreenShareFlag.sendingImplemented)
        XCTAssertFalse(ScreenShareFlag.isEnabled(.allOff),
                       "with the flag absent/off the Share row must not exist at all")
    }

    func test_contentAttendeeDetectionAndBaseId() {
        XCTAssertTrue(ContentShareAttendee.isContent("abc-123#content"))
        XCTAssertFalse(ContentShareAttendee.isContent("abc-123"))
        XCTAssertFalse(ContentShareAttendee.isContent("#contentabc"))
        XCTAssertEqual(ContentShareAttendee.baseAttendeeId("abc-123#content"), "abc-123")
        XCTAssertEqual(ContentShareAttendee.baseAttendeeId("abc-123"), "abc-123")
    }

    func test_tileAdded_recordsTileAndSharerBaseAttendee() {
        var s = ContentShareState()
        s.tileAdded(tileId: 9, attendeeId: "alice#content")
        XCTAssertEqual(s.tileId, 9)
        XCTAssertEqual(s.sharerAttendeeId, "alice", "the sharer is the base attendee, not the #content attendee")
    }

    func test_onlyOneActiveShare_secondTileIgnored() {
        var s = ContentShareState()
        s.tileAdded(tileId: 9, attendeeId: "alice#content")
        s.tileAdded(tileId: 10, attendeeId: "bob#content")
        XCTAssertEqual(s.tileId, 9)
        XCTAssertEqual(s.sharerAttendeeId, "alice")
    }

    func test_tileRemoved_onlyClearsMatchingTile() {
        var s = ContentShareState()
        s.tileAdded(tileId: 9, attendeeId: "alice#content")
        s.tileRemoved(tileId: 4)
        XCTAssertEqual(s.tileId, 9, "removing an unrelated tile must not end the share")
        s.tileRemoved(tileId: 9)
        XCTAssertNil(s.tileId)
        XCTAssertNil(s.sharerAttendeeId)
    }

    func test_shareCanRestartAfterStopping() {
        var s = ContentShareState()
        s.tileAdded(tileId: 9, attendeeId: "alice#content")
        s.tileRemoved(tileId: 9)
        s.tileAdded(tileId: 11, attendeeId: "bob#content")
        XCTAssertEqual(s.tileId, 11)
        XCTAssertEqual(s.sharerAttendeeId, "bob")
    }

    func test_reset_clearsEverything() {
        var s = ContentShareState()
        s.tileAdded(tileId: 9, attendeeId: "alice#content")
        s.reset()
        XCTAssertEqual(s, ContentShareState())
    }
}

// MARK: - E. Bubble roster

final class CallBubbleRosterTests: XCTestCase {

    private func items(
        localTile: Int? = nil, cameraOn: Bool = false,
        remoteTiles: [Int] = [], tileAttendee: [Int: String] = [:],
        remoteAttendees: [String] = [], external: [String: String] = [:],
        names: [String: String] = [:]
    ) -> [CallBubbleItem] {
        CallBubbleRoster.items(
            localTileId: localTile, cameraOn: cameraOn,
            remoteTileIds: remoteTiles, tileAttendee: tileAttendee,
            remoteAttendeeIds: remoteAttendees, externalUserIds: external, names: names)
    }

    func test_alwaysStartsWithSelfBubbleLabelledYou() {
        let out = items()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "self")
        XCTAssertEqual(out[0].name, "You")
        XCTAssertEqual(out[0].kind, .local(tileId: nil))
    }

    func test_selfCarriesTileOnlyWhileCameraIsOn() {
        XCTAssertEqual(items(localTile: 1, cameraOn: true)[0].kind, .local(tileId: 1))
        XCTAssertEqual(items(localTile: 1, cameraOn: false)[0].kind, .local(tileId: nil),
                       "a stale local tile id must not render once the camera is off")
    }

    func test_remoteVideoThenAudioOnly_ownFirst_andNoDuplicateForAttendeeWithVideo() {
        let out = items(
            remoteTiles: [5], tileAttendee: [5: "att-a"],
            remoteAttendees: ["att-a", "att-b"],
            external: ["att-a": "u-a", "att-b": "u-b"],
            names: ["u-a": "Alice", "u-b": "Bob"])
        XCTAssertEqual(out.map { $0.id }, ["self", "tile-5", "att-att-b"])
        XCTAssertEqual(out[1].name, "Alice")
        XCTAssertEqual(out[1].kind, .remoteVideo(tileId: 5))
        XCTAssertEqual(out[2].name, "Bob")
        XCTAssertEqual(out[2].kind, .audioOnly(attendeeId: "att-b"))
    }

    func test_contentShareAttendeeIsNeverABubble() {
        let out = items(remoteAttendees: ["att-a", "att-a#content"],
                        external: ["att-a": "u-a"], names: ["u-a": "Alice"])
        XCTAssertEqual(out.map { $0.id }, ["self", "att-att-a"])
        XCTAssertFalse(out.contains { $0.id.contains("#content") })
    }

    func test_unresolvedName_isNilNotGuessed() {
        let out = items(remoteTiles: [2], tileAttendee: [2: "att-x"], external: [:], names: [:])
        XCTAssertNil(out[1].name)
        XCTAssertNil(out[1].initial)
        XCTAssertEqual(out[1].accessibilityText, "Participant, video on")
    }

    func test_externalIdKnownButNameNotYetResolved_isNil() {
        let out = items(remoteAttendees: ["att-a"], external: ["att-a": "u-a"], names: [:])
        XCTAssertNil(out[1].name)
        XCTAssertEqual(out[1].accessibilityText, "Participant, audio only")
    }

    func test_accessibilityText_forEveryKind() {
        XCTAssertEqual(CallBubbleItem(id: "s", kind: .local(tileId: nil), name: "You").accessibilityText, "You, video off")
        XCTAssertEqual(CallBubbleItem(id: "s", kind: .local(tileId: 3), name: "You").accessibilityText, "You, video on")
        XCTAssertEqual(CallBubbleItem(id: "t", kind: .remoteVideo(tileId: 1), name: "Alice").accessibilityText, "Alice, video on")
        XCTAssertEqual(CallBubbleItem(id: "a", kind: .audioOnly(attendeeId: "x"), name: "Bob").accessibilityText, "Bob, audio only")
    }

    func test_initial_isUppercasedFirstLetter() {
        XCTAssertEqual(CallBubbleItem(id: "a", kind: .audioOnly(attendeeId: "x"), name: "bob").initial, "B")
    }
}

// MARK: - F. Participant-name resolution helper (CallParticipantNames)

@MainActor
final class CallParticipantNamesTests: XCTestCase {

    private func user(_ id: String, _ name: String) -> FSUser {
        FSUser(user_id: id, username: name, email: "\(id)@example.com")
    }

    /// Polls the main actor until `condition` holds (the resolver fires detached Tasks).
    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func test_resolvesEachExternalUserIdToUsername() async {
        let service = ThrowingTestDataService()
        service.fetchUserResultsById = ["u-a": user("u-a", "Alice"), "u-b": user("u-b", "Bob")]
        let names = CallParticipantNames()
        names.resolve(ids: ["u-a", "u-b"], service: service, selfId: "me")
        let ok = await waitUntil { names.names.count == 2 }
        XCTAssertTrue(ok)
        XCTAssertEqual(names.names["u-a"], "Alice")
        XCTAssertEqual(names.names["u-b"], "Bob")
    }

    func test_ownIdEmptyIdAndNilServiceAreSkipped() async {
        let service = ThrowingTestDataService()
        service.fetchUserResultsById = ["me": user("me", "Myself")]
        let names = CallParticipantNames()
        names.resolve(ids: ["me", ""], service: service, selfId: "me")
        names.resolve(ids: ["u-a"], service: nil, selfId: "me")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.fetchUserCallCount, 0, "self, empty ids and a nil service must never trigger a lookup")
        XCTAssertTrue(names.names.isEmpty)
    }

    func test_cachedAndInFlightIdsAreNotRefetched() async {
        let service = ThrowingTestDataService()
        service.fetchUserResultsById = ["u-a": user("u-a", "Alice")]
        let names = CallParticipantNames()
        // Two back-to-back calls with the same id: the second must see it in flight.
        names.resolve(ids: ["u-a"], service: service, selfId: "me")
        names.resolve(ids: ["u-a", "u-a"], service: service, selfId: "me")
        _ = await waitUntil { names.names["u-a"] != nil }
        XCTAssertEqual(service.fetchUserCallCount, 1, "an in-flight id must not be fetched twice")
        // Once cached, later passes (e.g. roster re-emit) skip it too.
        names.resolve(ids: ["u-a"], service: service, selfId: "me")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.fetchUserCallCount, 1, "a cached id must not be fetched again")
    }

    func test_failedLookup_leavesNameUnresolved_otherIdsStillResolve() async {
        struct Boom: Error {}
        let service = ThrowingTestDataService()
        service.fetchUserErrorsById = ["u-bad": Boom()]
        service.fetchUserResultsById = ["u-ok": user("u-ok", "Okay")]
        let names = CallParticipantNames()
        names.resolve(ids: ["u-bad", "u-ok"], service: service, selfId: "me")
        let ok = await waitUntil { names.names["u-ok"] != nil }
        XCTAssertTrue(ok)
        XCTAssertNil(names.names["u-bad"], "a failed lookup must not fabricate a name (throw-not-fabricate)")
    }

    func test_failedLookup_canBeRetriedOnALaterPass() async {
        struct Boom: Error {}
        let service = ThrowingTestDataService()
        service.fetchUserErrorsById = ["u-a": Boom()]
        let names = CallParticipantNames()
        names.resolve(ids: ["u-a"], service: service, selfId: "me")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(names.names["u-a"])
        service.fetchUserErrorsById = [:]
        service.fetchUserResultsById = ["u-a": user("u-a", "Alice")]
        names.resolve(ids: ["u-a"], service: service, selfId: "me")
        let ok = await waitUntil { names.names["u-a"] == "Alice" }
        XCTAssertTrue(ok, "in-flight bookkeeping must be released after a failure so a later pass can retry")
    }

    func test_emptyUsername_isNotCached() async {
        let service = ThrowingTestDataService()
        service.fetchUserResultsById = ["u-a": user("u-a", "")]
        let names = CallParticipantNames()
        names.resolve(ids: ["u-a"], service: service, selfId: "me")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(names.names["u-a"], "a blank username must stay unresolved (glyph, no label)")
    }
}

// MARK: - G. Breathing background: gating, easing, bounds

final class BreathingBackgroundModelTests: XCTestCase {

    // MARK: Gating (frozen for Reduce Motion, Low Power Mode, backgrounding, off-screen)

    func test_runsOnlyWhenEveryConditionAllows() {
        XCTAssertTrue(BreathingBackgroundModel.isAnimating(reduceMotion: false, sceneActive: true, lowPower: false, visible: true))
    }

    func test_reduceMotion_freezes() {
        XCTAssertFalse(BreathingBackgroundModel.isAnimating(reduceMotion: true, sceneActive: true, lowPower: false, visible: true))
    }

    func test_lowPowerMode_freezes() {
        XCTAssertFalse(BreathingBackgroundModel.isAnimating(reduceMotion: false, sceneActive: true, lowPower: true, visible: true))
    }

    func test_appBackgroundedOrInactive_freezes() {
        XCTAssertFalse(BreathingBackgroundModel.isAnimating(reduceMotion: false, sceneActive: false, lowPower: false, visible: true))
    }

    func test_offScreenOrMinimized_freezes() {
        XCTAssertFalse(BreathingBackgroundModel.isAnimating(reduceMotion: false, sceneActive: true, lowPower: false, visible: false))
    }

    /// Exhaustive: exactly one of the 16 combinations animates.
    func test_gatingTruthTable_onlyAllClearAnimates() {
        var animatingCount = 0
        for rm in [false, true] { for sa in [false, true] { for lp in [false, true] { for v in [false, true] {
            let r = BreathingBackgroundModel.isAnimating(reduceMotion: rm, sceneActive: sa, lowPower: lp, visible: v)
            XCTAssertEqual(r, !rm && sa && !lp && v)
            if r { animatingCount += 1 }
        }}}}
        XCTAssertEqual(animatingCount, 1)
    }

    // MARK: Easing

    func test_phase_isEasedSineNotLinear() {
        let p = BreathingBackgroundModel.period
        XCTAssertEqual(BreathingBackgroundModel.phase(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(BreathingBackgroundModel.phase(at: p / 2), 1, accuracy: 1e-9)
        XCTAssertEqual(BreathingBackgroundModel.phase(at: p), 0, accuracy: 1e-9, "a full period returns to the start")
        // Linear would give 0.25 at a quarter period; an eased sine gives 0.5.
        XCTAssertEqual(BreathingBackgroundModel.phase(at: p / 4), 0.5, accuracy: 1e-9)
        // Slow near the ends (ease), fast in the middle.
        let nearStart = BreathingBackgroundModel.phase(at: p * 0.05)
        XCTAssertLessThan(nearStart, 0.05, "motion must ease in: the first 5% of the cycle moves less than 5% of the range")
    }

    func test_phase_staysWithinZeroToOne_andIsPeriodic() {
        var t = 0.0
        while t < 40 {
            let v = BreathingBackgroundModel.phase(at: t)
            XCTAssertGreaterThanOrEqual(v, -1e-9)
            XCTAssertLessThanOrEqual(v, 1 + 1e-9)
            XCTAssertEqual(v, BreathingBackgroundModel.phase(at: t + BreathingBackgroundModel.period), accuracy: 1e-9)
            t += 0.37
        }
    }

    func test_cycleIsSlow_andTimerRateIsLow() {
        XCTAssertGreaterThanOrEqual(BreathingBackgroundModel.period, 8)
        XCTAssertLessThanOrEqual(BreathingBackgroundModel.period, 12)
        XCTAssertGreaterThanOrEqual(BreathingBackgroundModel.minimumInterval, 1.0 / 20.0,
                                    "low-frequency redraw for battery; no 60fps timeline")
    }

    func test_staticPhase_isMidBreathAndInRange() {
        XCTAssertEqual(BreathingBackgroundModel.staticPhase, 0.5)
        XCTAssertTrue((0.0...1.0).contains(BreathingBackgroundModel.staticPhase))
    }

    // MARK: Opacity / radius bounds (WCAG headroom at the brightest point)

    func test_frame_staysInsideDeclaredRanges_acrossTheWholeCycle() {
        for step in 0...20 {
            let p = Double(step) / 20
            let f = BreathingBackgroundModel.frame(phase: p)
            XCTAssertTrue(BreathingBackgroundModel.aOpacityRange.contains(f.aOpacity), "aOpacity \(f.aOpacity) @ \(p)")
            XCTAssertTrue(BreathingBackgroundModel.bOpacityRange.contains(f.bOpacity), "bOpacity \(f.bOpacity) @ \(p)")
            XCTAssertTrue(BreathingBackgroundModel.aRadiusRange.contains(f.aRadius))
            XCTAssertTrue(BreathingBackgroundModel.bRadiusRange.contains(f.bRadius))
        }
    }

    func test_frame_peakGoldOpacityIsCapped() {
        // The brightest gold the scrim ever has to defend against.
        let peak = BreathingBackgroundModel.frame(phase: 1)
        XCTAssertLessThanOrEqual(peak.aOpacity, 0.26)
        XCTAssertLessThanOrEqual(BreathingBackgroundModel.aOpacityRange.upperBound, 0.26)
        XCTAssertLessThanOrEqual(BreathingBackgroundModel.bOpacityRange.upperBound, 0.16)
    }

    func test_frame_blobsBreatheInOpposition() {
        let lo = BreathingBackgroundModel.frame(phase: 0)
        let hi = BreathingBackgroundModel.frame(phase: 1)
        XCTAssertLessThan(lo.aOpacity, hi.aOpacity)
        XCTAssertGreaterThan(lo.bOpacity, hi.bOpacity)
        XCTAssertLessThan(lo.aRadius, hi.aRadius)
        XCTAssertGreaterThan(lo.bRadius, hi.bRadius)
    }

    func test_frame_centerDriftIsSmallAndBounded() {
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            let f = BreathingBackgroundModel.frame(phase: p)
            XCTAssertEqual(f.aCenter.x, 0.22 + (p - 0.5) * 2 * BreathingBackgroundModel.centerDrift, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(abs(f.aCenter.x - 0.22), BreathingBackgroundModel.centerDrift + 1e-9)
        }
    }

    // MARK: Wiring pins (view body is not hostable in a unit test)

    func test_view_wiresReduceMotionScenePhaseLowPowerAndOffScreen() throws {
        let state = try callSource("FellowScript/Chat/CallSessionUIState.swift")
        guard let r = state.range(of: "struct CallBreathingBackground: View {") else { XCTFail("not found"); return }
        let body = String(state[r.upperBound...])
        XCTAssertTrue(body.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(body.contains("@Environment(\\.scenePhase)"))
        XCTAssertTrue(body.contains("ProcessInfo.processInfo.isLowPowerModeEnabled"))
        XCTAssertTrue(body.contains(".NSProcessInfoPowerStateDidChange"), "must react live to Low Power Mode toggling")
        XCTAssertTrue(body.contains("scenePhase == .active"))
        XCTAssertTrue(body.contains("BreathingBackgroundModel.isAnimating("),
                      "the view must delegate gating to the tested model, not re-derive it")
        XCTAssertFalse(body.contains("repeatForever"), "no free-running animation that could outlive the gate")
        XCTAssertFalse(body.contains("Animation.linear") || body.contains(".linear("), "never linear/robotic")
    }

    func test_timelineExistsOnlyInsideTheAnimatingBranch() throws {
        let state = try callSource("FellowScript/Chat/CallSessionUIState.swift")
        guard let r = state.range(of: "struct CallBreathingBackground: View {") else { XCTFail("not found"); return }
        let body = String(state[r.upperBound...])
        guard let ifAnim = body.range(of: "if animating {"),
              let elseAnim = body.range(of: "} else {", range: ifAnim.upperBound..<body.endIndex),
              let timeline = body.range(of: "TimelineView(") else {
            XCTFail("expected `if animating { TimelineView ... } else { static }` shape"); return
        }
        XCTAssertGreaterThan(timeline.lowerBound, ifAnim.lowerBound)
        XCTAssertLessThan(timeline.lowerBound, elseAnim.lowerBound,
                          "the TimelineView must sit in the animating branch so a frozen background has no timer running")
        XCTAssertEqual(body.components(separatedBy: "TimelineView(").count - 1, 1)
        let staticBranch = String(body[elseAnim.upperBound...])
        XCTAssertTrue(staticBranch.contains("BreathingBackgroundModel.staticPhase"))
    }

    func test_callViewGatesBackgroundOnExpandedAndOnScreen() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("CallBreathingBackground(isVisible: call.isExpanded && onScreen)"))
        XCTAssertTrue(view.contains(".onAppear { onScreen = true; resolveNames() }"))
        XCTAssertTrue(view.contains(".onDisappear { onScreen = false }"))
    }
}

// MARK: - H. Mute badge + VoiceOver labels (source pins)

final class CallSessionAccessibilityPinTests: XCTestCase {

    private func dockSource() throws -> String {
        let s = try callSource("FellowScript/Chat/ChimeCallView+Session.swift")
        guard let a = s.range(of: "struct CallDock: View {"),
              let b = s.range(of: "// MARK: - Submenu") else { throw XCTSkip("CallDock markers moved") }
        return String(s[a.upperBound..<b.lowerBound])
    }

    // Mute badge state

    func test_muteBadge_showsOnInteractionsButtonOnlyWhileMuted() throws {
        let dock = try dockSource()
        guard let r = dock.range(of: "if isMuted {") else { XCTFail("badge condition missing"); return }
        let badge = String(dock[r.upperBound...].prefix(800))
        XCTAssertTrue(badge.contains("mic.slash.fill"))
        XCTAssertTrue(badge.contains(".accessibilityHidden(true)"),
                      "the badge is decorative; the muted state is announced via the button's value")
        XCTAssertEqual(dock.components(separatedBy: "if isMuted {").count - 1, 1, "single, unconditional-free badge site")
        XCTAssertTrue(dock.contains(".overlay(alignment: .topTrailing)"))
    }

    func test_muteState_isAlsoSpokenOnTheCollapsedButton() throws {
        let dock = try dockSource()
        XCTAssertTrue(dock.contains(".accessibilityValue((isExpanded ? \"Expanded\" : \"Collapsed\") + (isMuted ? \", Muted\" : \"\"))"))
    }

    func test_headerShowsMutedPill_whileMuted() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        guard let r = view.range(of: "if manager.isMuted {") else { XCTFail("header muted pill missing"); return }
        let pill = String(view[r.upperBound...].prefix(600))
        XCTAssertTrue(pill.contains("Text(\"Muted\")"))
        XCTAssertTrue(pill.contains(".accessibilityLabel(\"Muted\")"))
    }

    // VoiceOver labels

    func test_dockButtons_haveLabelsHintsAndExpandedValue() throws {
        let dock = try dockSource()
        XCTAssertTrue(dock.contains(".accessibilityLabel(\"End call\")"))
        // Rooms: the End hint is a parameter (default unchanged) so it can say
        // "Leaves the room and the session" while in a room.
        XCTAssertTrue(dock.contains("var endHint = \"Leaves the session\""))
        XCTAssertTrue(dock.contains(".accessibilityHint(endHint)"))
        XCTAssertTrue(dock.contains(".accessibilityLabel(\"Session options\")"))
        XCTAssertTrue(dock.contains("\"Expanded\"") && dock.contains("\"Collapsed\""))
        XCTAssertTrue(dock.contains(".accessibilityHint(\"Double tap to show or hide options\")"))
        XCTAssertTrue(dock.contains(".accessibilityAddTraits(.isButton)"))
    }

    func test_everySubmenuRow_declaresLabelAndStateValue() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        guard let r = view.range(of: "private func menuRows() -> [CallMenuRow] {"),
              let end = view.range(of: "return rows", range: r.upperBound..<view.endIndex) else {
            XCTFail("menuRows not found"); return
        }
        let rows = String(view[r.upperBound..<end.lowerBound])
        // Every row construction carries an a11yLabel.
        XCTAssertEqual(rows.components(separatedBy: "CallMenuRow(").count - 1,
                       rows.components(separatedBy: "a11yLabel:").count - 1,
                       "each CallMenuRow must set a11yLabel")
        for label in ["Ring members", "Discussion prompts", "Camera", "Microphone"] {
            XCTAssertTrue(rows.contains("a11yLabel: \"\(label)\""), "missing VoiceOver label: \(label)")
        }
        // Share screen is intentionally out of the menu list. Rooms (task
        // 20261009-discussion-rooms) has no hard-coded row: it is appended only
        // through the gated roomsMenuRow() helper, so it is absent unless the
        // discussion_rooms flag is on (non-DM) or the user is away from main.
        XCTAssertFalse(rows.contains("a11yLabel: \"Share screen\""))
        XCTAssertFalse(rows.contains("a11yLabel: \"Rooms\""), "no unconditional Rooms row in menuRows")
        XCTAssertTrue(rows.contains("if let roomsRow = roomsMenuRow()"), "Rooms only via the gated helper")
        XCTAssertTrue(view.contains("guard roomsAvailable || rooms.state.showsBackToMain else { return nil }"))
        // Toggled controls expose state.
        XCTAssertTrue(rows.contains("a11yValue: manager.isCameraOn ? \"On\" : \"Off\""))
        XCTAssertTrue(rows.contains("a11yValue: manager.isMuted ? \"Muted\" : \"On\""))
        XCTAssertTrue(rows.contains("a11yValue: interactions.promptsOpen ? \"Showing\" : \"Hidden\""))
    }

    func test_submenuRowAppliesLabelValueHint() throws {
        let s = try callSource("FellowScript/Chat/ChimeCallView+Session.swift")
        XCTAssertTrue(s.contains(".accessibilityLabel(row.a11yLabel)"))
        XCTAssertTrue(s.contains(".accessibilityValue(row.a11yValue ?? \"\")"))
        XCTAssertTrue(s.contains(".accessibilityHint(row.a11yHint ?? \"\")"))
    }

    func test_bubblesAndContentArea_haveLabels() throws {
        let s = try callSource("FellowScript/Chat/ChimeCallView+Session.swift")
        XCTAssertTrue(s.contains(".accessibilityLabel(item.accessibilityText)"))
        XCTAssertTrue(s.contains(".accessibilityLabel(\"Close discussion prompts\")"))
        XCTAssertTrue(s.contains(".accessibilityLabel(\"Shared screen\")"))
        XCTAssertTrue(s.contains(".accessibilityLabel(\"Prompt \\(index + 1): \\(text)\")"))
        let field = try callSource("FellowScript/Chat/ChimeCallView+RemoteField.swift")
        XCTAssertTrue(field.contains(".accessibilityLabel(\"\\(nameForTile(id) ?? \"Participant\"), video on\")"))
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains(".accessibilityLabel(\"Minimize call\")"))
        XCTAssertTrue(view.contains(".accessibilityLabel(\"You, video on\")"))
    }

    func test_shareStartStopIsAnnouncedToVoiceOver() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("AccessibilityNotification.Announcement(\"\\(who) started sharing\")"))
        XCTAssertTrue(view.contains("AccessibilityNotification.Announcement(\"Sharing stopped\")"))
    }

    func test_shareRow_isGatedByFlag_andDisabledWhileSomeoneElseShares() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        // Reachable when the flag is on, or while a share is active so Stop is always possible.
        XCTAssertTrue(view.contains("if ScreenShareFlag.isEnabled(capabilities) || manager.screenShare.isActive {"))
        XCTAssertTrue(view.contains("enabled: ScreenShareFlag.sendingImplemented && !someoneElse && manager.isConnected"))
        XCTAssertFalse(view.contains("\"Not available yet\""), "the placeholder state was removed when sending shipped")
        XCTAssertTrue(view.contains("is sharing\""))
    }

    // MARK: - Session call menu polish (source pins)

    func test_promptsPanel_isTranslucent_noTitle_andKeepsA11y() throws {
        let s = try callSource("FellowScript/Chat/ChimeCallView+Session.swift")
        XCTAssertTrue(s.contains("Theme.bgPage.opacity(0.45)"))
        XCTAssertFalse(s.contains("Theme.bgPage.opacity(0.80)"), "opaque panel fill must be gone")
        XCTAssertFalse(s.contains("Text(\"Discussion Prompts\")"), "visible title removed")
        XCTAssertFalse(s.contains("\"Discussion Prompts\""))
        XCTAssertTrue(s.contains(".accessibilityLabel(kind == .prompts ? \"Discussion prompts\" : \"\")"))
        XCTAssertTrue(s.contains(".accessibilityLabel(\"Close discussion prompts\")"))
        XCTAssertTrue(s.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(s.contains("\"You are sharing\""), "share header kept")
    }

    func test_submenu_isCompactPopover() throws {
        let s = try callSource("FellowScript/Chat/ChimeCallView+Session.swift")
        guard let r = s.range(of: "struct CallSubmenu") else { XCTFail("CallSubmenu not found"); return }
        let body = String(s[r.lowerBound...])
        XCTAssertTrue(body.contains("minHeight: 44"))
        XCTAssertTrue(body.contains("ViewThatFits"))
        XCTAssertTrue(body.contains("ScrollView"))
        XCTAssertTrue(body.contains(".accessibilityAction(.escape, onEscape)"))
        XCTAssertTrue(body.contains("AccessibilityNotification.LayoutChanged().post()"))
        XCTAssertTrue(body.contains("popoverMaxWidth"))
    }

    func test_menuPlacement_anchoredAboveEllipsis_dismissOnOutsideTap_reduceMotion() throws {
        let v = try callSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(v.contains("CallDock.width(buttonSize: dockSize)"))
        XCTAssertTrue(v.contains("CallDock.padding"))
        XCTAssertTrue(v.contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
        XCTAssertTrue(v.contains(".onTapGesture { setMenu(expanded: false) }"))
        XCTAssertTrue(v.contains("reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing))"))
        XCTAssertTrue(v.contains("withMotionAwareAnimation(.easeOut(duration: 0.2), reduceMotion: reduceMotion)"))
    }

    func test_shareRow_hiddenFromMenu_butGatedCodeRemains() throws {
        let v = try callSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(v.contains("private static let showsShareRow = false"))
        XCTAssertTrue(v.contains("if Self.showsShareRow, let share = shareMenuRow() { rows.append(share) }"))
        XCTAssertTrue(v.contains("private func shareMenuRow() -> CallMenuRow?"))
        XCTAssertTrue(v.contains("ScreenShareFlag.isEnabled(capabilities)"))
        XCTAssertTrue(v.contains("ScreenShareFlag.sendingImplemented"))
    }
}

// MARK: - I. A content-share tile is never treated as a camera bubble (source pins)

final class ContentShareNeverABubblePinTests: XCTestCase {

    func test_videoTileDidAdd_routesContentTilesToContentShareBeforeAnyBubbleBookkeeping() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        guard let r = view.range(of: "func videoTileDidAdd(tileState: VideoTileState) {"),
              let end = view.range(of: "func videoTileDidRemove", range: r.upperBound..<view.endIndex) else {
            XCTFail("videoTileDidAdd not found"); return
        }
        let body = String(view[r.upperBound..<end.lowerBound])
        guard let contentGuard = body.range(of: "if isContent { self.contentShare.tileAdded(tileId: id, attendeeId: attendeeId); return }"),
              let localAssign = body.range(of: "self.localTileId = id"),
              let remoteAppend = body.range(of: "self.remoteTileIds.append(id)"),
              let attendeeMap = body.range(of: "self.tileAttendeeIds[id] = attendeeId") else {
            XCTFail("expected isContent early-return and the bubble bookkeeping lines"); return
        }
        XCTAssertLessThan(contentGuard.lowerBound, localAssign.lowerBound, "content check must precede local-tile assignment")
        XCTAssertLessThan(contentGuard.lowerBound, remoteAppend.lowerBound, "content check must precede remoteTileIds.append")
        XCTAssertLessThan(contentGuard.lowerBound, attendeeMap.lowerBound, "content check must precede tile->attendee mapping")
        XCTAssertTrue(body.contains("let isContent = tileState.isContent"))
    }

    func test_videoTileDidRemove_clearsContentShareWithoutTouchingBubbleState() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        guard let r = view.range(of: "func videoTileDidRemove(tileState: VideoTileState) {"),
              let end = view.range(of: "func videoTileDidPause", range: r.upperBound..<view.endIndex) else {
            XCTFail("videoTileDidRemove not found"); return
        }
        let body = String(view[r.upperBound..<end.lowerBound])
        guard let clear = body.range(of: "if self.contentShare.tileId == id { self.contentShare.tileRemoved(tileId: id); return }"),
              let remoteRemove = body.range(of: "self.remoteTileIds.removeAll") else {
            XCTFail("expected content-share removal early-return"); return
        }
        XCTAssertLessThan(clear.lowerBound, remoteRemove.lowerBound)
    }

    func test_contentAttendeesAreFilteredOutOfTheRemoteRoster() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        guard let r = view.range(of: "func attendeesDidJoin(attendeeInfo: [AttendeeInfo]) {"),
              let end = view.range(of: "func attendeesDidLeave", range: r.upperBound..<view.endIndex) else {
            XCTFail("attendeesDidJoin not found"); return
        }
        let body = String(view[r.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("!ContentShareAttendee.isContent(a.attendeeId)"))
        XCTAssertLessThan(body.range(of: "!ContentShareAttendee.isContent")!.lowerBound,
                          body.range(of: "self.remoteAttendeeIds.append")!.lowerBound)
    }

    func test_contentShareStateResetsOnLeave_andLayoutReadsItNotRemoteTiles() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("contentShare.reset()"))
        XCTAssertTrue(view.contains("CallLayoutState.mode(promptsOpen: interactions.promptsOpen, contentShareTileId: manager.contentShareTileId)"))
        XCTAssertTrue(view.contains("var contentShareTileId: Int? { contentShare.tileId }"))
    }

    func test_bubbleRowAndFieldNeverReceiveTheShareTile() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        // The only consumer of the content tile id is the content area.
        XCTAssertTrue(view.contains("shareTileId: manager.contentShareTileId"))
        let session = try callSource("FellowScript/Chat/ChimeCallView+Session.swift")
        guard let a = session.range(of: "struct CallBubbleView: View {"),
              let b = session.range(of: "struct CallContentArea: View {") else { XCTFail("markers"); return }
        let bubbleCode = String(session[a.upperBound..<b.lowerBound])
        XCTAssertFalse(bubbleCode.contains("contentShare") || bubbleCode.contains("shareTileId"),
                       "bubble views must have no path to the share tile")
    }

    func test_sdkStubStillCompiles_noSdkBranchIsUntouched() throws {
        let view = try callSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("#else"))
        guard let stub = view.range(of: "// MARK: - Stub (AmazonChimeSDK not installed)") else {
            XCTFail("no-SDK stub missing"); return
        }
        let stubBody = String(view[stub.upperBound...])
        XCTAssertFalse(stubBody.contains("CallSubmenu") || stubBody.contains("CallDock"),
                       "the no-SDK stub must not depend on SDK-only redesign types")
    }
}
