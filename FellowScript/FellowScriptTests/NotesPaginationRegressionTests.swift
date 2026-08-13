// NotesPaginationRegressionTests.swift — regression coverage for
// task: 20260812-notes-pagination, step 4 (testing) covering backend step 1
// (limit/offset/order query params) and frontend step 3 (NotesViewModel
// scroll-triggered per-scope paging) against the intake spec's acceptance
// criteria:
//
//  1. First load caps at 15 notes for the current scope.
//  2. Scroll-to-bottom appends the next 15 with a visible loading state
//     (isLoadingMore) and no duplicate in-flight fetches.
//  3. Pagination halts once a scope's last page is reached.
//  4. Sort-order change resets to page 1 and threads the right `order` param.
//  5. Group-chip switch resets paging without leaking the prior scope's notes.
//  6. DashboardView/AccountView's unpaginated fetchNotes(userId:) is unaffected.
//  7. saveNote/deleteNote optimistic updates are untouched by paging.
//
// Exercises NotesViewModel directly (no full app UI) against
// ThrowingTestDataService's fetchNotes/fetchGroupNotes paging overrides
// (AppStateAuthAccountTests.swift, same test target) — mirrors the pattern
// already used by NotesHighlightsRegressionTests / NotesViewModelHighlightRegressionTests.

import Foundation
import XCTest
@testable import FellowScript

@MainActor
final class NotesPaginationRegressionTests: XCTestCase {

    // ── Fixtures ─────────────────────────────────────────────────────────────

    /// Builds `count` notes with strictly increasing, zero-padded lexicographic
    /// timestamps (so String comparison == chronological order, matching how
    /// both the real backend's ORDER BY and the mock slicing below sort).
    /// Higher `startIndex` == later/newer.
    private func makeNotes(count: Int, groupId: String = "", startIndex: Int = 0, userId: String) -> [String: FSNote] {
        var result: [String: FSNote] = [:]
        for i in 0..<count {
            let idx = startIndex + i
            let id = "\(groupId.isEmpty ? "personal" : groupId)-note-\(String(format: "%03d", idx))"
            result[id] = FSNote(
                id: id, user: userId,
                title: "Note \(idx)", text: "Body \(idx)",
                public: idx % 2 == 0, group_id: groupId, is_reply: false,
                timestamp: String(format: "2026-01-01 00:%02d:%02d", idx / 60, idx % 60),
                verses: [], replies: []
            )
        }
        return result
    }

