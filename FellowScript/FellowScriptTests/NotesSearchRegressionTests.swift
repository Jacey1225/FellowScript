// NotesSearchRegressionTests.swift — regression coverage for task
// 20260903-notes-keyword-search, step 3 (testing).
//
// Backend step 1 added two segment-scoped keyword-search endpoints
// (GET /notes/{user_id}/search and GET /groups/{user_id}/{group_id}/notes/
// search), and frontend step 2 wired NotesViewModel.searchText /
// searchResults / isSearching to them (debounced, segment-scoped by
// currentGroupId, never filtering the in-memory `notes` dict). This proves
// the view-model side of that contract:
//
//   1. Typing a query surfaces matches by title and/or text.
//   2. Results can include notes NOT already present in `notes` -- i.e.
//      search isn't silently capped to whatever pages happen to already be
//      loaded client-side, the exact "past note" case the feature exists
//      for.
//   3. Search is segment-scoped: Personal uses searchNotes, a selected
//      group uses searchGroupNotes with that group's id, and switching
//      segments while a search is active re-queries the new segment rather
//      than showing stale results from the old one.
//   4. Access-boundary composition: the view model shows only what the
//      scoped endpoint returned for the CURRENT segment -- it never merges
//      in previously-loaded `notes` or a stale prior segment's results,
//      so switching away from a group can't leak that group's search hits.
//   5. Clearing search returns to the normal, unfiltered list with no
//      lingering query/results/loading state.
//   6. No regression to non-search behavior: with search inactive,
//      filteredNotes/pagination-driving state are untouched and no search
//      network call fires.
//   7. Rapid keystrokes coalesce into a single debounced call for the
//      final query, and a stale (superseded) in-flight response is
//      discarded rather than clobbering a newer query's results.
//
// Uses ThrowingTestDataService (defined in AppStateAuthAccountTests.swift,
// same test target), whose searchNotes/searchGroupNotes seams were extended
// for this task to support exact controllable results, call counts/args,
// and an artificial delay for the staleness test, without touching the
// network.

import XCTest
@testable import FellowScript

private func note(_ id: String, title: String = "", text: String = "", groupId: String = "") -> FSNote {
    FSNote(
        id: id, user: "user-1", title: title, text: text,
        public: false, group_id: groupId, is_reply: false,
        timestamp: "2026-09-03 00:00:00", verses: [], replies: []
    )
}

/// ~300ms debounce (NotesViewModel.searchDebounceNanoseconds) + generous
/// margin so these tests aren't flaky under CI load.
private let debounceSettle: UInt64 = 500_000_000

@MainActor
final class NotesSearchRegressionTests: XCTestCase {

    // MARK: 1 — title/text matching surfaces results

    func test_search_surfacesMatchesByTitleAndText() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        vm.configureSearch(userId: "user-1")

        service.searchNotesResult = [
            "n-title": note("n-title", title: "Sunday Service notes", text: "unrelated body"),
            "n-body":  note("n-body", title: "unrelated title", text: "mentions Sunday somewhere"),
        ]

        vm.searchText = "Sunday"
        try await Task.sleep(nanoseconds: debounceSettle)

