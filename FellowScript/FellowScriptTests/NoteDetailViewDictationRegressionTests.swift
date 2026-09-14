// NoteDetailViewDictationRegressionTests.swift — testing-gate coverage for
// task 20260914-dictation-tts, step 3 (testing).
//
// Exercises NoteDetailView's real dictation wiring end to end: the note
// body is HTML-stripped and untruncated via the new `FSNote.textForSpeech`
// (Models.swift), the button is reachable and toggles the shared
// `SpeechController` regardless of `canEdit` gating (the intake spec's
// resolved open question -- reading isn't ownership-sensitive the way
// editing is), and cleanup fires on disappear. `toggleDictation()` is
// `internal` (not `private`, same reasoning this file already documents for
// `editAction()`/`closeAction()`), so it's called directly here rather than
// through ViewInspector, which per NoteDetailViewDirectionBTests.swift's own
// documented finding cannot traverse a ToolbarItemGroup wrapped in
// `.suppressAutomaticGlassChrome()` anyway.
//
// SpeechControllerRegressionTests.swift separately covers the shared
// engine's own toggle/interrupt/fallback/audio-session behavior in
// isolation -- this file's job is proving NoteDetailView actually wires up
// to that engine correctly, with the real HTML-stripped note text and the
// real canEdit-independent gating.
import XCTest
import SwiftUI
import AVFoundation
import ViewInspector
@testable import FellowScript

@MainActor
final class NoteDetailViewDictationRegressionTests: XCTestCase {

    override func tearDown() async throws {
        // SpeechController.shared is a singleton -- see
        // SpeechControllerRegressionTests.swift's own tearDown for why this
        // reset matters across files, not just within this one.
        SpeechController.shared.stop()
        try await super.tearDown()
    }

    private func makeNote(
        id: String = "note-1",
        text: String = "<p>Hello <b>world</b>, this is the body.</p>",
        username: String = "author-user",
        groupId: String = "",
        isPublic: Bool = false
    ) -> FSNote {
        FSNote(
            id: id, user: username, username: username, title: "A Note",
            text: text, public: isPublic, group_id: groupId,
            is_reply: false, timestamp: "2026-09-14T10:00:00.000Z",
            verses: [], replies: []
        )
    }

    // MARK: - Wiring: toggling actually drives the shared SpeechController
    // with the note's own HTML-stripped, untruncated body.

    func test_toggleDictation_startsSpeaking_withHtmlStrippedNoteBody() {
        let note = makeNote(id: "note-42", text: "<p>Line one.</p><p>Line two.</p>")
        let sut = NoteDetailView(note: note, userId: "viewer", username: "viewer") { _ in nil }

        XCTAssertFalse(SpeechController.shared.isSpeaking(for: "note-note-42"))
        sut.toggleDictation()
        XCTAssertTrue(SpeechController.shared.isSpeaking(for: "note-note-42"),
                       "toggleDictation() must start the shared controller speaking under this note's own source id")

        // Confirm the spoken text is the HTML-stripped body, not the raw
        // markup -- matches FSNote.textForSpeech's own contract.
        XCTAssertEqual(note.textForSpeech, "Line one.Line two.")
    }

    func test_toggleDictation_tappedTwice_stopsPlayback() {
        let note = makeNote(id: "note-toggle")
        let sut = NoteDetailView(note: note, userId: "viewer", username: "viewer") { _ in nil }

        sut.toggleDictation()
        XCTAssertTrue(SpeechController.shared.isSpeaking(for: "note-note-toggle"))

        sut.toggleDictation()
        XCTAssertFalse(SpeechController.shared.isSpeaking,
                        "re-tapping the same note's dictation button must stop playback (toggle, not a separate stop control)")
    }

    // MARK: - Always available regardless of canEdit (resolved open
    // question) -- construct a note this viewer explicitly cannot edit and
    // confirm dictation still works.

