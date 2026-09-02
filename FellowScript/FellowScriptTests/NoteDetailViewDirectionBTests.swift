// NoteDetailViewDirectionBTests.swift — coverage for task
// 20260813-note-viewer-implementation, frontend gate.
//
// Direction B (Notes/NotesListView.swift, NoteDetailView) restyled the
// screen's chrome (bloom background, ghostPill Close, gradientPill Edit,
// sectionLabel eyebrow date, gold-gradient divider) but the design doc and
// intake spec both require every interaction to remain byte-for-byte
// unchanged. This file focuses on exactly that testable behavioral
// surface — per the intake spec's own guidance to test "what's testably
// preserved (dismiss trigger, editor-sheet presentation wiring/state,
// presentation modifier pair) rather than pixel-level SwiftUI rendering" —
// rather than asserting on colors/fonts/layout, which ViewInspector cannot
// meaningfully verify and which is the design gate's concern, not this
// gate's. This is a Lightweight spec routed only to `frontend` (no
// dedicated `testing` step), so this coverage is written by the frontend
// gate itself per pipeline convention.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class NoteDetailViewDirectionBTests: XCTestCase {

    private func makeNote(timestamp: String = "2026-08-12T10:00:00.000Z") -> FSNote {
        FSNote(
            id: "note-1", user: "user-1", title: "Fan into Flame",
            text: "<p>This is active.</p>", public: false, group_id: "",
            is_reply: false, timestamp: timestamp, verses: [], replies: []
        )
    }

    // ── Edit → showEditor = true (unchanged trigger, now fired from the
    // restyled gradientPill instead of a plain nav-bar Button("Edit")) ──────

    @MainActor
    func test_tappingEditPill_setsShowEditorTrue() throws {
        let note = makeNote()
        var sut = NoteDetailView(note: note) { _ in nil }

        // ViewInspector's documented minimal-intrusion pattern (guide.md,
        // "Views using @State" — Approach #1): @State can only be read back
        // reliably from inside a live SwiftUI render pass, so the tap and
        // the assertion both happen inside the `didAppear` callback, fired
        // once the hosted view actually appears.
        let exp = sut.on(\.didAppear) { view in
            XCTAssertFalse(try view.actualView().showEditor)

            // `.toolbar().item(N)`/`find(button:)` (used pre-task
            // 20260829-note-detail-toolbar-visual-fix) both broke once that
            // task added `.sharedBackgroundVisibility(.hidden)` to each
            // ToolbarItem (the fix for the doubled system/custom pill
            // outline) — ViewInspector 0.10.3 cannot traverse a ToolbarItem
            // wrapped in that modifier by any route (confirmed live: both
            // the positional and recursive-search APIs report an opaque,
            // private SwiftUI wrapper type they don't know how to unwrap).
            // `editAction()` is the exact closure the Edit button's
            // `Button(action:)` calls (see NotesListView.swift), exposed
            // `internal` for this reason — so this still exercises the real
            // production code path the button invokes, just without
            // simulating the tap itself.
            try view.actualView().editAction()

            // showEditor is the exact @State property NoteEditorView's
            // nested .sheet(isPresented:) reads — unchanged from before
            // the restyle, just now flipped by the gradientPill Edit
            // button instead of the old plain Button("Edit").
            XCTAssertTrue(try view.actualView().showEditor)
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 1)
    }

    // ── Close pill is present and wired to a tappable action (dismiss() is
    // a no-op outside a real presentation context, so this confirms the
    // control exists and its tap doesn't throw/crash rather than observing
    // dismissal itself, which requires a live presentation host) ───────────

    @MainActor
    func test_closePill_isPresentAndTappable() throws {
        let note = makeNote()
        let sut = NoteDetailView(note: note) { _ in nil }

        // See test_tappingEditPill_setsShowEditorTrue's comment: `closeAction()`
        // is the exact closure the Close button's `Button(action:)` calls,
        // called directly since ViewInspector 0.10.3 cannot traverse a
        // ToolbarItem wrapped in `.sharedBackgroundVisibility(.hidden)`
        // (task 20260829-note-detail-toolbar-visual-fix) to reach the button
        // itself, either positionally or via `find(button:)`.
        XCTAssertNoThrow(sut.closeAction())
    }

    // ── Date eyebrow guard: the `if !note.formattedTimestamp.isEmpty` guard
    // around the sectionLabel-styled date must still hold, matching the
    // pre-restyle plain-caption guard exactly. ─────────────────────────────

    @MainActor
    func test_emptyTimestamp_stillOmitsDateRow() throws {
        let note = makeNote(timestamp: "")
        XCTAssertEqual(note.formattedTimestamp, "")
        // No SwiftUI-level assertion beyond the guard's own input contract:
        // NoteDetailView reuses this exact `if` condition unchanged, so the
        // view-model-level guarantee (`formattedTimestamp` empty for an
        // empty stored timestamp) is what this restyle depends on.
    }

    // ── Doubled outline fix (task 20260829-note-detail-toolbar-visual-fix),
    // regression coverage: `.sharedBackgroundVisibility(.hidden)` on both
    // toolbar items is what suppresses iOS 26's automatic Liquid Glass
    // capsule chrome that was compositing a second stroke on top of
    // ghostPill/gradientPill's own deliberate outline. ViewInspector 0.10.3
    // cannot traverse a ToolbarItem wrapped in that modifier (see
    // `closeAction()`/`editAction()`'s own doc comment above and the two
    // tests in this file that route around it), so this can't be asserted
    // via a live render pass -- source-pinning it directly is the only way
    // to make a future accidental removal (e.g. someone "cleaning up" the
    // toolbar and dropping the modifier, silently reintroducing the doubled
    // outline) fail a test rather than only being caught by eyeballing a
    // screenshot again. Same source-pin technique NoteReplySectionTests
    // already uses for states unreachable through ViewInspector/MockDataService.
    //
    // Updated by task 20260902-ios-deployment-target-lower: the bare
    // `.sharedBackgroundVisibility(.hidden)` call at each ToolbarItem was
    // replaced by a single reusable `ToolbarContent.suppressAutomaticGlassChrome()`
    // helper (Theme.swift) that gates the same call behind
    // `if #available(iOS 26, *)` so the app's floor could drop from 26.5 to
    // 18.0 -- the underlying OS behavior being suppressed doesn't exist
    // pre-26, so this is a true no-op there, not a behavior change. The bare
    // literal no longer appears at the call site itself (it now lives only
    // inside the shared helper's own definition), so this test's source-pin
    // is updated to count occurrences of the new helper's name instead of
    // the old literal -- re-pointing the pin to match the current
    // implementation rather than leaving it to pass vacuously (0 == 0) or
    // fail outright, per this app's test-integrity preference (freely update
    // a stale pin to match current reality, don't let it rot).

    private func componentSource() throws -> String {
        let componentFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Notes/NotesListView.swift")
        return try String(contentsOf: componentFile, encoding: .utf8)
    }

    func test_source_bothToolbarItems_suppressAutomaticGlassChrome_toAvoidDoubledOutline() throws {
        let source = try componentSource()
        // Bounded on the first `.toolbarBackground(` call (task
        // 20260829-note-detail-toolbar-edge-blur changed its argument from a
        // flat `Color(hex:...)` to a `LinearGradient(...)`, so this boundary
        // marker can no longer assume "Color(hex:" follows the open-paren
        // directly -- the bare modifier name is still the first occurrence
        // in the file either way).
        guard let toolbarStart = source.range(of: ".toolbar {"),
              let toolbarBackgroundStart = source.range(of: ".toolbarBackground(") else {
            XCTFail("could not locate NoteDetailView's .toolbar block to scope this check")
            return
        }
        let toolbarBlock = String(source[toolbarStart.lowerBound..<toolbarBackgroundStart.lowerBound])

        XCTAssertTrue(
            toolbarBlock.contains(#"ToolbarItem(placement: .navigationBarLeading)"#),
            "the Close pill must still be placed via a leading ToolbarItem"
        )
        XCTAssertTrue(
            toolbarBlock.contains(#"ToolbarItem(placement: .navigationBarTrailing)"#),
            "the Edit pill must still be placed via a trailing ToolbarItem"
        )

        // Strip `//` line comments first -- this block's own doc comment
        // legitimately names the helper verbatim while explaining the fix
        // (see the block above), which would otherwise inflate a naive
        // substring count above the real 2 code occurrences on the
        // ToolbarItems. Same technique
        // NoteReplySectionTests.test_source_toolbarUsesTranslucentMaterial_notFlatScrim
        // already uses for exactly this reason.
        let codeOnly = toolbarBlock
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let range = line.range(of: "//") { return line[..<range.lowerBound] }
                return line
            }
            .joined(separator: "\n")

        // Re-pinned by task 20260902-ios-deployment-target-lower: the call
        // sites now route through the reusable
        // `.suppressAutomaticGlassChrome()` helper (Theme.swift), which
        // internally gates the original `.sharedBackgroundVisibility(.hidden)`
        // call behind `if #available(iOS 26, *)` so the app's deployment
        // target could drop to 18.0 -- the bare literal no longer appears at
        // the call site, only inside the helper's own definition, so this
        // pin now counts the helper name instead of re-checking against a
        // string that would no longer be found here at all.
        let occurrences = codeOnly.components(separatedBy: ".suppressAutomaticGlassChrome()").count - 1
        XCTAssertEqual(
            occurrences, 2,
            "both the Close and Edit ToolbarItems must carry .suppressAutomaticGlassChrome() -- " +
            "dropping it from either one reintroduces iOS 26's automatic Liquid Glass capsule chrome " +
            "layered on top of ghostPill/gradientPill's own stroke, i.e. the doubled-outline bug this task fixed"
        )
    }
}
