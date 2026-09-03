// NotesAuthorOnlyEditGateTests.swift — testing gate coverage for task
// 20260829-notes-edit-author-gate.
//
// Reported bug: on iOS, a group member could see Edit (and Delete) on
// another member's group note in NotesListView, even though the backend
// (api/routes/notes.py) always correctly rejected the write with 403. The
// frontend gate added:
//
//   1. `NotesListView.canModify` (delegating to the new pure
//      `NotesListView.isAuthor(of:currentUsername:)`), gating the
//      swipeActions Delete and contextMenu Edit/Delete for a note row.
//   2. `NoteDetailView.canEdit`, gating the toolbar Edit pill.
//   3. `NotesViewModel.deleteNote`'s new `isOwnNote` guard, so a non-author
//      delete attempt (should the UI gate ever be bypassed) no longer
//      optimistically vanishes the note from the local list before the
//      backend's real 403 lands.
//
// All three share the same authorship rule: a personal note (empty
// group_id) is always self-authored and always modifiable; a group note is
// only modifiable by the current user when `note.username` — non-empty —
// matches the viewer's own (non-empty) username. This file proves that rule
// holds for both gates, in both directions (author sees the affordance,
// non-author does not), plus the deny-by-default fallback for missing
// username data, and separately proves the ViewModel-level delete guard.
//
// `isAuthor`/`canEdit` are exercised directly rather than through
// ViewInspector's rendered-tree inspection: ViewInspector 0.10.3 (this
// project's checked-in version) has no support for inspecting
// `.swipeActions`/`.contextMenu` conditionals, and `canModify` itself needs
// a live-rendered EnvironmentObject<AppState> to resolve at all -- see
// `isAuthor`'s own doc comment in NotesListView.swift for why the frontend
// gate's testability-seam pattern (already used for
// closeAction/editAction) was extended here as a pure static function
// instead.

import XCTest
@testable import FellowScript

// MARK: - NotesListView.isAuthor (swipeActions Delete / contextMenu Edit+Delete gate)

final class NotesListViewAuthorGateTests: XCTestCase {

    private func groupNote(username: String) -> FSNote {
        FSNote(
            id: "note-1", user: "user-alice", username: username, title: "Group note",
            text: "body", public: true, group_id: "group-abc",
            timestamp: "2026-08-20 10:00:00"
        )
    }

    private func personalNote(username: String = "") -> FSNote {
        FSNote(
            id: "note-2", user: "user-1", username: username, title: "Personal note",
            text: "body", public: false, group_id: "",
            timestamp: "2026-08-20 09:00:00"
        )
    }

    // MARK: Personal notes: always modifiable, regardless of username data

    func test_personalNote_isAlwaysModifiable_evenWithNoCurrentUser() {
        XCTAssertTrue(NotesListView.isAuthor(of: personalNote(), currentUsername: nil),
                      "a personal note (no group_id) is always self-authored, no username check needed")
    }

    func test_personalNote_isAlwaysModifiable_evenIfSomeUsernameWereStamped() {
        // Defensive, mirrors NoteRowAuthorIndicatorTests' analogous Personal
        // guard: even if a future call site stamped a mismatched username
        // onto a Personal note, it must still be modifiable.
        XCTAssertTrue(NotesListView.isAuthor(of: personalNote(username: "someone-else"), currentUsername: "me"))
    }

    // MARK: Group notes: the reported bug -- author sees the affordance, non-author doesn't

    func test_groupNote_authoredByCurrentUser_isModifiable() {
        XCTAssertTrue(NotesListView.isAuthor(of: groupNote(username: "alice"), currentUsername: "alice"),
                      "the note's own author must still be able to modify their own group note")
    }

    func test_groupNote_authoredByAnotherMember_isNotModifiable() {
        // This is the exact reported gap: a group member other than the
        // author must never see Edit/Delete on a note that isn't theirs.
        XCTAssertFalse(NotesListView.isAuthor(of: groupNote(username: "alice"), currentUsername: "bob"),
                       "a non-author must not be able to modify another member's group note")
    }

    // MARK: Deny-by-default: missing username data hides the affordance, never assumes authorship

    func test_groupNote_withEmptyNoteUsername_isNotModifiable() {
        XCTAssertFalse(NotesListView.isAuthor(of: groupNote(username: ""), currentUsername: "alice"),
                       "an undecoded/uncaptured note author must fail closed, not be assumed to be the viewer")
    }

    func test_groupNote_withNilCurrentUsername_isNotModifiable() {
        XCTAssertFalse(NotesListView.isAuthor(of: groupNote(username: "alice"), currentUsername: nil),
                       "no signed-in/known viewer identity must fail closed")
    }

    func test_groupNote_withEmptyCurrentUsername_isNotModifiable() {
        XCTAssertFalse(NotesListView.isAuthor(of: groupNote(username: "alice"), currentUsername: ""),
                       "an empty (not just nil) viewer username must also fail closed")
    }
}

// MARK: - NoteDetailView.canEdit (toolbar Edit pill gate)
//
// Extended by task 20260903-notes-public-repurpose, step 5:
// `note.public` is checked BEFORE the deny-by-default username-matching
// fallback (see NoteDetailView.canEdit's own doc comment) -- a group note
// with public == true is editable by ANY viewer (mirroring the server's new
// update_note non-owner branch), regardless of username data; public ==
// false falls through to the original author-only comparison, preserving
// every deny-by-default guarantee task 20260829-notes-edit-author-gate
// established.

final class NoteDetailViewCanEditGateTests: XCTestCase {

    private func groupNote(username: String, public isPublic: Bool = true) -> FSNote {
        FSNote(
            id: "note-1", user: "user-alice", username: username, title: "Group note",
            text: "body", public: isPublic, group_id: "group-abc",
            timestamp: "2026-08-20 10:00:00"
        )
    }