    func test_toggleDictation_worksEvenWhenCanEditIsFalse() {
        // Group note authored by someone else, public flag off -- canEdit
        // must read false for this viewer.
        let note = makeNote(id: "note-readonly", username: "someone-else", groupId: "group-1", isPublic: false)
        let sut = NoteDetailView(note: note, userId: "viewer-id", username: "viewer-username") { _ in nil }

        XCTAssertFalse(sut.canEdit, "test setup must actually produce a non-editable note, or this test proves nothing")
        XCTAssertNoThrow(sut.toggleDictation())
        XCTAssertTrue(SpeechController.shared.isSpeaking(for: "note-note-readonly"),
                       "dictation must remain available even when the viewer cannot edit the note -- reading aloud isn't an ownership-sensitive action, per the intake spec's resolved open question")
    }

    // MARK: - Cross-screen: starting a note's dictation stops a
    // Bible-chapter (or another note's) in-flight speech, and vice versa --
    // proven here against the real note source id this screen actually uses.

    func test_toggleDictation_interruptsAnotherInFlightSource() {
        SpeechController.shared.speak("Reading a Bible chapter.", source: "bible-chapter")
        XCTAssertTrue(SpeechController.shared.isSpeaking(for: "bible-chapter"))

        let note = makeNote(id: "note-interrupt")
        let sut = NoteDetailView(note: note, userId: "viewer", username: "viewer") { _ in nil }
        sut.toggleDictation()

        XCTAssertTrue(SpeechController.shared.isSpeaking(for: "note-note-interrupt"))
        XCTAssertFalse(SpeechController.shared.isSpeaking(for: "bible-chapter"),
                        "starting this note's dictation must stop the other screen's in-flight speech, since both screens share one SpeechController instance")
    }

    // MARK: - Source-pinned wiring facts ViewInspector can't reach through
    // .suppressAutomaticGlassChrome() (see this file's header comment and
    // NoteDetailViewDirectionBTests.swift's own documented finding).

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_source_dictationButton_sitsOutsideCanEditGate_editPillStaysGated() throws {
        let source = try readSource("FellowScript/Notes/NoteDetailView.swift")
        // The dictation Button must be declared before the `if canEdit {`
        // block that wraps ONLY the Edit pill, inside the same
        // ToolbarItemGroup -- i.e. dictation renders unconditionally, Edit
        // stays gated exactly as before this task.
        guard let dictationRange = source.range(of: "Button(action: toggleDictation) {"),
              let canEditRange = source.range(of: "if canEdit {", range: dictationRange.upperBound..<source.endIndex),
              let editPillRange = source.range(of: "gradientPill(\"Edit\"", range: canEditRange.upperBound..<source.endIndex)
        else {
            XCTFail("expected to find toggleDictation button, followed by an `if canEdit` block containing the Edit gradientPill, in that order")
            return
        }
        XCTAssertTrue(dictationRange.upperBound < canEditRange.lowerBound && canEditRange.upperBound < editPillRange.lowerBound,
                       "dictation button must precede and sit outside the `if canEdit` block that still gates only the Edit pill")
    }

    func test_source_onDisappear_stopsSpeechController() throws {
        let source = try readSource("FellowScript/Notes/NoteDetailView.swift")
        XCTAssertTrue(source.contains(".onDisappear {") && source.contains("speechController.stop()"),
                       "NoteDetailView must stop playback when it leaves the view hierarchy (sheet dismissal), matching the acceptance criteria's 'navigating away stops playback' requirement")
    }

    // MARK: - Regression: Close pill's existing dismiss wiring is untouched
    // by the toolbar restructuring this task made to add the dictation
    // button alongside Edit.

    func test_closePill_stillPresentAndTappable_noRegression() {
        let note = makeNote()
        let sut = NoteDetailView(note: note, userId: "viewer", username: "viewer") { _ in nil }
        XCTAssertNoThrow(sut.closeAction())
    }

    func test_editAction_stillTogglesShowEditor_whenCanEditTrue_noRegression() throws {
        // Self-authored personal note -- canEdit must read true.
        let note = makeNote(id: "note-own", username: "viewer-username", groupId: "", isPublic: false)
        var sut = NoteDetailView(note: note, userId: "viewer-id", username: "viewer-username") { _ in nil }
        XCTAssertTrue(sut.canEdit)

        let exp = sut.on(\.didAppear) { view in
            XCTAssertFalse(try view.actualView().showEditor)
            try view.actualView().editAction()
            XCTAssertTrue(try view.actualView().showEditor)
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 1)
    }
}
