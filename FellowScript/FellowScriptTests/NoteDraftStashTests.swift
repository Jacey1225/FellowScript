// NoteDraftStashTests.swift — task 20261115-ipad-askai-notegate (item 2, testing gate).

import XCTest
@testable import FellowScript

final class NoteDraftStashTests: XCTestCase {

    private let content = NoteDraftContent(
        title: "  Exact Title ", bodyHTML: "<p>Hello <b>world</b></p>",
        verses: [NoteDraftVerse(book: "John", chapter: 3, verse: 16), NoteDraftVerse(book: "Rom", chapter: 8, verse: 1)],
        isPublic: true)

    private func stash(user: String = "u1") -> NoteDraftStash {
        NoteDraftStash(userId: user, content: content, editingNote: nil, editingId: "n1",
                       editingGroupId: "g1", inlineDraft: nil, inlineIsReply: true)
    }

    func test_restorable_sameUser_returnsStash() {
        let r = NoteDraftStash.restorable(stash(), userId: "u1")
        XCTAssertEqual(r?.content, content)
        XCTAssertEqual(r?.editingId, "n1")
    }

    func test_restorable_differentEmptyNilUser_returnsNil() {
        XCTAssertNil(NoteDraftStash.restorable(stash(), userId: "u2"))
        XCTAssertNil(NoteDraftStash.restorable(stash(), userId: ""))
        XCTAssertNil(NoteDraftStash.restorable(stash(), userId: nil))
        XCTAssertNil(NoteDraftStash.restorable(stash(user: ""), userId: ""))
    }

    func test_restorable_nilStash_returnsNil() {
        XCTAssertNil(NoteDraftStash.restorable(nil, userId: "u1"))
    }

    func test_updated_cleanContent_returnsNil_clearingStash() {
        XCTAssertNil(NoteDraftStash.updated(userId: "u1", content: nil, editingNote: nil, editingId: nil,
                                            editingGroupId: "", inlineDraft: nil, inlineIsReply: false))
    }

    func test_updated_missingUser_returnsNil() {
        for uid in [nil, ""] as [String?] {
            XCTAssertNil(NoteDraftStash.updated(userId: uid, content: content, editingNote: nil, editingId: nil,
                                                editingGroupId: "", inlineDraft: nil, inlineIsReply: false))
        }
    }

    func test_updated_dirtyContent_roundTripsEveryField() throws {
        let note = FSNote()
        let vd = VerseNoteDraft(book: "John", chapter: 3, verse: 16, text: "For God so loved")
        let s = try XCTUnwrap(NoteDraftStash.updated(userId: "u1", content: content, editingNote: note,
                                                     editingId: "n9", editingGroupId: "g9",
                                                     inlineDraft: vd, inlineIsReply: true))
        XCTAssertEqual(s.userId, "u1")
        XCTAssertEqual(s.content.title, "  Exact Title ")
        XCTAssertEqual(s.content.bodyHTML, "<p>Hello <b>world</b></p>")
        XCTAssertEqual(s.content.verses, content.verses)
        XCTAssertTrue(s.content.isPublic)
        XCTAssertEqual(s.editingNote?.id, note.id)
        XCTAssertEqual(s.editingId, "n9")
        XCTAssertEqual(s.editingGroupId, "g9")
        XCTAssertEqual(s.inlineDraft?.id, vd.id)
        XCTAssertTrue(s.inlineIsReply)
        // restore path returns the same thing for the same user only
        XCTAssertNotNil(NoteDraftStash.restorable(s, userId: "u1"))
        XCTAssertNil(NoteDraftStash.restorable(s, userId: "other"))
    }

    /// Structural guard: the stash is cleared on every discard/save path.
    func test_stashClearedOnDiscardAndSavePaths_source() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "FellowScriptTests" { url.deleteLastPathComponent() }
        url.deleteLastPathComponent()
        let ws = try String(contentsOf: url.appendingPathComponent("FellowScript/Workspace/WorkspaceView.swift"), encoding: .utf8)
        let nl = try String(contentsOf: url.appendingPathComponent("FellowScript/Notes/NotesListView.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("appState.noteDraftStash = nil"), "workspace Discard must clear the stash")
        XCTAssertTrue(nl.contains("restoredDraft = nil; appState.noteDraftStash = nil"), "editor close (save/discard) must clear the stash")
        XCTAssertTrue(nl.contains("NoteDraftStash.updated("), "editor changes must mirror into the stash")
    }
}
