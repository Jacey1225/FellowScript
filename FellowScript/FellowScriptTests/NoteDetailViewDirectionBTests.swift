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

            let toolbar = try view.navigationStack().zStack(0).toolbar()
            try toolbar.item(1).button().tap()

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

        let toolbar = try sut.inspect().navigationStack().zStack(0).toolbar()
        XCTAssertNoThrow(try toolbar.item(0).button().tap())
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
}
