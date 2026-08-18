// NotesPaginationRegressionTests.swift — regression coverage for task
// 20260817-notes-pagination-backend, step 2 (frontend).
//
// The backend replaced the never-shipped client-side "load everything then
// slice" attempt with SQL-level keyset pagination (15/page). This proves
// NotesViewModel's consuming side of that contract:
//
//   1. loadMoreIfNeeded(userId:) fetches the NEXT page using the segment's
//      own last-seen cursor (never an offset counter) and APPENDS it to the
//      existing notes -- no client-side capping/slicing anywhere in this
//      path.
//   2. It no-ops (does not fire a duplicate request) when a fetch for the
//      current segment is already in flight (isLoadingMore guard).
//   3. It stops fetching once a segment's has_more is false -- the true end
//      of that list -- so the client never spins pulling empty pages.
//   4. Personal and group segments track cursors independently, and
//      loadMoreIfNeeded reaches for the right underlying call
//      (fetchNotes vs. fetchGroupNotes) depending on which segment is
//      selected.
//   5. AccountViewModel.noteCount now comes from the dedicated
//      GET /notes/{userId}/count path (fetchNotesCount), not from counting a
//      (now-capped-at-15) fetched notes page -- so it stays correct for a
//      user with more than one page of notes.
//
// Uses ThrowingTestDataService (defined in AppStateAuthAccountTests.swift,
// same test target), whose fetchNotes/fetchGroupNotes/fetchNotesCount seams
// were extended for this task to support queuing exact pages and observing
// call counts/cursors without touching the network.

import XCTest
@testable import FellowScript

private func note(_ id: String, groupId: String = "") -> FSNote {
    FSNote(
        id: id, user: "user-1", title: "Note \(id)", text: "body",
        public: false, group_id: groupId, is_reply: false,
        timestamp: "2026-08-17 00:00:00", verses: [], replies: []
    )
}

@MainActor
final class NotesPaginationRegressionTests: XCTestCase {

    // MARK: 1 + 3 — append next page, then stop once has_more is false

    func test_loadMoreIfNeeded_appendsNextPersonalPage_thenStopsAtTrueEnd() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()

        let page1 = NotesPage(
            notes: ["n1": note("n1"), "n2": note("n2")],
            nextCursorCreatedAt: "2026-08-17 00:00:02", nextCursorId: "n2", hasMore: true
        )
        service.fetchNotesPageQueue = [page1]
        await vm.load(service: service, userId: "user-1")

        XCTAssertEqual(vm.notes.count, 2, "first page's notes must be loaded")
        XCTAssertTrue(vm.hasMoreForCurrentSegment, "hasMore from the first page must carry into pageState")

        let page2 = NotesPage(
            notes: ["n3": note("n3")],
            nextCursorCreatedAt: "2026-08-17 00:00:03", nextCursorId: "n3", hasMore: false
        )
        service.fetchNotesPageQueue = [page2]
        await vm.loadMoreIfNeeded(userId: "user-1")

        XCTAssertEqual(vm.notes.count, 3, "the next page must be APPENDED, not replace the existing notes")
        XCTAssertNotNil(vm.notes["n1"], "page 1's notes must still be present after loading page 2")
        XCTAssertNotNil(vm.notes["n3"], "page 2's note must now be present")
        XCTAssertFalse(vm.hasMoreForCurrentSegment, "has_more:false on page 2 means the true end of the list")

        // The cursor sent for page 2 must be page 1's own last-seen
        // (created_at, id) -- never an offset/position counter.
        XCTAssertEqual(service.fetchNotesCursors.last?.created, "2026-08-17 00:00:02")
        XCTAssertEqual(service.fetchNotesCursors.last?.id, "n2")

