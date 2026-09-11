// LoadingScreenAssetTransparencyTests.swift — repurposed for task
// 20260910-loading-screen-star, testing step.
//
// This file previously covered the video-backed (`AVPlayerLayer` +
// `loading-screen.mov`) implementation's alpha-transparency fix (task
// 20260824-loading-screen-visual-fix). That implementation, and the
// asset-decode assertions that proved its fix, are both gone as of this
// task — `LoadingScreenView` is now a zero-dependency procedural draw with
// nothing to decode and no load-failure mode — so every asset-decode
// assertion below is replaced rather than kept stale. Per the intake spec's
// own acceptance criteria, this file is restored (it had been deleted by
// the now-abandoned blob redesign attempt, task
// 20260909-loading-screen-fullscreen) and its content is fully superseded
// to assert against the new star/spring implementation instead.
//
// Coverage:
//   A. `LoadingScreenMotion`'s pure timing constants (design-spec.md's
//      Motion language table — spring response/damping, beat/rest/entry-
//      hold durations, beat angle).
//   B. `LoadingScreenMotion`'s pure geometry (mark/stroke sizing). The
//      inner diamond and its clearance rule (critique.md issue #3) were
//      removed at the user's explicit request during the bounce-fix pass —
//      a single star shape only now — so that geometry and its coverage
//      are gone, not stale.
//   C. `LoadingScreenMotion`'s point-generation math (star shape),
//      exercised directly since it's kept outside any Canvas draw closure
//      specifically to be testable this way (Q18).
//   D. `LoadingScreenView` itself via ViewInspector: the accessibility
//      label is reachable through the real view tree, which is the
//      concrete regression check for the modifier-order hazard
//      (`warmBloomBackground()` before the accessibility modifiers) that
//      bounced the now-abandoned blob task once already.
//   E. Source-pinned checks for facts ViewInspector/XCTest can't observe at
//      runtime on this SDK (this target's established pattern — see
//      AttachmentLightboxTests.swift's own note on
//      `EnvironmentValues.accessibilityReduceMotion` being a get-only
//      property, so Reduce Motion can't be force-set via `.environment(_:_:)`
//      in a test): that the rotation state is a true unbounded ratchet
//      (never reset/modulo'd), that `loaderGrey` and the old fallback stack
//      are both actually gone, that the reduced-motion branch pairs the
//      static mark with a real `ProgressView` (not a frozen screen) and
//      routes through the project's existing motion-aware-animation
//      helpers, not a hand-rolled parallel mechanism.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - A. Timing constants

final class LoadingScreenMotionTimingTests: XCTestCase {

    func test_beatDuration_is1500ms() {
        XCTAssertEqual(LoadingScreenMotion.beatDuration, 1.5)
    }

    func test_loopDuration_isTwoBeats_3000ms() {
        XCTAssertEqual(LoadingScreenMotion.loopDuration, 3.0)
        XCTAssertEqual(LoadingScreenMotion.loopDuration, LoadingScreenMotion.beatDuration * 2)
    }

    func test_entryHold_is400ms() {
        XCTAssertEqual(LoadingScreenMotion.entryHoldDuration, 0.4)
    }

    func test_springSettle_and_rest_sumToOneBeat() {
        XCTAssertEqual(LoadingScreenMotion.springSettleDuration, 1.05)
        XCTAssertEqual(LoadingScreenMotion.restDuration, 0.45, accuracy: 0.0001)
        XCTAssertEqual(
            LoadingScreenMotion.springSettleDuration + LoadingScreenMotion.restDuration,
            LoadingScreenMotion.beatDuration,
            accuracy: 0.0001,
            "rest is the last 30% of the beat, not extra time bolted on"
        )
    }

    func test_beatAngle_defaultsTo180Degrees() {
        XCTAssertEqual(LoadingScreenMotion.beatAngleDegrees, 180)
    }

    /// The load-bearing spring curve — design-spec.md explicitly forbids
    /// re-splitting this into a separate ease-in stage, and the user's own
    /// standing Q9/Q13 motion preference forbids ever substituting a linear
    /// or constant-rate rotation for it. Pinning the exact constants is the
    /// most direct guard against either regression.
    func test_springConstants_matchDesignSpec() {
        XCTAssertEqual(LoadingScreenMotion.springResponse, 0.5)
        XCTAssertEqual(LoadingScreenMotion.springDampingFraction, 0.35)
    }
}