        XCTAssertEqual(vm.searchResults.count, 2, "both a title match and a text match must surface")
        XCTAssertTrue(vm.searchResults.contains { $0.0 == "n-title" })
        XCTAssertTrue(vm.searchResults.contains { $0.0 == "n-body" })
        XCTAssertFalse(vm.isSearching, "isSearching must settle back to false once the query completes")
        XCTAssertEqual(service.lastSearchNotesQuery, "Sunday")
        XCTAssertEqual(service.lastSearchNotesUserId, "user-1")
    }

    // MARK: 2 — results include notes beyond already-loaded pages

    func test_search_includesNotesNotYetPaginatedIn() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        vm.configureSearch(userId: "user-1")

        // Only one page loaded client-side -- "n1" is the only note vm.notes
        // knows about.
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["n1": note("n1", title: "Recent note")],
            nextCursorCreatedAt: "2026-09-03 00:00:01", nextCursorId: "n1", hasMore: true
        )]
        await vm.load(service: service, userId: "user-1")
        XCTAssertEqual(vm.notes.count, 1)
        XCTAssertNil(vm.notes["n-old"], "the old note must NOT be in the already-loaded page")

        // The backend search endpoint finds an older note that was never
        // paginated in client-side.
        service.searchNotesResult = ["n-old": note("n-old", title: "An old past note", text: "found by keyword")]

        vm.searchText = "past"
        try await Task.sleep(nanoseconds: debounceSettle)

        XCTAssertEqual(vm.searchResults.count, 1)
        XCTAssertEqual(vm.searchResults.first?.0, "n-old",
                        "search must surface a note beyond whatever pages are already loaded in `notes` -- the whole point of hitting a dedicated backend search endpoint instead of filtering the local dict")
    }

    // MARK: 3 — segment scoping: Personal vs. group route to different endpoints

    func test_search_isScopedToCurrentSegment_personalUsesSearchNotes() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        vm.configureSearch(userId: "user-1")
        // currentGroupId defaults to nil (Personal).

        service.searchNotesResult = ["n1": note("n1", title: "match")]
        vm.searchText = "match"
        try await Task.sleep(nanoseconds: debounceSettle)

        XCTAssertEqual(service.searchNotesCallCount, 1, "Personal segment must call searchNotes")
        XCTAssertEqual(service.searchGroupNotesCallCount, 0, "Personal segment must never call searchGroupNotes")
    }

    func test_search_isScopedToCurrentSegment_groupUsesSearchGroupNotesWithGroupId() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        vm.configureSearch(userId: "user-1")

        vm.currentGroupId = "group-abc"
        service.searchGroupNotesResult = ["g1": note("g1", title: "match", groupId: "group-abc")]
        vm.searchText = "match"
        try await Task.sleep(nanoseconds: debounceSettle)

        XCTAssertEqual(service.searchGroupNotesCallCount, 1, "group segment must call searchGroupNotes")
        XCTAssertEqual(service.searchNotesCallCount, 0, "group segment must never call searchNotes")
        XCTAssertEqual(service.lastSearchGroupNotesGroupId, "group-abc",
                        "must query the CURRENTLY selected group, not Personal or another group")
        XCTAssertEqual(vm.searchResults.first?.0, "g1")
    }

    // MARK: 3b + 4 — switching segments mid-search re-queries the new
    // segment and never leaks the old segment's results

    func test_search_switchingSegmentMidSearch_reQueriesAndDoesNotLeakPriorSegmentResults() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        vm.configureSearch(userId: "user-1")

        // Search Personal first.
        service.searchNotesResult = ["p1": note("p1", title: "shared keyword", groupId: "")]
        vm.searchText = "keyword"
        try await Task.sleep(nanoseconds: debounceSettle)
        XCTAssertEqual(vm.searchResults.first?.0, "p1")

        // Now switch to a group -- currentGroupId's didSet must re-run the
        // active search against the NEW segment automatically (no need to
        // retype the query), and the displayed results must become the
        // group's own results, never a mix with Personal's prior hit.
        service.searchGroupNotesResult = ["g1": note("g1", title: "shared keyword", groupId: "group-abc")]
        vm.currentGroupId = "group-abc"
        try await Task.sleep(nanoseconds: debounceSettle)

        XCTAssertEqual(vm.searchResults.count, 1,
                        "switching segments must not accumulate/leak the previous segment's results")
        XCTAssertEqual(vm.searchResults.first?.0, "g1",
                        "after switching to a group, results must reflect ONLY that group's search, not Personal's")
        XCTAssertGreaterThanOrEqual(service.searchGroupNotesCallCount, 1,
                        "switching to a group while search is active must re-query the new segment")
    }

    // MARK: 5 — clearSearch returns to normal list with no lingering state

    func test_clearSearch_returnsToNormalList_withNoLingeringState() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        vm.configureSearch(userId: "user-1")

        service.searchNotesResult = ["n1": note("n1", title: "match")]
        vm.searchText = "match"
        try await Task.sleep(nanoseconds: debounceSettle)
        XCTAssertFalse(vm.searchResults.isEmpty)
        XCTAssertTrue(vm.isSearchActive)

        vm.clearSearch()

        XCTAssertEqual(vm.searchText, "", "query must be cleared")
        XCTAssertTrue(vm.searchResults.isEmpty, "results must be cleared")
        XCTAssertFalse(vm.isSearching, "no lingering loading state")
        XCTAssertFalse(vm.isSearchActive, "search must report inactive once cleared")

        // A further debounce window passing must not repopulate results
        // from some still-in-flight task.
        try await Task.sleep(nanoseconds: debounceSettle)
        XCTAssertTrue(vm.searchResults.isEmpty, "no stale in-flight search result may land after clearSearch")
    }

    // MARK: 6 — no regression when search is inactive

    func test_searchInactive_doesNotAffectFilteredNotesOrFireNetworkCalls() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["n1": note("n1", title: "Existing note")],
            nextCursorCreatedAt: "2026-09-03 00:00:01", nextCursorId: "n1", hasMore: false
        )]
        await vm.load(service: service, userId: "user-1")
        vm.configureSearch(userId: "user-1")

        XCTAssertFalse(vm.isSearchActive, "search must default to inactive")
        XCTAssertEqual(vm.filteredNotes.count, 1, "normal paginated list must be untouched while search is inactive")
        XCTAssertEqual(service.searchNotesCallCount, 0, "no search call may fire while searchText is empty")

        // Whitespace-only query must also count as inactive (per
        // isSearchActive's trimmed-empty check), not silently fire a search.
        vm.searchText = "   "
        try await Task.sleep(nanoseconds: debounceSettle)
        XCTAssertFalse(vm.isSearchActive)
        XCTAssertEqual(service.searchNotesCallCount, 0,
                        "a whitespace-only query must not be treated as an active search")
    }

    // MARK: 7 — debounce coalesces rapid keystrokes; stale response discarded

    func test_search_debounceCoalescesRapidKeystrokes_intoOneCallForFinalQuery() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        vm.configureSearch(userId: "user-1")

        service.searchNotesResult = ["n1": note("n1", title: "abc match")]

        // Simulate fast typing well inside the ~300ms debounce window.
        vm.searchText = "a"
        try await Task.sleep(nanoseconds: 50_000_000)
        vm.searchText = "ab"
        try await Task.sleep(nanoseconds: 50_000_000)
        vm.searchText = "abc"

        try await Task.sleep(nanoseconds: debounceSettle)

        XCTAssertEqual(service.searchNotesCallCount, 1,
                        "rapid keystrokes inside the debounce window must coalesce into exactly one backend call")
        XCTAssertEqual(service.lastSearchNotesQuery, "abc",
                        "the single call must carry the FINAL query, not an intermediate keystroke")
    }

    func test_search_staleInFlightResponse_isDiscardedOnceQueryHasChanged() async throws {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        vm.configureSearch(userId: "user-1")

        // First query's response is artificially slow.
        service.searchNotesDelayNanoseconds = 400_000_000
        service.searchNotesResult = ["n-stale": note("n-stale", title: "first query result")]
        vm.searchText = "first"

        // Before that slow response lands, the user types a new query.
        try await Task.sleep(nanoseconds: 100_000_000)
        service.searchNotesDelayNanoseconds = nil
        service.searchNotesResult = ["n-fresh": note("n-fresh", title: "second query result")]
        vm.searchText = "second"

        // Wait long enough for BOTH the slow first response and the fast
        // second response to have landed.
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(vm.searchResults.count, 1)
        XCTAssertEqual(vm.searchResults.first?.0, "n-fresh",
                        "a slow response for a superseded query must be discarded, not clobber the newer query's results")
    }
}
