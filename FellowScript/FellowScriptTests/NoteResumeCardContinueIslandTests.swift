// NoteResumeCardContinueIslandTests.swift — coverage for task
// 20260828-continue-button-circle-implementation, testing step (step 3).
//
// Task 20260828-continue-button-circle-implementation replaced NoteResumeCard's
// pill/capsule "Continue" island (text-only, chamfered corner, notched into the
// card's bottom-right boundary) with design-spec.md's Option 2: a plain
// circular icon-only Continue button (chevron.right glyph, no visible text)
// sitting in a genuine breach/overlap over the card's own plain, un-notched
// bottom-right corner. The entire chamfer/notch geometry subsystem this file
// used to cover (`ContinueIslandShape`, `NoteResumeCardNotch`,
// `NoteResumeCardShape`, `NotchedCardMaterial`, `chamferEdgeIntersections`,
// `chamferGeometryIsValid`, `chamferTreatmentFitsIslandRadius`, the
// `glassCard(shape:...)` overloads, the §4 `notchTreatmentFits`/
// `fallbackContinueCapsule` fallback mechanism, and the hidden
// `measuringLabel`-driven sizing) was deleted along with the pill — this file
// no longer references any of it (confirmed by the dead-code-removal test
// below), replaced with coverage for the new construction:
//
//   - icon-only control (chevron.right glyph, no visible "Continue" text --
//     the previous acceptance criterion is now inverted)
//   - accessibility label "Continue reading <title>" (unchanged pattern),
//     including the "Untitled note" fallback
//   - tap wiring survives the restyle
//   - `.contentShape(Circle())` -- hit-testing must not be limited to the
//     visually-reduced circular silhouette
//   - the note == nil empty state never renders the circle button
//   - the @ScaledMetric-driven `resolvedDiameter` clamps to 52...72 and never
//     exceeds 45% of the live card width across the full 12-category Dynamic
//     Type range at multiple device widths -- proving design-spec.md's claim
//     that the retired §4 fallback capsule is genuinely never needed
//   - source-pinned regression coverage for every construction detail this
//     task locked that isn't reachable through ViewInspector (AngularGradient
//     rim stop-window/color, LinearGradient fill direction/colors, glyph
//     weight/size-formula/color/optical-offset, the unchanged shadow stack,
//     the @ScaledMetric declaration/clamp) -- ViewInspector has no built-in
//     support for AngularGradient's `ShapeStyle` internals or for
//     @ScaledMetric's environment-driven scaling (confirmed empirically: no
//     `AngularGradient`/`ScaledMetric` support exists anywhere in the
//     ViewInspector package this target vendors), so this file follows the
//     same source-string-pin technique this codebase already established for
//     other private/ViewInspector-unreachable implementation details (see
//     `LoadingScreenAssetTransparencyTests.
//     test_loadingScreenSource_frameSize_isIconScale_notFullBleed`, and this
//     file's own prior Reduce Motion / token-value pins, carried forward
//     below).
//
// Reduce Motion's press-state substitution (unchanged from the retired pill --
// `ContinueIslandButtonStyle` itself was not touched by this task) still lives
// entirely inside a `private` file-scoped type not reachable via `@testable
// import`, and ViewInspector's `.tap()` invokes a Button's action directly
// without driving SwiftUI's real press-state machinery, so that acceptance
// criterion is still pinned by reading the real shipped source, exactly as
// before.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class NoteResumeCardContinueIslandTests: XCTestCase {

    private func makeNote(title: String = "Sunday Service 06/28") -> FSNote {
        FSNote(
            id: "note-1", user: "user-1", title: title,
            text: "Pastor Ed spoke on the courage of faith.", public: false, group_id: "",
            is_reply: false, timestamp: "2026-06-28 20:10:22", verses: [], replies: []
        )
    }

    /// Reads the real shipped DashboardComponents.swift source -- used by
    /// every source-pin test below, and by the dead-code-removal test.
    private func componentSource() throws -> String {
        let componentFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Dashboard/DashboardComponents.swift")
        return try String(contentsOf: componentFile, encoding: .utf8)
    }

    /// The circular Continue button is one of two `Button`s in the populated
    /// card (the other is `cardBody`, whose accessibility label is "Resume
    /// note: <title>") -- found by its own distinct "Continue reading
    /// <title>" accessibility label rather than by any text content, since
    /// the new button is icon-only and carries no "Continue" text to search
    /// for (unlike the retired pill, which `find(button: "Continue")` could
    /// match directly).
    private func findContinueButton(in sut: NoteResumeCard) throws -> InspectableView<ViewType.Button> {
        try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string())?.hasPrefix("Continue reading") ?? false
        })
    }

    // ── Icon-only control, no text (inverts the retired pill's own
    // "text-only, no icon" acceptance criterion) ───────────────────────────

    func test_populatedNote_continueButton_rendersChevronGlyph_noVisibleContinueText() throws {
        let sut = NoteResumeCard(note: makeNote()) {}
        let button = try findContinueButton(in: sut)

        let image = try button.find(ViewType.Image.self)
        XCTAssertEqual(
            try image.actualImage().name(), "chevron.right",
            "Option 2's circular Continue button must render the chevron.right glyph"
        )
        XCTAssertThrowsError(
            try button.find(text: "Continue"),
            "the new circular button is icon-only -- no visible 'Continue' text label like the retired pill's"
        ) { _ in }
    }

    // ── Accessibility label (unchanged pattern, carried forward) ───────────

    func test_populatedNote_continueButton_accessibilityLabel_includesNoteTitle() throws {
        let sut = NoteResumeCard(note: makeNote(title: "Sunday Service 06/28")) {}
        let button = try findContinueButton(in: sut)
        XCTAssertEqual(try button.accessibilityLabel().string(), "Continue reading Sunday Service 06/28")
    }

    func test_populatedNote_emptyTitle_continueButton_accessibilityLabelFallsBackToUntitledNote() throws {
        let sut = NoteResumeCard(note: makeNote(title: "")) {}
        let button = try findContinueButton(in: sut)
        XCTAssertEqual(try button.accessibilityLabel().string(), "Continue reading Untitled note",
                       "an empty note title must fall back to the same 'Untitled note' label used elsewhere in this component, not a blank/broken accessibility label")
    }

    // ── Tap wiring survives the restyle ─────────────────────────────────────

    func test_populatedNote_tappingContinueButton_invokesOnOpen() throws {
        var opened = false
        let sut = NoteResumeCard(note: makeNote()) { opened = true }
        try findContinueButton(in: sut).tap()
        XCTAssertTrue(opened)
    }

    // ── Hit target: .contentShape(Circle()), not limited to the visually- ──
    // reduced silhouette (design-spec.md's locked "Hit target" requirement)

    func test_populatedNote_continueButton_hasContentShapeCircle() throws {
        let sut = NoteResumeCard(note: makeNote()) {}
        let button = try findContinueButton(in: sut)
        XCTAssertNoThrow(
            try button.contentShape(Circle.self),
            "the circular Continue button must apply .contentShape(Circle()) so hit-testing isn't limited to the visually-reduced silhouette"
        )
    }

    // ── The circle button must never render in the empty (note == nil)
    // state (design-spec.md's own explicit note that the empty state's
    // original pill is untouched by this task) ─────────────────────────────

    func test_emptyState_neverRendersContinueCircleButton() throws {
        let sut = NoteResumeCard(note: nil) {}
        XCTAssertThrowsError(
            try findContinueButton(in: sut),
            "the note == nil empty state must keep its own original dark-circle/gold-arrow 'Start a note' button -- the populated-state circular Continue button must not render there"
        ) { _ in }
        // The empty state's own original control is untouched.
        XCTAssertNoThrow(try sut.inspect().find(text: "Start a note"))
    }

    // ── @ScaledMetric diameter clamp + the retired §4 fallback claim ───────
    //
    // ViewInspector has no support for @ScaledMetric (confirmed empirically
    // -- no reference to `ScaledMetric` anywhere in the vendored
    // ViewInspector package), so a plain `.environment(\.sizeCategory, ...)`
    // override on an un-hosted `.inspect()` call cannot be trusted to drive
    // its scaling. This instead hosts the real `NoteResumeCard` (mirroring
    // this file's own pre-existing `chamferIsValid` sweep pattern for the
    // retired pill) across all 12 standard Dynamic Type categories crossed
    // with three device widths spanning design-spec.md §6's stated
    // ~375-430pt range, and reads `resolvedDiameter`/`cardWidth` directly off
    // the actually laid-out live instance via the `didAppear` hook.
    //
    // This is the direct, live-measured proof of design-spec.md's stated
    // claim that the clamped 52...72 diameter can never exceed 45% of card
    // width at any accessibility text size -- i.e. that the retired §4
    // fallback capsule was never actually reachable and is safe to have
    // removed outright, not just a claim taken on faith.

    @MainActor
    private func settledDiameterAndCardWidth(
        category: ContentSizeCategory, width: CGFloat
    ) throws -> (resolvedDiameter: CGFloat, cardWidth: CGFloat) {
        var sut = NoteResumeCard(note: makeNote()) {}
        var result: (CGFloat, CGFloat)?
        let exp = expectation(description: "cardWidth settles for \(category) at width \(width)")
        sut.didAppear = { view in
            // Ignore the pre-measurement pass, and guard against `onAppear`
            // and `onChange(of: cardWidth)` both firing with a settled
            // value (`.onChange` can re-fire on a subsequent layout pass
            // even once `cardWidth` has already settled) -- fulfilling more
            // than once is an XCTestExpectation API violation.
            guard view.cardWidth > 0, result == nil else { return }
            result = (view.resolvedDiameter, view.cardWidth)
            exp.fulfill()
        }
        let hosted = sut.environment(\.sizeCategory, category)
        ViewHosting.host(view: hosted, size: CGSize(width: width, height: 500))
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
        let settled = try XCTUnwrap(result, "cardWidth never settled for \(category) at width \(width)")
        return (settled.0, settled.1)
    }

    @MainActor
    func test_resolvedDiameter_staysClampedAndUnderFortyFivePercentOfCardWidth_acrossFullDynamicTypeRange_atMultipleDeviceWidths() throws {
        let categories: [ContentSizeCategory] = [
            .extraSmall, .small, .medium, .large,
            .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
            .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge
        ]
        let widths: [CGFloat] = [375, 393, 430]

        for width in widths {
            for category in categories {
                let (resolvedDiameter, cardWidth) = try settledDiameterAndCardWidth(category: category, width: width)

                XCTAssertGreaterThanOrEqual(
                    resolvedDiameter, 52,
                    "resolvedDiameter must never clamp below design-spec.md's locked 52pt floor -- failed at \(category), width \(width)"
                )
                XCTAssertLessThanOrEqual(
                    resolvedDiameter, 72,
                    "resolvedDiameter must never clamp above design-spec.md's locked 72pt ceiling -- failed at \(category), width \(width)"
                )
                XCTAssertGreaterThanOrEqual(
                    resolvedDiameter, 44,
                    "the 52pt clamp floor must clear the 44x44pt minimum touch target at every size -- failed at \(category), width \(width)"
                )
                XCTAssertLessThanOrEqual(
                    resolvedDiameter, 0.45 * cardWidth,
                    "resolvedDiameter must never exceed 45% of the live card width -- if this fails, design-spec.md's claim that the retired §4 fallback capsule is never needed does not actually hold at \(category), width \(width)"
                )
            }
        }
    }

    // ── Reduce Motion press substitution -- unchanged from the retired
    // pill's own press state (ContinueIslandButtonStyle itself was not
    // touched by this task); source-pinned, see the file-header comment for
    // why this can't be exercised behaviorally. ────────────────────────────

    func test_source_reduceMotionPressSubstitution_dropsScaleAndUsesOpacityDipInstead() throws {
        let source = try componentSource()

        XCTAssertTrue(
            source.contains("scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1.0)"),
            "Reduce Motion must suppress the press-state scale transform entirely -- found no `!reduceMotion &&`-guarded scaleEffect in DashboardComponents.swift"
        )
        XCTAssertTrue(
            source.contains("opacity(reduceMotion && configuration.isPressed ? 0.92 : 1.0)"),
            "Reduce Motion must substitute a brief opacity dip in place of the scale transform -- found no matching reduceMotion-gated opacity dip in DashboardComponents.swift"
        )
    }

    // ── Source-pinned construction details (design-spec.md's Option 2's
    // exact locked values) -- not reachable via ViewInspector: AngularGradient
    // has no `ShapeStyle` extraction support in this project's vendored
    // ViewInspector, and colors/fonts applied via string-hex/system-image
    // literals inside a `private` computed property aren't independently
    // observable at runtime either. Pinned by reading the real shipped
    // source, the same technique this file already used for the retired
    // pill's own token values. ───────────────────────────────────────────

    func test_source_glyphIsChevronRight_boldWeight_darkBrownColor_withOpticalOffset() throws {
        let source = try componentSource()

        XCTAssertTrue(
            source.contains(#"Image(systemName: "chevron.right")"#),
            "the Continue button's glyph must be chevron.right"
        )
        XCTAssertTrue(
            source.contains(".font(.system(size: iconSize, weight: .bold))"),
            "the glyph must be bold weight (not semibold -- semibold is option 1's icon weight) at the resolved-diameter-derived iconSize, not a static 20pt"
        )
        XCTAssertTrue(
            source.contains("private var iconSize: CGFloat { resolvedDiameter * 0.38 }"),
            "iconSize must be a fixed 38% of the resolved (post-clamp, post-@ScaledMetric) diameter"
        )
        XCTAssertTrue(
            source.contains(".offset(x: -1)"),
            "the glyph must carry the -1pt x-axis optical offset, nudging it toward the circle's leading edge"
        )
    }

    func test_source_fillIsDiagonalGoldGradient_topLeadingToBottomTrailing() throws {
        let source = try componentSource()

        XCTAssertTrue(
            source.contains(##"LinearGradient(colors: [Color(hex: "#EEAC3F"), Color(hex: "#C88C2C")],"##) &&
            source.contains(".topLeading, endPoint: .bottomTrailing)"),
            "the circle's fill must be LinearGradient(#EEAC3F -> #C88C2C) direction .topLeading -> .bottomTrailing -- a deliberate change from the retired pill's horizontal .leading -> .trailing, so the light direction agrees with the top rim highlight and the downward ambient shadow"
        )
    }

    func test_source_rimIsStrokeBorderAngularGradient_correctlyCenteredOnTop() throws {
        let source = try componentSource()

        XCTAssertTrue(
            source.contains(##"let rimColor = Color(hex: "#FBE8C0").opacity(0.8)"##),
            "the option-2-specific rim color must be #FBE8C0 @ 0.8 -- not the other options' standard #F5D392 @ 0.35 top-fade rim"
        )
        XCTAssertTrue(
            source.contains("Circle().strokeBorder(rimGradient, lineWidth: 2)"),
            "the rim must be drawn .strokeBorder at 2pt, so the stroke sits fully inside the circle's own silhouette rather than bleeding past the fill edge"
        )
        // SwiftUI's AngularGradient places 0° at 3-o'clock, sweeping
        // clockwise -- top is 270° in its own coordinate system. The
        // generation pass's own disclosed false start got this wrong on the
        // first attempt (assumed 0°-at-top); pin the corrected stop
        // locations directly so a regression back to that false start (or
        // any other offset) fails here.
        let expectedStops = [
            ".init(color: .clear, location: 0.0),",
            ".init(color: .clear, location: 200.0 / 360.0),    // 270 - 70",
            ".init(color: rimColor, location: 225.0 / 360.0),  // 270 - 45",
            ".init(color: rimColor, location: 315.0 / 360.0),  // 270 + 45",
            ".init(color: .clear, location: 340.0 / 360.0),    // 270 + 70",
            ".init(color: .clear, location: 1.0),",
        ]
        for stop in expectedStops {
            XCTAssertTrue(
                source.contains(stop),
                "expected AngularGradient stop `\(stop)` -- the rim must be full bright ±45° from top (270°±45° = 225°/315°), fading to clear by ±70° (200°/340°), correctly re-centered on top rather than the false start's un-shifted 0°-at-top assumption"
            )
        }
    }

    func test_source_shadowStack_unchangedFromRetiredPill_allThreeLayers() throws {
        let source = try componentSource()

        XCTAssertTrue(
            source.contains(".shadow(color: .black.opacity(0.40), radius: gutter + 2, x: 0, y: 0)"),
            "separation shadow layer must be unchanged: black @0.40, radius = gutter + 2 (14pt), 0/0 offset"
        )
        XCTAssertTrue(
            source.contains(".shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)"),
            "ambient shadow layer must be unchanged: black @0.55, radius 10, y+4"
        )
        XCTAssertTrue(
            source.contains(".shadow(color: .black.opacity(0.40), radius: 3, x: 0, y: 1)"),
            "contact shadow layer must be unchanged: black @0.40, radius 3, y+1"
        )
    }

    func test_source_scaledMetricDiameter_declaredWithLockedBaseAndRelativeToSubheadline() throws {
        let source = try componentSource()

        XCTAssertTrue(
            source.contains("@ScaledMetric(relativeTo: .subheadline) private var diameter: CGFloat = 52"),
            "diameter must be @ScaledMetric(relativeTo: .subheadline) with a 52pt base value"
        )
        XCTAssertTrue(
            source.contains("min(max(diameter, 52), 72)"),
            "resolvedDiameter must clamp the scaled diameter to the locked 52...72 range"
        )
    }

    // ── Card join: plain overlap, no notch -- the card must always use the
    // plain glassCard(cornerRadius:) overload (generation.json's "THE NOTCH"
    // fix), never a shape-based notch-cutting overload. ────────────────────

    func test_source_cardBody_usesPlainGlassCardCornerRadiusOverload_noNotch() throws {
        let source = try componentSource()

        XCTAssertTrue(
            source.contains(".glassCard(cornerRadius: cardCornerRadius, tint: Color(hex: \"#2A1B0B\").opacity(0.14), blurBoost: 4)"),
            "the populated card's body must use the plain glassCard(cornerRadius:) overload -- the card join is a plain overlap with no notch, per design-spec.md's Option 2"
        )
    }

    // ── Dead-code removal: the entire retired pill/chamfer/notch subsystem
    // must be gone from the live source, not left as silent unreferenced
    // cruft (intake-spec.md's open question 1, resolved by frontend as
    // "delete outright") ────────────────────────────────────────────────

    func test_source_retiredPillChamferNotchSubsystem_isFullyRemoved() throws {
        let source = try componentSource()

        // Strip `//` line comments before searching -- this file's own
        // header-comment prose *legitimately* names several of these
        // retired symbols when documenting their removal (e.g. "the
        // `shape:`/split-stroke `glassCard` overloads... were removed by
        // task 20260828-continue-button-circle-implementation"), which is
        // exactly the kind of removal rationale the intake spec's open
        // question 1 asked for, not dead code left in the live path. Only a
        // reference in actual compiled code -- a real declaration or call
        // site -- should fail this test.
        let codeOnly = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let range = line.range(of: "//") { return line[..<range.lowerBound] }
                return line
            }
            .joined(separator: "\n")

        let retiredSymbols = [
            "ContinueIslandShape", "NoteResumeCardNotch", "NoteResumeCardShape",
            "NotchedCardMaterial", "chamferEdgeIntersections", "chamferGeometryIsValid",
            "chamferTreatmentFitsIslandRadius", "notchTreatmentFits", "fallbackContinueCapsule",
            "measuringLabel", "islandCornerRadius", "chamferJoin", "notchStrokeColor",
            "func glassCard(shape:",
        ]
        for symbol in retiredSymbols {
            XCTAssertFalse(
                codeOnly.contains(symbol),
                "the retired pill/chamfer/notch subsystem must be fully removed from DashboardComponents.swift's live code -- found a lingering reference to `\(symbol)` outside a comment"
            )
        }
    }
}