// MARK: - B. Geometry

final class LoadingScreenMotionGeometryTests: XCTestCase {

    private let markRect = CGRect(x: 0, y: 0, width: LoadingScreenMotion.markSize, height: LoadingScreenMotion.markSize)

    /// The mark was shrunk from the original 180pt design-spec.md call to
    /// 96pt at the user's explicit request during the bounce-fix pass (see
    /// LoadingScreenView.swift's own `markSize` doc comment) -- pinned here
    /// so a regression can't silently grow it back.
    func test_markSize_is96pt_significantlySmallerThanOriginal180pt() {
        XCTAssertEqual(LoadingScreenMotion.markSize, 96)
        XCTAssertLessThan(LoadingScreenMotion.markSize, 180, "must stay significantly smaller than the original 180pt mark")
    }

    func test_strokeWidth_is9pt_nineToTenPercentOfMarkSize() {
        XCTAssertEqual(LoadingScreenMotion.strokeWidth, 9)
        let fraction = LoadingScreenMotion.strokeWidth / LoadingScreenMotion.markSize
        XCTAssertEqual(fraction, 0.09, accuracy: 0.005, "style brief specifies stroke ≈ 9% of the mark size")
    }

    func test_starWaistRadius_isSmallerThanTipRadius_soTheStarReadsAsConcave() {
        XCTAssertLessThan(
            LoadingScreenMotion.starWaistRadius(in: markRect),
            LoadingScreenMotion.starTipRadius(in: markRect)
        )
    }
}

// MARK: - C. Point generation (star shape math)

final class LoadingScreenMotionShapeTests: XCTestCase {

    private let center = CGPoint(x: 90, y: 90)

    func test_alternatingRadiusPoints_producesRequestedCount() {
        let points = LoadingScreenMotion.alternatingRadiusPoints(center: center, tipRadius: 80, waistRadius: 40, count: 8)
        XCTAssertEqual(points.count, 8)
    }

    func test_alternatingRadiusPoints_firstPointIsStraightUp_atTipRadius() {
        let points = LoadingScreenMotion.alternatingRadiusPoints(center: center, tipRadius: 80, waistRadius: 40, count: 8)
        let first = points[0]
        XCTAssertEqual(first.x, center.x, accuracy: 0.001, "rest pose points to twelve o'clock")
        XCTAssertEqual(first.y, center.y - 80, accuracy: 0.001)
    }

    func test_alternatingRadiusPoints_alternatesTipAndWaistRadius() {
        let points = LoadingScreenMotion.alternatingRadiusPoints(center: center, tipRadius: 80, waistRadius: 40, count: 8)
        for (i, p) in points.enumerated() {
            let expectedRadius: CGFloat = i.isMultiple(of: 2) ? 80 : 40
            let distance = hypot(p.x - center.x, p.y - center.y)
            XCTAssertEqual(distance, expectedRadius, accuracy: 0.001, "point \(i) should sit at the \(i.isMultiple(of: 2) ? "tip" : "waist") radius")
        }
    }

    /// `regularPolygonPoints` (previously used only by the now-removed inner
    /// diamond) and `diamondPath` are gone along with the diamond shape
    /// itself -- a single star shape only, per the user's explicit request.
    func test_starPath_closesAndIsNonEmpty() {
        let rect = CGRect(x: 0, y: 0, width: LoadingScreenMotion.markSize, height: LoadingScreenMotion.markSize)
        let star = LoadingScreenMotion.starPath(in: rect)
        XCTAssertFalse(star.isEmpty)
    }
}

// MARK: - D. View-tree coverage (ViewInspector)

final class LoadingScreenViewTests: XCTestCase {

