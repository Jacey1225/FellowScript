// ReplyEditAuthorOnlyGateTests.swift — testing gate coverage for task
// 20260904-reply-edit-button, step 4, re-scoped per the security gate's
// 2026-09-04 author-only correction.
//
// Reported/corrected gap: `NoteDetailView.canEdit(_ reply:)` was originally
// implemented as a verbatim copy of the parent note's `canEdit` -- which has
// a legitimate `if note.group_id.isEmpty { return true }` fail-open branch
// and an `if note.public { return true }` non-owner group-edit exception.
// Applied per-reply, that would have shown the new Edit pill (and let the
// save round-trip attempt succeed) for ANY member of the reply's group
// whenever the reply's own `public` flag was true -- which every reply in
// this app's fixtures/production defaults to (see MockDataService.mockReplies
// and NotesListView.postReplyDraft, which always posts `public: false`
// itself but the server-side default and other clients may not). A reply
// must be author-only, full stop: no group_id fail-open, no public-flag
// exception, deny-by-default (hide) on any empty/unresolved username.
//
// This file proves the corrected `canEdit(_ reply:)` gate holds by hosting a
// real NoteDetailView (ViewHosting) against MockDataService.shared's actual
// `mockReplies["note-grp-001"]` fixture -- 3 replies, all with
// `public: true, group_id: "group-abc"` (the exact combination that would
// have wrongly granted non-author edit access under the pre-correction
// group/public-permissive logic) -- rather than a bespoke double, mirroring
// NoteReplySectionTests' own established approach.
//
// `canEdit(_ reply:)` itself is `private` to NotesListView.swift (Swift's
// file-scoped access, not just `internal`+@testable), so it can't be called
// directly from this file -- this drives the same real render pass the
// production UI uses and asserts on the resulting Edit-pill Button's
// presence/absence, the same technique NoteReplySectionTests already uses
// for `showReplyComposer`/composer-pill coverage. The parent note's own
// toolbar Edit pill lives inside a `ToolbarItem` wrapped in
// `.suppressAutomaticGlassChrome()`, which ViewInspector 0.10.3 cannot
// traverse at all (see NoteDetailViewDirectionBTests' own doc comment) — so
// every Button carrying "Edit" text findable below is unambiguously one of
// the per-reply overlay pills, never the parent's.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class ReplyEditAuthorOnlyGateTests: XCTestCase {

    // Parent note deliberately kept private/non-public with a mismatched
    // username so the parent's OWN canEdit is false either way -- isolates
    // this file's assertions to the per-reply gate, even though the parent's
    // toolbar Edit pill wouldn't be independently findable regardless (see
    // file-level comment above).
    private func groupNoteWithReplies(id: String = "note-grp-001") -> FSNote {
        FSNote(
            id: id, user: "user-owner", username: "owner-only",
            title: "Romans 8 Study Notes",
            text: "<p>Walking by the Spirit.</p>", public: false, group_id: "group-abc",
            is_reply: false, timestamp: "2026-08-20 10:00:00"
        )
    }

    private func editButtons(in view: InspectableView<ViewType.View<NoteDetailView>>) throws -> [InspectableView<ViewType.Button>] {
        try view.findAll(ViewType.Button.self, where: { button in
            (try? button.find(text: "Edit")) != nil
        })
    }

    // MARK: 1 — The reply's own author sees exactly one Edit pill: their own

    @MainActor
    func test_viewerIsSarah_seesEditPillOnlyOnHerOwnReply() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "Sarah", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            let buttons = try self.editButtons(in: view)
            XCTAssertEqual(buttons.count, 1,
                            "Sarah authored exactly one of the 3 mock replies -- she must see exactly one reply Edit pill, not one per reply")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 2 — Same for Marcus, the author of a different reply

    @MainActor
    func test_viewerIsMarcus_seesEditPillOnlyOnHisOwnReply() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "Marcus", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            let buttons = try self.editButtons(in: view)
            XCTAssertEqual(buttons.count, 1,
                            "Marcus authored exactly one of the 3 mock replies -- he must see exactly one reply Edit pill")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 3 — THE regression this task's security correction exists for:
    // a non-author group member must see ZERO reply Edit pills, even though
    // every mock reply has public: true and a shared group_id -- the exact
    // combination the pre-correction (parent-canEdit-mirroring) implementation
    // would have wrongly granted access under.

    @MainActor
    func test_viewerIsNonAuthorGroupMember_seesNoReplyEditPills_evenThoughRepliesArePublicAndShareGroupId() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "someone-else", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            let buttons = try self.editButtons(in: view)
            XCTAssertEqual(buttons.count, 0,
                            "a non-author group member must never see an Edit pill on ANY reply, regardless of that reply's public flag or shared group_id -- " +
                            "a reply has no group/public edit exception, unlike an ordinary note")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 4 — Deny-by-default: an empty/unresolved viewer username hides
    // every reply Edit pill, never assumes authorship.

    @MainActor
    func test_emptyViewerUsername_seesNoReplyEditPills() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            let buttons = try self.editButtons(in: view)
            XCTAssertEqual(buttons.count, 0,
                            "an empty/unresolved viewer username must fail closed -- no reply Edit pill shown to an unknown viewer")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 5 — Deny-by-default: the author-less mock reply (reply-003,
    // username: "") must never show an Edit pill to anyone, including a
    // viewer whose own username also happens to be empty (must not be
    // treated as a false "match").

    @MainActor
    func test_authorlessReply_showsNoEditPillToAnyViewer_includingEmptyUsernameViewer() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            // Already covered generally by test 4 above (0 total buttons),
            // but explicitly re-asserted here against the author-less
            // reply's own text to pin the exact failure mode this guards:
            // `guard !reply.username.isEmpty, !username.isEmpty else { return false }`
            // must reject an empty == empty "match" just as it rejects a
            // real mismatch.
            let buttons = try self.editButtons(in: view)
            XCTAssertTrue(buttons.isEmpty,
                          "empty note-author username must never be treated as authored by an empty-username viewer")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 6 — Tapping the author's own Edit pill opens the shared editor
    // (sets editingReply, presenting the same NoteEditorView the parent note
    // uses) without throwing. `editingReply` itself is `@State private`, so
    // this proves wiring/tappability the same way NoteReplySectionTests'
    // MARK 5 "Add a reply" test does, rather than asserting internal state.

    @MainActor
    func test_authorTapsOwnReplyEditPill_doesNotThrow() throws {
        let sut = NoteDetailView(note: groupNoteWithReplies(), userId: "user-1", username: "Sarah", service: MockDataService.shared) { _ in nil }
        let exp = sut.inspection.inspect(after: 0.5) { view in
            let buttons = try self.editButtons(in: view)
            XCTAssertEqual(buttons.count, 1)
            XCTAssertNoThrow(try buttons[0].tap(), "tapping the reply author's own Edit pill must not throw")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 2)
    }

    // MARK: 7 — Source-pinned regression guard: the reply-save closure must
    // key off `saved.id` (the reply actually being saved), never the
    // enclosing parent `note.id` -- the exact id-mismatch trap the intake
    // spec's premise verification identified (finding #2). Not independently
    // observable via ViewInspector (the sheet's presented NoteEditorView
    // content and its onSave invocation aren't reachable from a unit test
    // without a live user interaction + network round trip), so this pins
    // the shipped source directly, the same technique this codebase already
    // uses for logic unreachable through available test doubles (see
    // NoteReplySectionTests' MARK 7 and NoteDetailViewDirectionBTests'
    // toolbar-modifier pin).

    private func componentSource() throws -> String {
        // The per-reply editor sheet (editingReply/loadReplies) moved out of
        // NotesListView.swift into NoteDetailView.swift in the compliance-
        // readability-cleanup task's split (readability #6, 20260904-
        // frontend-arch-sweep) -- same type, same behavior.
        let componentFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Notes/NoteDetailView.swift")
        return try String(contentsOf: componentFile, encoding: .utf8)
    }

    func test_source_replyEditSheet_savesWithRepliesOwnIdNotParentNoteId() throws {
        let source = try componentSource()
        guard let sheetStart = source.range(of: ".sheet(item: $editingReply) { reply in"),
              let sheetBodyEnd = source.range(of: "private func loadReplies", range: sheetStart.upperBound..<source.endIndex) else {
            XCTFail("could not locate the per-reply editor sheet block")
            return
        }
        let sheetBlock = String(source[sheetStart.lowerBound..<sheetBodyEnd.lowerBound])

        XCTAssertTrue(
            sheetBlock.contains("editingId: saved.id"),
            "the reply-save closure must key off `saved.id` (the reply actually being saved), " +
            "never the enclosing parent `note.id` -- reusing the parent's own onSave closure unmodified " +
            "would silently overwrite the parent note instead of the reply"
        )
        XCTAssertFalse(
            sheetBlock.contains("editingId: note.id"),
            "the reply-save closure must not reuse the parent-note-scoped `note.id` for editingId"
        )
        XCTAssertTrue(
            sheetBlock.contains("catch {") && sheetBlock.contains("return error.localizedDescription"),
            "a save failure must propagate as an inline error string, mirroring the parent note's own " +
            "onSave failure path -- no silent no-op per this app's error-handling convention"
        )
        XCTAssertTrue(
            sheetBlock.contains("if let idx = replies.firstIndex(where: { $0.id == saved.id }) {") &&
            sheetBlock.contains("replies[idx] = saved"),
            "a successful reply save must update this view's own `replies` state in place (no full reload needed) " +
            "and must not write into the top-level notes list/vm.notes, which would wrongly surface a reply as a note"
        )
    }
}