        // Once has_more is false, a further call must not fire another
        // network request at all.
        let callCountBefore = service.fetchNotesCallCount
        await vm.loadMoreIfNeeded(userId: "user-1")
        XCTAssertEqual(service.fetchNotesCallCount, callCountBefore,
                        "loadMoreIfNeeded must not fetch again once has_more is false -- the true end of the list")
        XCTAssertEqual(vm.notes.count, 3, "notes must be unchanged by the no-op call")
    }

    // MARK: 2 — duplicate in-flight request guard

    func test_loadMoreIfNeeded_noOps_whenAFetchIsAlreadyInFlight() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["n1": note("n1")],
            nextCursorCreatedAt: "2026-08-17 00:00:01", nextCursorId: "n1", hasMore: true
        )]
        await vm.load(service: service, userId: "user-1")

        let callCountAfterLoad = service.fetchNotesCallCount
        vm.isLoadingMore = true   // simulate a fetch already in flight
        await vm.loadMoreIfNeeded(userId: "user-1")

        XCTAssertEqual(service.fetchNotesCallCount, callCountAfterLoad,
                        "a second loadMoreIfNeeded call must be a no-op (not fire a duplicate request) while isLoadingMore is true")
    }

    // MARK: 4 — group segment uses its own cursor and fetchGroupNotes, independent of Personal

    func test_loadMoreIfNeeded_groupSegment_usesFetchGroupNotes_andItsOwnCursor() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()

        // Personal first page (has_more true) ...
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")],
            nextCursorCreatedAt: "2026-08-17 00:00:01", nextCursorId: "p1", hasMore: true
        )]
        // ... and group "group-abc" first page (the mock's fixture group id),
        // also has_more true with a DIFFERENT cursor than Personal's.
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")],
            nextCursorCreatedAt: "2026-08-17 00:00:09", nextCursorId: "g1", hasMore: true
        )]
        await vm.load(service: service, userId: "user-1")

        // Switch to the group segment and load its next page.
        vm.currentGroupId = "group-abc"
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g2": note("g2", groupId: "group-abc")],
            nextCursorCreatedAt: "2026-08-17 00:00:10", nextCursorId: "g2", hasMore: false
        )]
        let personalCallCountBefore = service.fetchNotesCallCount
        await vm.loadMoreIfNeeded(userId: "user-1")

        XCTAssertEqual(service.fetchNotesCallCount, personalCallCountBefore,
                        "loading more for the group segment must not touch the Personal (fetchNotes) call at all")
        XCTAssertEqual(service.fetchGroupNotesCursors.last?.created, "2026-08-17 00:00:09",
                        "the group segment must use ITS OWN cursor, not Personal's")
        XCTAssertEqual(service.fetchGroupNotesCursors.last?.id, "g1")
        XCTAssertNotNil(vm.notes["g1"])
        XCTAssertNotNil(vm.notes["g2"], "the group segment's next page must be appended")
        XCTAssertNotNil(vm.notes["p1"], "Personal's already-loaded notes must be unaffected by paging the group segment")
        XCTAssertFalse(vm.hasMoreForCurrentSegment, "group segment's has_more must now read false")

        // Switching back to Personal must still show ITS OWN hasMore/cursor
        // state, unaffected by the group segment's pagination above.
        vm.currentGroupId = nil
        XCTAssertTrue(vm.hasMoreForCurrentSegment, "Personal segment's has_more must be untouched by paging the group segment")
    }
}

// MARK: - AccountViewModel.noteCount via the dedicated count endpoint

@MainActor
final class AccountViewModelNoteCountRegressionTests: XCTestCase {

    /// Before this task, AccountView computed noteCount by fetching notes
    /// and counting the array -- now that GET /notes/{userId} is capped at
    /// 15/page, that would silently truncate the displayed total for any
    /// user with more than one page. Proves noteCount instead reflects the
    /// dedicated COUNT(*) endpoint's answer, even when it's far larger than
    /// one page.
    func test_noteCount_reflectsDedicatedCountEndpoint_beyondOnePage() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        service.fetchNotesCountResult = 42   // far beyond a single 15-note page

        let user = FSUser(user_id: "user-1", username: "alice", email: "a@example.com")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.noteCount, 42,
                        "noteCount must equal the dedicated count endpoint's total, not a page-capped fetched-notes count")
    }
}
