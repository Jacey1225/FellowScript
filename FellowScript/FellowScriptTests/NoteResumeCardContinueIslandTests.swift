// NoteResumeCardContinueIslandTests.swift — coverage for task
// 20260827-note-continue-island, testing step (step 4).
//
// Covers the geometry-adjacent behavior called for by architecture step 4
// and the intake spec's acceptance criteria for the new "Continue" capsule
// island (design-spec.md §2.2/§2.3/§3/§4) that replaced NoteResumeCard's old
// full-width "Open note / where you left off" pill:
//
//   - text-only control, no trailing icon (design-spec.md §7 non-goal)
//   - accessibility label "Continue reading <title>" (§4), including the
//     "Untitled note" fallback
//   - tap wiring survives the restyle
//   - `.contentShape(Rectangle())` (§3 step 9) — the chamfer must not shrink
//     the tap target
//   - the §2.2 44pt height floor survives at default measurement
//   - the note == nil empty state never renders the island (confirms design
//     step 1's decision holds structurally, not just by construction review)
//   - the §4 Dynamic-Type/width fallback: a narrow available card width
//     collapses the notch/island treatment to the full-width in-card capsule
//     (proxying "Dynamic Type fallback threshold engagement" — the fallback
//     is driven by the same live-measured-width comparison Dynamic Type
//     growth also feeds, so a narrow container exercises the identical
//     `notchTreatmentFits` code path a large type size would)
//
// Reduce Motion's press-state substitution (§2.4) lives entirely inside
// `ContinueIslandButtonStyle`, a `private` file-scoped type not reachable via
// `@testable import` from this file, and ViewInspector's `.tap()` invokes a
// Button's action directly without driving SwiftUI's real press-state
// machinery (`configuration.isPressed` never becomes true), so the
// press-time visual substitution can't be exercised behaviorally from an
// XCTest. Rather than skip that acceptance criterion, this file pins the
// exact substitution formula by reading the real shipped source, the same
// technique this codebase already uses for a similarly unreachable
// `private`/non-ViewInspectable implementation detail — see
// LoadingScreenAssetTransparencyTests.test_loadingScreenSource_frameSize_isIconScale_notFullBleed.

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

    // ── Text-only control, no icon (design-spec.md §7 non-goal) ────────────

    func test_populatedNote_continueControl_isTextOnly_noIconGlyph() throws {
        let sut = NoteResumeCard(note: makeNote()) {}

        XCTAssertNoThrow(try sut.inspect().find(button: "Continue"))
        XCTAssertThrowsError(
            try sut.inspect().find(ViewType.Image.self),
            "the new Continue island must be text-only -- no trailing icon like the retired pill's circular arrow"
        ) { _ in }
    }

    // ── Accessibility label (§4) ────────────────────────────────────────────

    func test_populatedNote_continueButton_accessibilityLabel_includesNoteTitle() throws {
        let sut = NoteResumeCard(note: makeNote(title: "Sunday Service 06/28")) {}
        let button = try sut.inspect().find(button: "Continue")
        XCTAssertEqual(try button.accessibilityLabel().string(), "Continue reading Sunday Service 06/28")
    }

    func test_populatedNote_emptyTitle_continueButton_accessibilityLabelFallsBackToUntitledNote() throws {
        let sut = NoteResumeCard(note: makeNote(title: "")) {}
        let button = try sut.inspect().find(button: "Continue")
        XCTAssertEqual(try button.accessibilityLabel().string(), "Continue reading Untitled note",
                       "an empty note title must fall back to the same 'Untitled note' label used elsewhere in this component, not a blank/broken accessibility label")
    }

    // ── Tap wiring survives the restyle ─────────────────────────────────────

    func test_populatedNote_tappingContinueButton_invokesOnOpen() throws {
        var opened = false
        let sut = NoteResumeCard(note: makeNote()) { opened = true }
        try sut.inspect().find(button: "Continue").tap()
        XCTAssertTrue(opened)
    }

    // ── Tap target survives the chamfer (§3 step 9) ─────────────────────────

    func test_populatedNote_continueButton_hasContentShapeRectangle_soChamferDoesNotShrinkTapTarget() throws {
        let sut = NoteResumeCard(note: makeNote()) {}
        let button = try sut.inspect().find(button: "Continue")
        XCTAssertNoThrow(
            try button.contentShape(Rectangle.self),
            "the Continue island must apply .contentShape(Rectangle()) so the visual chamfer cut doesn't also cut into the hit-testing area"
        )
    }

    // ── §2.2 44pt height floor, at default (un-hosted) label measurement ──
    // Un-hosted, `labelSize` stays at its `.zero` initial value, so
    // `islandHeight` evaluates its `max(44, labelSize.height + 22)` floor
    // directly — this pins that floor without needing a live layout pass.

    func test_populatedNote_continueIsland_defaultHeight_meetsFortyFourPointFloor() throws {
        let sut = NoteResumeCard(note: makeNote()) {}
        let label = try sut.inspect().find(text: "Continue")
        let height = try label.fixedFrame().height
        XCTAssertGreaterThanOrEqual(height, 44,
                                     "design-spec.md §2.2's islandHeight formula floors at 44pt regardless of label measurement")
    }

    // ── The island must never render in the empty (note == nil) state ──────
    // (design step 1's decision, design-notes.md — structural check, not
    // just a design-review confirmation.)

    func test_emptyState_neverRendersContinueControl() throws {
        let sut = NoteResumeCard(note: nil) {}
        XCTAssertThrowsError(
            try sut.inspect().find(button: "Continue"),
            "the note == nil empty state must keep its own original pill -- the Continue island must not render there"
        ) { _ in }
        // The empty state's own original control is untouched.
        XCTAssertNoThrow(try sut.inspect().find(text: "Start a note"))
    }

    // ── §4 fallback: a narrow live-measured card width collapses the
    // notch/island treatment back to a full-width in-card capsule ──────────
    //
    // `notchTreatmentFits` compares the live-measured island width against
    // 45% of the live-measured card width (design-spec.md §4) — the same
    // comparison that also fires when Dynamic Type grows the label. Forcing
    // a narrow host width exercises that identical code path without
    // depending on a specific Dynamic Type category being available in the
    // test environment.

    @MainActor
    private func settledContinueTexts(hostedIn width: CGFloat) throws -> [InspectableView<ViewType.Text>] {
        let sut = NoteResumeCard(note: makeNote()) {}
        ViewHosting.host(view: sut, size: CGSize(width: width, height: 500))
        defer { ViewHosting.expel() }

        // GeometryReader-driven @State (labelSize/cardWidth) updates land on
        // a subsequent render pass, not synchronously within the layout call
        // above -- pump the run loop briefly so that pass completes before
        // inspecting, mirroring this file's neighbors' use of a real
        // XCTestExpectation-driven wait for async SwiftUI state settling
        // (see NoteDetailViewDirectionBTests.test_tappingEditPill_setsShowEditorTrue).
        let exp = expectation(description: "layout settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        return try sut.inspect().findAll(ViewType.Text.self).filter { (try? $0.string()) == "Continue" }
    }

    @MainActor
    func test_wideCardWidth_keepsNotchIslandTreatment_fixedSizeCapsule() throws {
        // Wide enough that 45% of the live card width comfortably exceeds
        // the "Continue" label's intrinsic island width.
        let texts = try settledContinueTexts(hostedIn: 500)

        // The island's own button applies a fixed `.frame(width:height:)` to
        // its label -- the always-present hidden measuring label only has
        // `.fixedSize()`, not a `.frame(width:height:)`, so this uniquely
        // identifies the island (not fallback, not the measuring label).
        let islandLabel = texts.first { (try? $0.fixedFrame()) != nil }
        XCTAssertNotNil(islandLabel, "at ample card width, the notch/island treatment (fixed-size capsule) should be active, not the full-width fallback")

        // And the full-width fallback's `.frame(maxWidth: .infinity)` marker
        // must NOT be present on any "Continue" text at this width.
        let fallbackLabel = texts.first { (try? $0.flexFrame().maxWidth) == .infinity }
        XCTAssertNil(fallbackLabel, "the §4 fallback capsule must not be active at ample card width")
    }

    @MainActor
    func test_narrowCardWidth_engagesFallbackCapsule_dropsNotchTreatment() throws {
        // Narrow enough that the live card width's 45% threshold is smaller
        // than the "Continue" label's own intrinsic island width, forcing
        // the §4 fallback.
        let texts = try settledContinueTexts(hostedIn: 90)

        let fallbackLabel = texts.first { (try? $0.flexFrame().maxWidth) == .infinity }
        XCTAssertNotNil(fallbackLabel, "a card too narrow for the notch/gutter/island geometry to fit must fall back to the full-width in-card capsule per design-spec.md §4")

        let islandLabel = texts.first { (try? $0.fixedFrame()) != nil }
        XCTAssertNil(islandLabel, "the fixed-size notch/island treatment must be fully collapsed once the fallback engages, not left rendering alongside it")
    }

    // ── Reduce Motion press substitution (§2.4) — source-pinned; see the
    // file-header comment for why this can't be exercised behaviorally. ────

    func test_source_reduceMotionPressSubstitution_dropsScaleAndUsesOpacityDipInstead() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let componentFile = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Dashboard/DashboardComponents.swift")
        let source = try String(contentsOf: componentFile, encoding: .utf8)

        XCTAssertTrue(
            source.contains("scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1.0)"),
            "Reduce Motion must suppress the press-state scale transform entirely (§2.4) -- found no `!reduceMotion &&`-guarded scaleEffect in DashboardComponents.swift"
        )
        XCTAssertTrue(
            source.contains("opacity(reduceMotion && configuration.isPressed ? 0.92 : 1.0)"),
            "Reduce Motion must substitute a brief opacity dip in place of the scale transform (§2.4/§4) -- found no matching reduceMotion-gated opacity dip in DashboardComponents.swift"
        )
    }
}
