// ChimeCallViewRedesignRegressionTests.swift — testing-gate coverage for
// task 20260915-video-call-ui-redesign, step 3.
//
// Covers the parts of design-notes.md's spec that aren't the packing
// algorithm itself (see RemoteCameraFieldLayoutRegressionTests.swift for
// that): the background treatment, the self-camera PiP decision, the
// control-bar/header/MinimizedCallBar out-of-bounds guard, and the
// motion/reduced-motion rules. Following this project's established
// technique (SubmenuVisualRedesignRegressionTests.swift,
// DashboardBackgroundConsistencyRegressionTests.swift) of pinning
// render-tree facts that ViewInspector can't cheaply assert on (an exact
// modifier/literal, an absent old construct) by reading the real shipped
// source directly.

import XCTest
import SwiftUI
@testable import FellowScript

final class ChimeCallViewRedesignRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - A. Grid fully replaced

    func test_chimeCallView_noLongerContainsLazyVGridOrRemoteGridFunction() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        // Task 20261009-session-ui-redesign legitimately added ONE LazyVGrid, but
        // only for audio-only name bubbles inside audioParticipantsView. The old
        // video-tile grid box (a LazyVGrid of ChimeVideoTileView) must stay gone.
        XCTAssertEqual(source.components(separatedBy: "LazyVGrid").count - 1, 1,
                       "the old grid box must be fully removed; only the audio-only bubble grid may use LazyVGrid")
        if let grid = source.range(of: "LazyVGrid"),
           let audio = source.range(of: "private var audioParticipantsView: some View {") {
            XCTAssertGreaterThan(grid.lowerBound, audio.lowerBound, "the sole LazyVGrid must live in audioParticipantsView")
            let gridBody = String(source[grid.upperBound...].prefix(250))
            XCTAssertFalse(gridBody.contains("ChimeVideoTileView"), "no grid of live video tiles may return")
        }
        XCTAssertFalse(source.contains("func remoteGrid"), "remoteGrid(containerHeight:) must be fully removed, not left dead")
        XCTAssertTrue(source.contains("RemoteCameraField(manager: manager, containerSize: geo.size,"),
                      "the field layout must still render the randomized-circle field in the grid's place " +
                      "(task 20261009-session-ui-redesign added a trailing nameForTile argument)")
    }

    // MARK: - B. Background: genuine native blur, on-brand, no new colors

    /// Task 20261009-session-ui-redesign replaced the static `chimeBackground`
    /// (ultraThinMaterial over a static bloom) with `CallBreathingBackground`
    /// (CallSessionUIState.swift). The original intent is preserved: warm dark
    /// base token, gold bloom from existing Theme tokens, no new hex literal,
    /// no flat black. The ultraThinMaterial pin is deliberately inverted: a
    /// material over a continuously animating layer is a known cost.
    func test_background_isBreathingGoldGradientFromThemeTokens_notStaticChimeBackground() throws {
        let view = try readSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertFalse(view.contains("private var chimeBackground"), "the static chimeBackground must be fully replaced")
        XCTAssertTrue(view.contains("CallBreathingBackground(isVisible: call.isExpanded && onScreen)"),
                      "the call screen must render the breathing background, gated on expanded + on-screen")

        let state = try readSource("FellowScript/Chat/CallSessionUIState.swift")
        guard let range = state.range(of: "struct CallBreathingBackground: View {") else {
            XCTFail("CallBreathingBackground not found"); return
        }
        let body = String(state[range.upperBound...])
        XCTAssertTrue(body.contains("Theme.bgPage"), "must use the warm dark base token, never pure black")
        XCTAssertTrue(body.contains("Theme.gold") && body.contains("Theme.goldLight"),
                      "gold bloom must reuse existing Theme tokens, not a new literal hex")
        XCTAssertFalse(body.contains("Color.black"), "no flat black")
        XCTAssertFalse(body.contains("Color(hex:"), "no new color literals; brand tokens only")
        XCTAssertTrue(body.contains(".ignoresSafeArea()"))
        XCTAssertFalse(body.contains(".ultraThinMaterial"), "no material over the animated layer (perf, design-notes.md §6)")
    }

    func test_chimeCallView_bodyNoLongerUsesFlatBlackBackground() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        guard let structRange = source.range(of: "struct ChimeCallView: View {") else {
            XCTFail("ChimeCallView not found"); return
        }
        // Only check the #if canImport(AmazonChimeSDK) live implementation,
        // not the #else stub (which legitimately keeps Color.black.ignoresSafeArea()
        // for the "SDK not installed" placeholder screen -- out of this task's scope).
        let stubRange = source.range(of: "#else", range: structRange.upperBound..<source.endIndex)
        let end = stubRange?.lowerBound ?? source.endIndex
        let liveBody = String(source[structRange.upperBound..<end])
        XCTAssertFalse(liveBody.contains("Color.black.ignoresSafeArea()"),
                       "the live call screen must no longer use the old flat-black background")
    }

    // MARK: - C. Self-camera PiP: stays fixed/distinct, not folded into the field

    func test_selfCameraPiP_staysFixedNonRandomizedElement_withGlassTokensCosmeticOnly() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(source.contains(".frame(width: 96, height: 128)"),
                      "self-PiP must keep its original fixed size, unrelated to the randomized-tile diameter tiers")
        XCTAssertTrue(source.contains(".background(Theme.bgPage.opacity(0.72))"),
                      "self-PiP's fill must use the Theme.bgPage token (the old 0.34 glass fill went away with chimeBackground)")
        XCTAssertFalse(source.contains(".background(Color.black)"),
                       "self-PiP's old flat-black fill must be fully replaced, not left alongside the new one")
        XCTAssertTrue(source.contains(".padding(.trailing, 16).padding(.bottom, dockZone + 8)"),
                      "self-PiP keeps its fixed bottom-trailing position, now raised to clear the dock (was a fixed 152)")
        XCTAssertFalse(source.contains("RemoteCameraField(manager: manager, containerSize: geo.size, includeLocal"),
                       "the self-camera must not have been folded into RemoteCameraField's randomized field")
    }

    // MARK: - D. Control bar / header / MinimizedCallBar out-of-bounds guard

    func test_controlBar_replacedByTwoButtonDock_withMuteCameraRingMovedIntoSubmenu() throws {
        let view = try readSource("FellowScript/Chat/ChimeCallView.swift")
        let session = try readSource("FellowScript/Chat/ChimeCallView+Session.swift")
        XCTAssertFalse(view.contains("private var controlBar"), "the old 4-button controlBar must be gone")
        XCTAssertFalse(view.contains("callButton(icon:"), "the old callButton helper must be gone")
        XCTAssertTrue(view.contains("CallDock(isMuted: manager.isMuted"), "the dock must be wired to live mute state")
        // The two dock buttons: End and the Interactions toggle, nothing else.
        XCTAssertTrue(session.contains("Button(action: onEnd)") && session.contains("Button(action: onToggleMenu)"))
        guard let dockRange = session.range(of: "struct CallDock: View {"),
              let menuRange = session.range(of: "// MARK: - Submenu") else {
            XCTFail("CallDock / submenu marker not found"); return
        }
        let dock = String(session[dockRange.upperBound..<menuRange.lowerBound])
        XCTAssertEqual(dock.components(separatedBy: "Button(action:").count - 1, 2,
                       "exactly two persistent bottom buttons: End Call and Interactions")
        XCTAssertTrue(dock.contains("phone.down.fill"))
        // Existing behaviours survive, now as submenu rows (semantics unchanged).
        XCTAssertTrue(view.contains("manager.toggleMute()") && view.contains("manager.toggleCamera()"))
        XCTAssertTrue(view.contains("showRingSheet = true") && view.contains("if canRing {"),
                      "Ring keeps its canRing gating and RingMembersSheet")
        XCTAssertTrue(view.contains("manager.isMuted ? \"mic.slash.fill\" : \"mic.fill\""))
        XCTAssertTrue(view.contains("manager.isCameraOn ? \"video.fill\" : \"video.slash.fill\""))
    }

    func test_callHeader_structureUnchanged_onlySitsOverNewBackdrop() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(source.contains("LinearGradient(colors: [Theme.bgPage.opacity(0.80), .clear], startPoint: .top, endPoint: .bottom)"),
                      "callHeader's top scrim is now a Theme.bgPage tint (was black) so it blends with the gold background")
        XCTAssertTrue(source.contains(".padding(.horizontal, 20).padding(.top, topPadding).padding(.bottom, 16)"),
                      "callHeader's top padding is now a parameter (56 in the field layout, 16 in compact/landscape row)")
        // Step 5: headerStack wraps callHeader (adds the pinned share pill + notice) and carries the same padding.
        XCTAssertTrue(source.contains("headerStack(topPadding: 56)"))
        XCTAssertTrue(source.contains("callHeader(topPadding: topPadding)"))
        // Task 20261009-discussion-rooms: the status text is now routed through
        // headerConnectionText (adds "Reconnecting…" for a failed return-to-main);
        // the main-session wording is unchanged.
        XCTAssertTrue(source.contains("Text(headerConnectionText)"))
        XCTAssertTrue(source.contains("return manager.isConnected ? \"Connected\" : \"Connecting…\""))
    }

    func test_minimizedCallBar_notTouchedByThisTask() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        guard let range = source.range(of: "struct MinimizedCallBar: View {") else {
            XCTFail("MinimizedCallBar not found"); return
        }
        let end = source.range(of: "\n}\n\n#if canImport", range: range.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[range.upperBound..<end])
        XCTAssertTrue(body.contains(".background(Color(white: 0.12))"), "MinimizedCallBar's own background must be untouched by this call-screen-only redesign")
        XCTAssertFalse(body.contains("RemoteCameraField"), "MinimizedCallBar must not reference the new randomized field at all")
    }

    // MARK: - E. Motion: eased, asymmetric, reduced-motion first-class, no idle motion

    func test_remoteCameraField_motion_easedAsymmetricAndReducedMotionFirstClass() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView+RemoteField.swift")
        XCTAssertTrue(source.contains("Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)"), "enter curve must match design-notes.md §4 exactly")
        XCTAssertTrue(source.contains(".timingCurve(0.16, 1, 0.3, 1, duration: 0.25)"), "exit must be faster (0.25s) than enter (0.45s), same curve family")
        XCTAssertTrue(source.contains("if reduceMotion {") && source.contains(".opacity.animation(.easeInOut(duration: 0.2))"),
                      "reduced motion must be a first-class opacity-only cross-fade, not a bolted-on afterthought")
        XCTAssertFalse(source.contains("repeatForever"), "no idle/ambient motion anywhere -- tiles are static once placed")
        XCTAssertFalse(source.contains("Animation.linear"), "no constant/linear ('robotic') motion, per UI/UX Q9/Q13")
    }

    // MARK: - F. Non-video states: no content/copy changes

    func test_waitingPlaceholderAndAudioParticipantsView_contentUnchanged() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        // Rooms adds an in-room variant; the main-session copy is unchanged.
        XCTAssertTrue(source.contains("Text(!manager.isConnected ? \"Connecting…\""))
        XCTAssertTrue(source.contains(": \"Waiting for others to join…\"))"))
        XCTAssertTrue(source.contains("Text(count == 1 ? \"1 person connected\" : \"\\(count) people connected\")"))
        XCTAssertTrue(source.contains("Text(\"Audio call in progress\")"))
    }
}
