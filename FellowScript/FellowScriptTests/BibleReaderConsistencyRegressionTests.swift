// BibleReaderConsistencyRegressionTests.swift — coverage for task
// 20260830-bible-reader-consistency (testing gate).
//
// Proves the two real defects this task fixed, against the actual shipped
// source, so a regression of either one fails here rather than only being
// caught by a future manual screenshot comparison:
//
//   1. BibleReaderView's full-page background now uses the shared
//      `Theme.bgPage` token (identical to every other screen in the app)
//      instead of the bespoke, near-but-not-identical `Theme.bibleBg`. The
//      `bibleBg` token itself is now fully retired from Theme.swift.
//   2. The book/chapter nav pill (BibleReaderView's toolbar leading item, the
//      literal "Bible navigation button" the request referred to) no longer
//      carries the `.overlay(Capsule().stroke(Theme.borderGold, ...))` outer
//      capsule outline it used to.
//
// Following this project's established technique (see
// EmberGlassFidelityPassRegressionTests.swift's
// SenderGroupDividerRemovalRegressionTests) for pinning render-tree facts
// that ViewInspector can't cheaply assert on (an *absent* modifier, an exact
// Color token identity) by reading the real shipped source directly rather
// than re-deriving them from a hosted view.
//
// Explicitly re-confirms two "must NOT regress" boundaries from the intake
// spec's Out-of-bounds section, which a careless global find/replace on
// either token could have silently violated:
//   - `Theme.borderGold` itself, and every OTHER bordered pill that
//     legitimately uses it elsewhere in the app (Account/Chat/Onboarding/
//     Notes), must be untouched.
//   - `BibleNavDropdown`'s own surfaces (`Theme.islandBg` for the panel,
//     the OT/NT segmented pill's own separate stroke) must be untouched —
//     they were never bespoke/deviant and were out of scope.
//     (Superseded below by task 20260830-bible-nav-dropdown-blur, which
//     explicitly brought BibleNavDropdown's backgrounds into scope — see
//     that test's own updated assertion.)

import XCTest
import SwiftUI
@testable import FellowScript