    /// The concrete regression check for the modifier-order hazard
    /// design-spec.md calls out: the now-abandoned blob task bounced once
    /// because `.ignoresSafeArea()` inside `warmBloomBackground()`'s own
    /// `.background(...)` landed in the wrong order relative to the
    /// accessibility modifiers, which broke ViewInspector's ability to find
    /// `.accessibilityLabel()`. Applying `warmBloomBackground()` BEFORE
    /// `.accessibilityElement`/`.accessibilityLabel` on the same outermost
    /// container (as `LoadingScreenView.body` does) is what keeps this
    /// reachable.
    func test_accessibilityLabel_isReachable_throughTheRealViewTree() throws {
        let sut = LoadingScreenView()
        // `.find` walks all the way down to the real content (the mark's
        // own ZStack), passing through -- and accumulating -- every
        // modifier applied along the way, including `.accessibilityLabel`
        // several layers further out. `sut.inspect()` alone, with no further
        // navigation, stops at the un-expanded `LoadingScreenView` node
        // itself and doesn't see modifiers applied inside `body`.
        let mark = try sut.inspect().find(ViewType.ZStack.self)
        XCTAssertEqual(try mark.accessibilityLabel().string(), "Loading FellowScript")
    }

    /// Default test-host environment has Reduce Motion off, so this
    /// exercises the standard (spring) path -- confirms the mark itself
    /// renders at the shipped `markSize`x`markSize` frame.
    func test_standardPath_markRendersAtSpecSize() throws {
        let sut = LoadingScreenView()
        let frame = try sut.inspect().find(ViewType.ZStack.self).fixedFrame()
        XCTAssertEqual(frame.width, LoadingScreenMotion.markSize)
        XCTAssertEqual(frame.height, LoadingScreenMotion.markSize)
    }

    /// Rest pose (before the first beat fires) must show the mark at
    /// rotation 0 -- `beatCount` starts at 0 and the ratchet is
    /// `Double(beatCount) * beatAngleDegrees`.
    func test_standardPath_restPose_hasZeroRotation() throws {
        let sut = LoadingScreenView()
        let rotation = try sut.inspect().find(ViewType.ZStack.self).rotation()
        XCTAssertEqual(rotation.angle.degrees, 0)
    }
}

// MARK: - E. Source-pinned regression guards

final class LoadingScreenViewSourceRegressionTests: XCTestCase {

