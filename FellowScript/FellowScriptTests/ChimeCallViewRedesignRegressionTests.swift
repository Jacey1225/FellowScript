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
        XCTAssertFalse(source.contains("LazyVGrid"), "the old grid box must be fully removed")
        XCTAssertFalse(source.contains("func remoteGrid"), "remoteGrid(containerHeight:) must be fully removed, not left dead")
        XCTAssertTrue(source.contains("RemoteCameraField(manager: manager, containerSize: geo.size)"),
                      "callActiveBody must render the new randomized-circle field in the grid's place")
    }

    // MARK: - B. Background: genuine native blur, on-brand, no new colors

    func test_chimeBackground_usesUltraThinMaterialOverThemeBgPageAndGoldBloom() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        guard let range = source.range(of: "private var chimeBackground: some View {") else {
            XCTFail("chimeBackground not found"); return
        }
        let body = String(source[range.upperBound...].prefix(1000))
        XCTAssertTrue(body.contains("Theme.bgPage"), "must use the warm dark base token, never pure black/Color.black")
        XCTAssertTrue(body.contains(".overlay(.ultraThinMaterial)"), "must be a genuine native-blur exception, per design-notes.md §1's resolved decision (a)")
        XCTAssertTrue(body.contains("Theme.gold.opacity(0.16)") || body.contains("Theme.gold"),
                      "gold bloom must reuse the existing Theme.gold token, not a new literal hex")
        XCTAssertTrue(body.contains(".ignoresSafeArea()"))
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
        XCTAssertTrue(source.contains(".background(Theme.bgPage.opacity(0.34))") && source.contains(".background(.ultraThinMaterial)"),
                      "self-PiP's fill must switch to the same glass tokens as the new backdrop")
        XCTAssertFalse(source.contains(".background(Color.black)"),
                       "self-PiP's old flat-black fill must be fully replaced, not left alongside the new one")
        XCTAssertTrue(source.contains(".padding(.trailing, 16).padding(.bottom, 152)"),
                      "self-PiP's fixed bottom-trailing position must be unchanged")
        XCTAssertFalse(source.contains("RemoteCameraField(manager: manager, containerSize: geo.size, includeLocal"),
                       "the self-camera must not have been folded into RemoteCameraField's randomized field")
    }

    // MARK: - D. Control bar / header / MinimizedCallBar out-of-bounds guard

    func test_controlBar_remainsPixelForPixelUnchanged() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(source.contains("callButton(icon: manager.isMuted ? \"mic.slash.fill\" : \"mic.fill\","))
        XCTAssertTrue(source.contains("callButton(icon: manager.isCameraOn ? \"video.fill\" : \"video.slash.fill\","))
        XCTAssertTrue(source.contains(".padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 44).frame(maxWidth: .infinity)"))
        XCTAssertTrue(source.contains("Circle().fill(Color.red).frame(width: 62, height: 62)"))
        XCTAssertTrue(source.contains("LinearGradient(colors: [.clear, .black.opacity(0.90)], startPoint: .top, endPoint: .bottom)"),
                      "controlBar's own scrim must be unchanged -- it is not part of the new backdrop")
    }

    func test_callHeader_structureUnchanged_onlySitsOverNewBackdrop() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(source.contains("LinearGradient(colors: [.black.opacity(0.80), .clear], startPoint: .top, endPoint: .bottom)"),
                      "callHeader's own top scrim must be unchanged, per design-notes.md §1 ('flag, not a redesign')")
        XCTAssertTrue(source.contains(".padding(.horizontal, 20).padding(.top, 56).padding(.bottom, 16)"))
        XCTAssertTrue(source.contains("Text(manager.isConnected ? \"Connected\" : \"Connecting…\")"))
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
        XCTAssertTrue(source.contains("Text(manager.isConnected ? \"Waiting for others to join…\" : \"Connecting…\")"))
        XCTAssertTrue(source.contains("Text(count == 1 ? \"1 person connected\" : \"\\(count) people connected\")"))
        XCTAssertTrue(source.contains("Text(\"Audio call in progress\")"))
    }
}