final class BibleReaderConsistencyRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - 1. Background now uses the shared Theme.bgPage token

    func test_source_bibleReaderView_pageBackground_usesSharedBgPageToken_notBespokeBibleBg() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(
            source.contains("Theme.bgPage.ignoresSafeArea()"),
            "BibleReaderView's full-page background must use the same Theme.bgPage token every other screen (ContentView, DashboardView, AccountView, etc.) uses, so the Bible reader's background tone exactly matches the rest of the app"
        )
        XCTAssertFalse(
            source.contains("Theme.bibleBg"),
            "BibleReaderView must no longer reference the retired, bespoke Theme.bibleBg token at all"
        )
    }

    func test_source_themeSwift_bibleBgToken_isFullyRetired() throws {
        // Confirms the now-fully-unused bibleBg token itself was deleted from
        // Theme.swift, per this repo's no-dead-code convention (spec's open
        // question, resolved by the frontend gate) — not just unreferenced.
        let source = try readSource("FellowScript/Theme/Theme.swift")
        XCTAssertFalse(
            source.contains("bibleBg"),
            "Theme.bibleBg must be deleted from Theme.swift now that BibleReaderView no longer uses it — leaving a dead token behind would violate this repo's existing convention"
        )
    }

    func test_source_themeSwift_bgPageToken_stillPresentAndUnchanged() throws {
        // Guards against an over-eager rename that also touched the
        // app-wide token this fix is unifying onto.
        let source = try readSource("FellowScript/Theme/Theme.swift")
        XCTAssertTrue(
            source.contains(##"static let bgPage      = Color(hex: "#1E1812")"##),
            "the shared Theme.bgPage token BibleReaderView now unifies onto must remain exactly as every other screen already uses it"
        )
    }

    // MARK: - 2. Book/chapter nav pill no longer has an outer capsule outline

    func test_source_bibleReaderView_navPill_noLongerHasCapsuleStrokeOverlay() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertFalse(
            source.contains(".overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))"),
            "the book/chapter nav pill (toolbar leading item, 'Navigate to book and chapter') must no longer render an outer capsule outline/stroke"
        )
    }

    func test_source_bibleReaderView_navPill_stillHasItsOtherStyling_onlyTheStrokeWasRemoved() throws {
        // Narrow-scope guard: the fix should have removed only the
        // .overlay(...) stroke line, not collaterally stripped the pill's
        // background fill or capsule shape (which are unrelated to "outer
        // outline" and must survive untouched).
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(
            source.contains(".background(Theme.gold.opacity(0.10))"),
            "the nav pill's background fill must be untouched by the outline-removal fix"
        )
        XCTAssertTrue(
            source.contains("Text(\"\\(vm.curBook) \\(vm.curChapter)\")"),
            "the nav pill's book/chapter label content must be untouched"
        )
    }

    func test_source_bibleReaderView_otNtSegmentedPill_isUnrelatedAndUntouched() throws {
        // Out-of-bounds guard: BibleNavDropdown's own OT/NT segmented pill
        // (testamentToggle) has its own separate stroke
        // (Theme.parchment.opacity(0.13)) that was never part of this
        // request's scope ("that Bible navigation button" = the toolbar
        // book/chapter pill, not this internal panel control) and must not
        // have been collaterally touched.
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(
            source.contains(".overlay(Capsule().stroke(Theme.parchment.opacity(0.13), lineWidth: 1))"),
            "BibleNavDropdown's unrelated OT/NT segmented-pill stroke is out of this task's scope and must remain exactly as it was"
        )
    }

    // MARK: - Out-of-bounds guard: Theme.borderGold itself, and other bordered
    // pills elsewhere in the app, must be untouched (spec's explicit
    // narrow-scope instruction — remove the border from only this one pill).

    func test_source_themeSwift_borderGoldToken_stillDefined_forOtherPillsToKeepUsing() throws {
        let source = try readSource("FellowScript/Theme/Theme.swift")
        XCTAssertTrue(
            source.contains(##"static let borderGold      = Color(hex: "#D4922A").opacity(0.32)"##),
            "Theme.borderGold is a shared token used by other legitimately-bordered pills elsewhere in the app (Account/Chat/Onboarding/Notes) and must not have been removed or altered by this Bible-reader-only fix"
        )
    }

    func test_source_accountView_borderedPill_stillHasItsOwnCapsuleStrokeOverlay() throws {
        // Representative "other bordered pill elsewhere in the app" from the
        // spec's own investigation notes (AccountView.swift:929) — confirms
        // the fix was scoped to BibleReaderView's one pill, not a global
        // strip of every Capsule().stroke(Theme.borderGold, ...) occurrence.
        let source = try readSource("FellowScript/Account/AccountView.swift")
        XCTAssertTrue(
            source.contains(".overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))"),
            "AccountView's own bordered pill is an established, unrelated use of Theme.borderGold and must be unaffected by the Bible reader's outline removal"
        )
    }

    func test_source_chatThreadView_borderedPill_stillHasItsOwnCapsuleStrokeOverlay() throws {
        // Same guard as above, for the spec's other named example
        // (ChatThreadView.swift:752).
        let source = try readSource("FellowScript/Chat/ChatThreadView.swift")
        XCTAssertTrue(
            source.contains(".overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))"),
            "ChatThreadView's own bordered pill is an established, unrelated use of Theme.borderGold and must be unaffected by the Bible reader's outline removal"
        )
    }

    // MARK: - Out-of-bounds guard: BibleNavDropdown's already-consistent
    // surfaces (islandBg) were not implicated by this request and must be
    // untouched.

    // Superseded by task 20260830-bible-nav-dropdown-blur: BibleNavDropdown's
    // background was explicitly out of scope for *this* task
    // (20260830-bible-reader-consistency), but the later task deliberately
    // replaced the opaque `Theme.islandBg`/`Theme.widgetBg` fills with a
    // translucent, blurred panel background (per that task's own regression
    // coverage, BibleNavDropdownBlurScreenshotUITests.swift, plus the source
    // assertions below) — so `Theme.islandBg` no longer appears in this file
    // at all, which is the new correct, intentional state.
    func test_source_bibleNavDropdown_backgroundIsNowTranslucentBlur_perLaterTask() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertFalse(
            source.contains(".background(Theme.islandBg)"),
            "Theme.islandBg's usage as a BibleNavDropdown background was deliberately retired by task 20260830-bible-nav-dropdown-blur"
        )
        XCTAssertTrue(
            source.contains(".background(Theme.panelGlassTint)") && source.contains(".background(.ultraThinMaterial)"),
            "expected BibleNavDropdown's outer panel to use the translucent tint + Material blur pair introduced by task 20260830-bible-nav-dropdown-blur"
        )
    }
}
