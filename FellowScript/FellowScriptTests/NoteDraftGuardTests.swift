// NoteDraftGuardTests.swift — task 20261115-ipad-askai-notegate (item 2, testing gate).
// Dirty rule, proceed/confirm decision, editorSurvives across layout changes.

import XCTest
@testable import FellowScript

final class NoteDraftGuardTests: XCTestCase {

    private func snap(_ title: String = "", _ html: String = "", _ verses: [String] = [], _ pub: Bool = false) -> NoteDraftSnapshot {
        NoteDraftGuard.snapshot(title: title, bodyHTML: html, verses: verses, isPublic: pub)
    }

    // MARK: dirty rule
    func test_emptyNewNote_untouched_isClean() {
        XCTAssertFalse(NoteDraftGuard.isDirty(baseline: snap(), current: snap()))
        // rich-text view re-serializing an empty body to empty markup is still clean
        XCTAssertFalse(NoteDraftGuard.isDirty(baseline: snap(), current: snap("", "<p><br></p>")))
        XCTAssertFalse(NoteDraftGuard.isDirty(baseline: snap(), current: snap("  \n ", "  ")))
    }

    func test_newNote_typedTitleOrBody_isDirty() {
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: snap(), current: snap("Hi")))
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: snap(), current: snap("", "<p>x</p>")))
    }

    func test_untouchedVersePrefill_isClean_butEditedIsDirty() {
        let prefill = snap("", "<p>John 3:16</p>", ["John 3:16"])
        XCTAssertFalse(NoteDraftGuard.isDirty(baseline: prefill, current: prefill))
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: prefill, current: snap("", "<p>John 3:16 love</p>", ["John 3:16"])))
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: prefill, current: snap("T", "<p>John 3:16</p>", ["John 3:16"])))
    }

    func test_existingNote_unmodifiedClean_modifiedDirty() {
        let base = snap("Title", "<p>Body text</p>", ["Rom 8:1"], true)
        XCTAssertFalse(NoteDraftGuard.isDirty(baseline: base, current: snap("Title", "<p>Body text</p>", ["Rom 8:1"], true)))
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: base, current: snap("Title2", "<p>Body text</p>", ["Rom 8:1"], true)))
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: base, current: snap("Title", "<p>Body texts</p>", ["Rom 8:1"], true)))
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: base, current: snap("Title", "<p>Body text</p>", ["Rom 8:1", "Rom 8:2"], true)))
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: base, current: snap("Title", "<p>Body text</p>", [], true)))
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: base, current: snap("Title", "<p>Body text</p>", ["Rom 8:1"], false)))
    }

    func test_publicToggleAlone_isDirty() {
        XCTAssertTrue(NoteDraftGuard.isDirty(baseline: snap(), current: snap("", "", [], true)))
    }

    func test_whitespaceAndMarkupOnlyDifferences_areClean() {
        let a = snap("Title", "<p>Hello   world</p>")
        let b = snap("  Title  ", "<div>Hello\n world</div>")
        XCTAssertFalse(NoteDraftGuard.isDirty(baseline: a, current: b))
        XCTAssertEqual(NoteDraftGuard.normalizedBody("<p>a</p>  <p> b </p>"), "a b")
    }

    // MARK: decision
    func test_decision_dirty() {
        XCTAssertEqual(NoteDraftGuard.decision(dirty: false), .proceed)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true), .confirm)
    }

    // MARK: layout changes
    private let base = WorkspaceDockLayout.default

    func test_layout_selectAlreadyActiveNotes_proceeds() {
        var after = base; after.activate(.notes)
        XCTAssertTrue(NoteDraftGuard.editorSurvives(before: base, after: after))
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: after), .proceed)
    }

    func test_layout_switchOtherTabInNotesDock_confirms() {
        var after = base; after.activate(.highlights)
        XCTAssertFalse(NoteDraftGuard.editorSurvives(before: base, after: after))
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: after), .confirm)
        after = base; after.activate(.messages)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: after), .confirm)
    }

    func test_layout_moveNotesToOtherDock_confirms() {
        var after = base; after.move(.notes, to: .centerTop)
        XCTAssertFalse(NoteDraftGuard.editorSurvives(before: base, after: after))
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: after), .confirm)
    }

    func test_layout_closeNotes_confirms() {
        var after = base; after.close(.notes)
        XCTAssertFalse(NoteDraftGuard.editorSurvives(before: base, after: after))
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: after), .confirm)
    }

    func test_layout_resetFromCustomLayout_confirms_resetFromDefault_proceeds() {
        var custom = base; custom.move(.notes, to: .centerTop)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: custom, after: .default), .confirm)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: .default), .proceed)
    }

    func test_layout_unrelatedDockChanges_proceed() {
        var a = base; a.move(.messages, to: .centerTop)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: a), .proceed)
        var b = base; b.close(.highlights)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: b), .proceed)
        var c = base; c.close(.bible)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: c), .proceed)
    }

    /// Reorder-nudging a sibling tab ("Move Earlier/Later") makes it the active
    /// tab (Layout.move activates the moved tab), which unmounts the Notes editor.
    func test_layout_nudgeSiblingTab_activatesIt_soGuardConfirms_nudgeNotesProceeds() {
        var sibling = base; sibling.nudge(.highlights, by: 1)
        XCTAssertEqual(sibling.activeTab(in: .right), .highlights)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: sibling), .confirm)
        var notes = base; notes.nudge(.notes, by: 1)
        XCTAssertEqual(notes.activeTab(in: .right), .notes)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true, before: base, after: notes), .proceed)
    }

    /// Wiring: the Move Earlier/Later action must go through the unsaved-note gate.
    func test_workspaceView_nudgeAction_isRoutedThroughGuardLayout() throws {
        let src = try source("FellowScript/Workspace/WorkspaceView.swift")
        let r = try XCTUnwrap(src.range(of: "nudge: { delta in"))
        let rest = src[r.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "reset:"))
        let tail = String(rest[..<end.lowerBound])
        XCTAssertTrue(tail.contains("guardLayout"), "nudge activates the tab so it must be gated like select/move")
    }

    func test_layout_clean_alwaysProceeds() {
        var a = base; a.close(.notes)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: false, before: base, after: a), .proceed)
        var b = base; b.activate(.highlights)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: false, before: base, after: b), .proceed)
    }

    func test_editorSurvives_falseWhenNotesNotActiveBefore() {
        var before = base; before.activate(.highlights)
        XCTAssertFalse(NoteDraftGuard.editorSurvives(before: before, after: before))
    }

    // MARK: verse handoff while dirty (consumePendingNoteDraft routes through decision(dirty:))
    func test_verseHandoff_whileDirty_confirms_whileClean_proceeds() {
        XCTAssertEqual(NoteDraftGuard.decision(dirty: true), .confirm)
        XCTAssertEqual(NoteDraftGuard.decision(dirty: false), .proceed)
    }

    private func source(_ rel: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "FellowScriptTests" { url.deleteLastPathComponent() }
        url.deleteLastPathComponent()
        return try String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8)
    }

    /// Structural guard: the handoff must be gated on a dirty open editor, must
    /// park the draft when confirm, and the discard path must clear the stash.
    func test_verseHandoff_source_gatesOnDirtyEditorAndClearsStash() throws {
        let src = try source("FellowScript/Notes/NotesListView+DraftGuard.swift")
        let consume = try XCTUnwrap(src.range(of: "func consumePendingNoteDraft"))
        let apply = try XCTUnwrap(src.range(of: "func applyHandoff"))
        let body = String(src[consume.lowerBound..<apply.lowerBound])
        XCTAssertTrue(body.contains("showEditor, NoteDraftGuard.decision(dirty: editorDirty) == .confirm"))
        XCTAssertTrue(body.contains("handoffDraft = draft"))
        let applyBody = String(src[apply.lowerBound...])
        XCTAssertTrue(applyBody.contains("appState.noteDraftStash = nil"))
        XCTAssertTrue(applyBody.contains("editorDirty    = false"))
    }
}