    private func personalNote() -> FSNote {
        FSNote(
            id: "note-2", user: "user-1", title: "Personal note",
            text: "body", public: false, group_id: "",
            timestamp: "2026-08-20 09:00:00"
        )
    }

    @MainActor
    func test_personalNote_canEditIsAlwaysTrue() {
        let sut = NoteDetailView(note: personalNote(), username: "") { _ in nil }
        XCTAssertTrue(sut.canEdit, "a personal note must always be editable, regardless of the viewer's username")
    }

    @MainActor
    func test_groupNote_viewerIsAuthor_canEditIsTrue() {
        let sut = NoteDetailView(note: groupNote(username: "alice", public: false), username: "alice") { _ in nil }
        XCTAssertTrue(sut.canEdit, "the note's own author must still see the Edit pill even when public is false")
    }

    // MARK: public == true -- the new non-owner group-edit capability

    @MainActor
    func test_groupNote_public_viewerIsNotAuthor_canEditIsTrue() {
        // The new capability this task adds: a non-owner group member sees
        // the Edit pill when the note's owner opted it into public == true,
        // mirroring the server's new update_note non-owner branch.
        let sut = NoteDetailView(note: groupNote(username: "alice", public: true), username: "bob") { _ in nil }
        XCTAssertTrue(sut.canEdit, "a non-author must see the Edit pill on a public == true group note")
    }

    @MainActor
    func test_groupNote_public_withEmptyNoteUsername_canEditIsTrue() {
        // note.public is checked before the username-matching fallback, so
        // an undecoded/uncaptured note author no longer blocks the pill when
        // the note itself is public == true.
        let sut = NoteDetailView(note: groupNote(username: "", public: true), username: "alice") { _ in nil }
        XCTAssertTrue(sut.canEdit, "public == true grants Edit regardless of missing note-author username data")
    }

    @MainActor
    func test_groupNote_public_withEmptyViewerUsername_canEditIsTrue() {
        let sut = NoteDetailView(note: groupNote(username: "alice", public: true), username: "") { _ in nil }
        XCTAssertTrue(sut.canEdit, "public == true grants Edit even for an unresolved viewer identity")
    }

    // MARK: public == false -- original deny-by-default author-only gate, unchanged

    @MainActor
    func test_groupNote_notPublic_viewerIsNotAuthor_canEditIsFalse() {
        // The original reported gap for NoteDetailView's toolbar Edit pill,
        // still guarded when the note is NOT opted into group-editing:
        // opening another member's note must show no Edit affordance.
        let sut = NoteDetailView(note: groupNote(username: "alice", public: false), username: "bob") { _ in nil }
        XCTAssertFalse(sut.canEdit, "a non-author must not see the Edit pill on a non-public group note")
    }

    @MainActor
    func test_groupNote_notPublic_withEmptyNoteUsername_canEditIsFalse() {
        let sut = NoteDetailView(note: groupNote(username: "", public: false), username: "alice") { _ in nil }
        XCTAssertFalse(sut.canEdit, "an undecoded/uncaptured note author must still fail closed when not public")
    }

    @MainActor
    func test_groupNote_notPublic_withEmptyViewerUsername_canEditIsFalse() {
        let sut = NoteDetailView(note: groupNote(username: "alice", public: false), username: "") { _ in nil }
        XCTAssertFalse(sut.canEdit, "an unresolved viewer identity must still fail closed when not public")
    }
}

// MARK: - NotesViewModel.deleteNote (isOwnNote guard, no optimistic removal for a rejected delete)

@MainActor
final class NotesViewModelDeleteNoteAuthorGuardTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 204
        StubURLProtocol.stubBody = Data()
    }

    private func makeNote(id: String) -> FSNote {
        FSNote(id: id, user: "user-alice", username: "alice", title: "Group note",
               text: "body", public: true, group_id: "group-abc", timestamp: "2026-08-20 10:00:00")
    }

    // isOwnNote: false — the UI gate hides this action for a non-author, but
    // this proves the ViewModel itself no-ops too (defense in depth): no
    // local removal, and no DELETE request sent to the backend.
    func test_deleteNote_notOwnNote_doesNotRemoveLocallyAndDoesNotCallBackend() async {
        let vm = NotesViewModel()
        vm.service = NetworkService.shared
        let note = makeNote(id: "note-1")
        vm.notes = [note.id: note]

        await vm.deleteNote(id: note.id, userId: "user-bob", isOwnNote: false)

        XCTAssertNotNil(vm.notes[note.id],
                         "a delete attempt on a note the caller doesn't own must not vanish it from the local list")
        XCTAssertTrue(StubURLProtocol.requestLog.filter { $0.method == "DELETE" }.isEmpty,
                      "a non-author delete attempt must never reach the backend at all")
    }

    // isOwnNote: true — the normal, already-gated-by-the-UI path: local
    // removal proceeds and the backend DELETE is actually sent.
    func test_deleteNote_ownNote_removesLocallyAndCallsBackend() async {
        let vm = NotesViewModel()
        vm.service = NetworkService.shared
        let note = makeNote(id: "note-2")
        vm.notes = [note.id: note]

        await vm.deleteNote(id: note.id, userId: "user-alice", isOwnNote: true)

        XCTAssertNil(vm.notes[note.id], "the caller's own note must still be removed from the local list on delete")
        let deleteRequests = StubURLProtocol.requestLog.filter { $0.method == "DELETE" }
        XCTAssertEqual(deleteRequests.count, 1, "the caller's own delete must still reach the backend exactly once")
        XCTAssertTrue(deleteRequests.first?.path.contains("user-alice") ?? false,
                      "the DELETE request must be scoped to the caller's own user id")
    }
}