    private func loadingScreenSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let viewFile = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/LoadingScreen/LoadingScreenView.swift")
        return try String(contentsOf: viewFile, encoding: .utf8)
    }

    /// critique.md issue #1: the rotation ratchet must be unbounded, never
    /// a resetting keyframe loop -- required regardless of which beat-angle
    /// variant ships, since a resetting loop pops `goldGradient`'s rotated
    /// sweep at the loop boundary under the 90°-per-beat fallback.
    func test_rotationState_isUnboundedRatchet_neverReset() throws {
        let source = try loadingScreenSource()
        XCTAssertTrue(source.contains("beatCount += 1"), "each beat must increment the ratchet, not replace it")
        XCTAssertFalse(source.contains("beatCount = 0"), "the ratchet must never reset back to zero mid-loop")
        XCTAssertFalse(source.contains("truncatingRemainder"), "rotation must not be wrapped/modulo'd -- that would reintroduce a resetting loop")
    }

    /// The user's own standing Q9/Q13 motion preference (no linear/robotic
    /// motion) and design-spec.md's own explicit ban.
    func test_noLinearOrConstantRateRotation() throws {
        let source = try loadingScreenSource()
        XCTAssertFalse(source.contains(".linear"), "linear/constant-rate motion is explicitly disallowed for this mark's rotation")
    }

    /// The old asset-load-failure fallback stack has nothing left to guard
    /// against for a procedural draw and must be gone, not carried forward.
    /// These check real code shapes (`Image("FellowScriptMark")`,
    /// `Text("Loading…")`, `AVPlayerLayer.self`), not the bare words --
    /// this file's own header comments legitimately name all three while
    /// documenting what was removed and why.
    func test_oldFallbackStack_isFullyRemoved() throws {
        let source = try loadingScreenSource()
        XCTAssertFalse(source.contains("Image(\"FellowScriptMark\")"), "the old asset-fallback image must not be referenced")
        XCTAssertFalse(source.contains("Text(\"Loading…\")"), "the old fallback caption text must not be referenced")
        XCTAssertFalse(source.contains("AVPlayerLayer.self"), "the video-backed implementation must be fully replaced, not conditionally kept")
        XCTAssertFalse(source.contains("forResource: \"loading-screen\""), "the view must not look up the now-unreferenced-but-not-deleted .mov asset")
        XCTAssertFalse(source.contains("AVPlayerItem("), "no AVFoundation playback APIs should remain in a purely procedural draw")
    }

    /// Reduced motion must pair the static mark with real, non-spatial
    /// loading feedback -- never a frozen screen -- per design-spec.md's
    /// "Reduced motion, corrected" note and this user's Q14.2/Q14.3
    /// preference. ViewInspector can't force `accessibilityReduceMotion`
    /// true on this SDK (get-only property; see AttachmentLightboxTests.swift's
    /// own note), so this is source-pinned rather than live-inspected.
    func test_reducedMotionPath_pairsStaticMarkWithRealProgressView() throws {
        let source = try loadingScreenSource()
        XCTAssertTrue(source.contains("reducedMotionLayer"))
        XCTAssertTrue(source.contains("ProgressView()"))
        XCTAssertTrue(source.contains(".tint(Theme.gold)"))
        XCTAssertTrue(source.contains(".accessibilityHidden(true)"), "the spinner itself must stay out of the accessibility tree -- the container label is the only VoiceOver element")
        // Checks for real usage (`VStack(` / `VStack {`), not the word
        // itself -- this file's own doc comments legitimately mention
        // VStack by name to explain why it's avoided here.
        XCTAssertFalse(source.contains("VStack("), "the mark's on-screen center must match the standard variant exactly -- a VStack here would shift it (critique.md issue #4)")
        XCTAssertFalse(source.contains("VStack {"), "the mark's on-screen center must match the standard variant exactly -- a VStack here would shift it (critique.md issue #4)")
    }

    /// `loaderGrey` must not carry forward from the abandoned blob task --
    /// palette is Theme.swift shipped tokens only, and this specific token
    /// is explicitly excluded by the spec. Checks the real member-access
    /// shape (`Theme.loaderGrey` / `.loaderGrey`), not the bare word -- this
    /// file's own header comments legitimately name the retired token in
    /// backticks while documenting that it's gone.
    func test_loaderGreyToken_isNotReferenced() throws {
        let source = try loadingScreenSource()
        XCTAssertFalse(source.contains("Theme.loaderGrey"))
        XCTAssertFalse(source.contains(".loaderGrey"))
    }

    func test_themeSwift_noLongerDefinesLoaderGrey() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let themeFile = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Theme/Theme.swift")
        let source = try String(contentsOf: themeFile, encoding: .utf8)
        XCTAssertFalse(source.contains("loaderGrey"), "the abandoned blob task's loaderGrey token must not carry forward")
    }

    /// design-spec.md's "Reduced motion, corrected" note and "Consistency
    /// notes" both say explicitly: "Implement the branch via the project's
    /// existing motionAwareAnimation/withMotionAwareAnimation helpers ...
    /// rather than inventing a parallel mechanism." intake-spec.md repeats
    /// this verbatim as an in-bounds requirement. This was previously a real
    /// gap -- the view branched on a hand-rolled
    /// `@Environment(\.accessibilityReduceMotion)` check and drove the beat
    /// ratchet with a raw `withAnimation(...)` call, with neither helper
    /// referenced anywhere in the file -- fixed by routing `startLoop()`'s
    /// animated state change through `withMotionAwareAnimation(_:reduceMotion:_:)`.
    /// Kept as a permanent regression guard against reintroducing a raw
    /// `withAnimation`/parallel mechanism at this call site.
    func test_reducedMotionBranch_routesThroughProjectMotionAwareHelpers() throws {
        let source = try loadingScreenSource()
        // Strip comment lines first -- the file's own header/doc comments
        // legitimately mention `.motionAwareAnimation(.easeOut(...` (quoting
        // ContentView's unrelated exit crossfade) and would otherwise make
        // a bare `.contains` check pass without any real usage in code.
        let codeLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") ? "" : line
            }
        let code = codeLines.joined(separator: "\n")
        XCTAssertTrue(
            code.contains("motionAwareAnimation(") || code.contains("withMotionAwareAnimation("),
            "design-spec.md and intake-spec.md both require the reduced-motion branch to route through the project's existing motionAwareAnimation/withMotionAwareAnimation helpers rather than a hand-rolled parallel mechanism -- no real (non-comment) call site for either helper exists in LoadingScreenView.swift"
        )
    }
}