    /// Mirrors the real backend's (and MockDataService's) page-slicing
    /// contract: sort by timestamp per `order`, then take `limit` starting at
    /// `offset`. `nonisolated` because it's invoked from inside
    /// `fetchNotesPageOverride`/`fetchGroupNotesPageOverride` closures stored
    /// on `ThrowingTestDataService` (a plain, non-actor-isolated class) and
    /// called from its `nonisolated async` protocol methods -- it touches no
    /// MainActor-isolated state, so it's safe to call across that boundary.
    private nonisolated func page(from all: [String: FSNote], limit: Int, offset: Int, order: String) -> [String: FSNote] {
        let sorted = all.sorted {
            order == "asc" ? $0.value.timestamp < $1.value.timestamp : $0.value.timestamp > $1.value.timestamp
        }
        guard offset < sorted.count else { return [:] }
        let slice = sorted[offset...].prefix(limit)
        return Dictionary(uniqueKeysWithValues: slice.map { ($0.key, $0.value) })
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // ── 1. First load caps at 15 ────────────────────────────────────────────

    func test_firstLoad_capsAtFifteen_forPersonalScope() async {
        let userId = "user-page-test-1"
        let all = makeNotes(count: 37, userId: userId)
        let service = ThrowingTestDataService()
        service.fetchNotesPageOverride = { [self] limit, offset, order in page(from: all, limit: limit, offset: offset, order: order) }

        let vm = NotesViewModel()
        await vm.load(service: service, userId: userId)

        XCTAssertEqual(vm.notes.count, 15, "first load must cap at the fixed page size (15), not the full 37-note collection")
        XCTAssertTrue(vm.hasMorePages, "37 notes with a page size of 15 must still report more pages after the first")
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(service.fetchNotesPageCallCount, 1)
        XCTAssertEqual(service.fetchNotesPageCallArgs.first?.limit, 15)
        XCTAssertEqual(service.fetchNotesPageCallArgs.first?.offset, 0)
    }

    // ── 2. Scroll-to-bottom appends next page, visible loading state, no dupes ─

    func test_scrollToBottom_appendsNextPage_andDedupesConcurrentInFlightFetches() async {
        let userId = "user-page-test-2"
        let all = makeNotes(count: 37, userId: userId)
        let service = ThrowingTestDataService()
        service.fetchNotesPageOverride = { [self] limit, offset, order in page(from: all, limit: limit, offset: offset, order: order) }

        let vm = NotesViewModel()
        await vm.load(service: service, userId: userId)
        XCTAssertEqual(vm.notes.count, 15)

        // Simulate real network latency so three near-simultaneous scroll
        // events (as would fire from `.onAppear` on the last visible row
        // while the list re-renders) race against a single in-flight fetch.
        service.fetchNotesPageDelayNanoseconds = 150_000_000
        let lastRowId = vm.filteredNotes.last!.0

        async let call1: () = vm.loadNextPageIfNeeded(currentId: lastRowId)
        async let call2: () = vm.loadNextPageIfNeeded(currentId: lastRowId)
        async let call3: () = vm.loadNextPageIfNeeded(currentId: lastRowId)

        // Give the first call a moment to actually set isLoadingMore before
        // asserting the visible-loading-state contract.
        await waitUntil { vm.isLoadingMore }
        XCTAssertTrue(vm.isLoadingMore, "a visible loading indicator must be active while the next page is in flight")

        _ = await (call1, call2, call3)

        XCTAssertEqual(vm.notes.count, 30, "exactly one more page (15) must be appended, not three")
        XCTAssertEqual(service.fetchNotesPageCallCount, 2,
                        "three concurrent near-bottom scroll events while a fetch is pending must only ever produce one additional network call")
        XCTAssertFalse(vm.isLoadingMore, "loading indicator must clear once the fetch completes")
        XCTAssertTrue(vm.hasMorePages, "22 notes remain unfetched (37 - 15), so more pages must still be signaled")
    }

    // ── 3. Pagination halts at the end of a scope ───────────────────────────

    func test_pagination_haltsAtEndOfScope_noFurtherFetchesPastLastPage() async {
        let userId = "user-page-test-3"
        let all = makeNotes(count: 37, userId: userId)
        let service = ThrowingTestDataService()
        service.fetchNotesPageOverride = { [self] limit, offset, order in page(from: all, limit: limit, offset: offset, order: order) }

        let vm = NotesViewModel()
        await vm.load(service: service, userId: userId)                                  // page 1: notes 0..14 (15)
        await vm.loadNextPageIfNeeded(currentId: vm.filteredNotes.last!.0)                // page 2: notes 15..29 (15) -> 30 total
        XCTAssertEqual(vm.notes.count, 30)
        XCTAssertTrue(vm.hasMorePages)

        await vm.loadNextPageIfNeeded(currentId: vm.filteredNotes.last!.0)                // page 3: remaining 7 notes -> 37 total
        XCTAssertEqual(vm.notes.count, 37)
        XCTAssertFalse(vm.hasMorePages, "a short page (7 < pageSize 15) must signal the end of the scope")

        let callCountAtEnd = service.fetchNotesPageCallCount
        // Further "scroll to bottom" events past the end must not fire any
        // more network calls (no infinite/erroring pagination past the end).
        await vm.loadNextPageIfNeeded(currentId: vm.filteredNotes.last!.0)
        await vm.loadNextPageIfNeeded(currentId: vm.filteredNotes.last!.0)

        XCTAssertEqual(service.fetchNotesPageCallCount, callCountAtEnd, "no additional fetch should fire once hasMorePages is false")
        XCTAssertEqual(vm.notes.count, 37)
    }

    // ── 4. Sort-order change resets to page 1 and threads the order param ──

    func test_sortOrderChange_resetsToPageOne_andPassesOrderParam() async {
        let userId = "user-page-test-4"
        let all = makeNotes(count: 37, userId: userId)
        let service = ThrowingTestDataService()
        service.fetchNotesPageOverride = { [self] limit, offset, order in page(from: all, limit: limit, offset: offset, order: order) }

        let vm = NotesViewModel()
        await vm.load(service: service, userId: userId)
        await vm.loadNextPageIfNeeded(currentId: vm.filteredNotes.last!.0)   // page 2 -> offset now at 30
        XCTAssertEqual(vm.notes.count, 30)
        XCTAssertEqual(service.fetchNotesPageCallArgs.last?.order, "desc", "default sort (Newest First) must map to order=desc")

        vm.sortOrder = .oldest
        // Wait on the final observable state (page-1-sized notes dict), not
        // just the call-count tick, so this can't race ahead of the
        // assignment that follows the network call.
        await waitUntil { vm.notes.count == 15 && service.fetchNotesPageCallArgs.last?.order == "asc" }

        XCTAssertEqual(service.fetchNotesPageCallArgs.last?.order, "asc", "Oldest First must map to order=asc")
        XCTAssertEqual(service.fetchNotesPageCallArgs.last?.offset, 0, "changing sort order must restart the cursor at page 1, not resume the old offset")
        XCTAssertEqual(vm.notes.count, 15, "the previously-loaded second page must be discarded on a sort-order reload, not merged with the new order's page 1")

        // With order=asc, page 1 must contain the OLDEST notes (lowest index),
        // i.e. note-000..note-014, proving the sort direction actually took effect.
        XCTAssertNotNil(vm.notes["personal-note-000"])
        XCTAssertNil(vm.notes["personal-note-036"], "the newest note must not be on page 1 of an oldest-first sort")
    }

    // ── 5. Group-chip switch resets paging without leaking the prior scope ─

    func test_groupChipSwitch_resetsPaging_withoutLeakingPriorScopeNotes() async {
        let userId = "user-page-test-5"
        let groupId = "group-xyz"
        let personalNotes = makeNotes(count: 20, userId: userId)
        let groupNotes = makeNotes(count: 12, groupId: groupId, startIndex: 100, userId: userId)

        let service = ThrowingTestDataService()
        service.fetchNotesPageOverride = { [self] limit, offset, order in page(from: personalNotes, limit: limit, offset: offset, order: order) }
        service.fetchGroupNotesPageOverride = { [self] gid, limit, offset, order in
            gid == groupId ? page(from: groupNotes, limit: limit, offset: offset, order: order) : [:]
        }

        let vm = NotesViewModel()
        await vm.load(service: service, userId: userId)
        XCTAssertEqual(vm.notes.count, 15, "personal scope page 1")
        XCTAssertTrue(vm.hasMorePages, "20 personal notes > page size, so more pages remain")

        vm.currentGroupId = groupId
        await waitUntil { vm.notes.count == 12 }

        XCTAssertEqual(vm.notes.count, 12, "the group only has 12 notes total, all should load on page 1 (< page size)")
        XCTAssertFalse(vm.hasMorePages, "12 < page size 15, so the group scope has no more pages")
        for (id, note) in vm.notes {
            XCTAssertEqual(note.group_id, groupId, "no personal-scope note may leak into the group scope's notes dict")
            XCTAssertTrue(id.hasPrefix(groupId), "unexpected leaked note id: \(id)")
        }
        XCTAssertEqual(service.fetchNotesPageCallCount, 1, "switching scope must not re-fetch the old (personal) scope")

        // Switch back to Personal — must reset again to a fresh page 1, not
        // resume the group scope's offset, and must not contain group notes.
        vm.currentGroupId = nil
        await waitUntil { vm.notes.count == 15 && vm.currentGroupId == nil }

        XCTAssertEqual(vm.notes.count, 15)
        for (_, note) in vm.notes {
            XCTAssertEqual(note.group_id, "", "switching back to Personal must not leak the group scope's notes")
        }
    }

    // ── 6. Visibility filter auto-continues paging (force) without a matching row id ─

    func test_loadNextPageIfNeeded_force_fetchesNextPage_evenWithoutMatchingLastRow() async {
        // Mirrors NotesListView's empty-filtered-but-more-pages-may-exist path
        // (`.task(id:) { await vm.loadNextPageIfNeeded(force: true) }`), which
        // must be able to keep paging even when nothing in the currently
        // loaded/filtered set matches `currentId` (there may BE no visible rows).
        let userId = "user-page-test-6"
        let all = makeNotes(count: 37, userId: userId)
        let service = ThrowingTestDataService()
        service.fetchNotesPageOverride = { [self] limit, offset, order in page(from: all, limit: limit, offset: offset, order: order) }

        let vm = NotesViewModel()
        await vm.load(service: service, userId: userId)
        XCTAssertEqual(vm.notes.count, 15)

        // No currentId at all, and it doesn't match any loaded row -- an
        // ordinary (non-forced) call must no-op...
        let callCountBeforeNoForce = service.fetchNotesPageCallCount
        await vm.loadNextPageIfNeeded(currentId: "does-not-exist")
        XCTAssertEqual(service.fetchNotesPageCallCount, callCountBeforeNoForce, "a non-forced call with a non-matching id must not trigger a fetch")

        // ...but `force: true` must still fetch the next page regardless.
        await vm.loadNextPageIfNeeded(force: true)
        XCTAssertEqual(service.fetchNotesPageCallCount, callCountBeforeNoForce + 1)
        XCTAssertEqual(vm.notes.count, 30)
    }

    // ── 7. DashboardView / AccountView's unpaginated fetchNotes is unaffected ─

    func test_unpaginatedFetchNotes_forDashboardAndAccountView_stillReturnsFullSetUnaffectedByPagingOverrides() async throws {
        let userId = "user-page-test-7"
        let service = ThrowingTestDataService()
        // Even with a paging override configured (as NotesListView would
        // configure for its own scroll-triggered fetches), the *unpaginated*
        // overload DashboardView/AccountView call must be completely
        // unaffected -- proving the two call sites don't share behavior.
        service.fetchNotesPageOverride = { _, _, _ in ["should-never-be-seen": FSNote(id: "should-never-be-seen")] }

        let result = try await service.fetchNotes(userId: userId)
        let expected = try await MockDataService.shared.fetchNotes(userId: userId)

        XCTAssertEqual(Set(result.keys), Set(expected.keys), "DashboardView/AccountView's fetchNotes(userId:) must still return the full unpaginated set")
        XCTAssertNil(result["should-never-be-seen"], "the paginated overload's override must not leak into the unpaginated call path")
    }

    // ── 8. saveNote / deleteNote optimistic updates unaffected by paging ───

    func test_saveNote_and_deleteNote_stillUpdateOptimistically_underPagingModel() async {
        let userId = "user-page-test-8"
        let service = ThrowingTestDataService()
        let vm = NotesViewModel()
        vm.service = service

        let note = FSNote(id: "local-temp-id", user: userId, title: "T", text: "Body", public: false, group_id: "", is_reply: false, timestamp: "2026-01-01 00:00:00")
        let ok = await vm.saveNote(note, editingId: nil, userId: userId)

        XCTAssertTrue(ok)
        XCTAssertNotNil(vm.notes["local-temp-id"], "saveNote must optimistically add the note to the in-memory dict")

        await vm.deleteNote(id: "local-temp-id", userId: userId)
        XCTAssertNil(vm.notes["local-temp-id"], "deleteNote must optimistically remove the note from the in-memory dict")
    }
}
