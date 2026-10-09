// VerseAddToNoteRegressionTests.swift — testing-gate coverage for task
// 20260909-verse-add-to-note / 20261009-verse-add-to-note, step 2.
//
// The verse context menu's "Add to Note" used to set a @State nothing read.
// It now presents a prefilled new-note editor. Covered here:
//   - VerseNotePrefill HTML building + escaping + no-fabrication on blank data
//   - saving a prefilled note through the shared NotesViewModel.saveNote path
//   - source-pinned wiring (private SwiftUI state is out of reach of a render)

import XCTest
@testable import FellowScript

@MainActor
final class VerseAddToNoteRegressionTests: XCTestCase {

    // MARK: prefill helper

    func test_html_buildsReferenceAndText() {
        let h = VerseNotePrefill.html(book: "John", chapter: 3, verse: 16,
                                      text: "For God so loved the world")
        XCTAssertEqual(h, "<p>John 3:16 \u{2014} For God so loved the world</p>")
    }

    func test_html_escapesMarkup() {
        let h = VerseNotePrefill.html(book: "John", chapter: 1, verse: 1,
                                      text: "<b>\"A\" & B</b>")
        XCTAssertEqual(h, "<p>John 1:1 \u{2014} &lt;b&gt;&quot;A&quot; &amp; B&lt;/b&gt;</p>")
        XCTAssertFalse(h.contains("<b>"))
    }

    func test_html_trimsWhitespace() {
        let h = VerseNotePrefill.html(book: "Psalms", chapter: 23, verse: 1, text: "  The Lord  \n")
        XCTAssertEqual(h, "<p>Psalms 23:1 \u{2014} The Lord</p>")
    }

    func test_html_missingData_returnsEmpty_notFabricated() {
        XCTAssertEqual(VerseNotePrefill.html(book: "John", chapter: 3, verse: 16, text: ""), "")
        XCTAssertEqual(VerseNotePrefill.html(book: "John", chapter: 3, verse: 16, text: "  \n "), "")
        XCTAssertEqual(VerseNotePrefill.html(book: "", chapter: 3, verse: 16, text: "x"), "")
        XCTAssertEqual(VerseNotePrefill.html(book: "John", chapter: 0, verse: 16, text: "x"), "")
        XCTAssertEqual(VerseNotePrefill.html(book: "John", chapter: 3, verse: 0, text: "x"), "")
    }

    func test_escape_ampersandFirst_noDoubleEscape() {
        XCTAssertEqual(VerseNotePrefill.escape("&lt;"), "&amp;lt;")
    }

    // MARK: save wiring

    func test_saveNote_prefilledNewNote_createsExactlyOneNote_withVerseBody() async {
        let vm = NotesViewModel()
        vm.service = ThrowingTestDataService()
        XCTAssertTrue(vm.notes.isEmpty)
        let note = FSNote(id: "n1", user: "u1", title: "", text: VerseNotePrefill.html(
            book: "John", chapter: 3, verse: 16, text: "For God so loved"))

        let ok = await vm.saveNote(note, editingId: nil, userId: "u1", authorUsername: "jacey")

        XCTAssertTrue(ok)
        XCTAssertEqual(vm.notes.count, 1)
        XCTAssertTrue(vm.notes.values.first?.text.contains("John 3:16") ?? false)
    }

    // MARK: source-pinned wiring

    private func readSource(_ relativePath: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_source_addToNoteButton_setsTarget_andDeadStateRemoved() throws {
        let s = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertFalse(s.contains("showAddToNote"), "dead placeholder state must stay removed")
        XCTAssertTrue(s.contains("addToNoteTarget = VerseNoteDraft("))
        XCTAssertTrue(s.contains(".sheet(item: $addToNoteTarget)"))
        XCTAssertTrue(s.contains(#".accessibilityLabel("Add verse \(verse) to note")"#))
    }

    func test_source_saveClosure_usesSharedSaveNote_andFailSoftContract() throws {
        let s = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(s.contains("notesVM.saveNote(saved, editingId: nil"))
        XCTAssertTrue(s.contains("if ok { return nil }"))
        XCTAssertTrue(s.contains("return notesVM.failedSaveMessage()"))
    }

    func test_source_existingContextMenuActions_untouched() throws {
        let s = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(s.contains(#".accessibilityLabel("Copy verse \(verse)")"#))
        XCTAssertTrue(s.contains("UIPasteboard.general.string = text"))
    }

    func test_source_editorPrefill_onlyAppliesToNewNotes() throws {
        let s = try readSource("FellowScript/Notes/NoteEditorView.swift")
        XCTAssertTrue(s.contains("note?.text ?? initialBodyHTML"))
        XCTAssertTrue(s.contains("if let v = initialVerse { verseList = [v] }"))
    }
}
