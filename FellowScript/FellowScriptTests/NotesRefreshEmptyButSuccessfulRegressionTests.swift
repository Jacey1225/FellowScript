// NotesRefreshEmptyButSuccessfulRegressionTests.swift — testing-gate
// coverage for task 20260909-notes-account-refresh-data-loss, step 6,
// proving the frontend gate's step 3 fix to NotesViewModel.fetchAndCache.
//
// This is deliberately NOT a re-run of NotesGroupRefreshNullDataRegressionTests
// (which covers a fetch that THROWS -- either a genuine network error or the
// already-fixed fabricated-empty-page-on-decode-failure case from task
// 20260905-notes-group-refresh-clobber-rootcause). The live symptom this
// task's spec targets is different and was explicitly left as an open,
// unresolved question by that prior task: a fetch that does NOT throw at
// all -- a genuinely-well-formed 200 response whose `notes` dict just
// happens to be empty -- for a segment (Personal, or a specific group like
// the spec's real "Godly Goobers") that already has real notes on screen.
//
// Before this task's fix, NotesViewModel.fetchAndCache's splice logic
// treated ANY non-throwing NotesPage as authoritative: `page.notes.isEmpty`
// unconditionally meant "this segment is now empty", spliced that emptiness
// in, and wiped the previously-good notes. That is the literal live
// symptom in the spec's own screenshot ("No notes in Godly Goobers" showing
// over a group that has real cached data).
//
// The fix (Q26/Q27 preference profile -- explicit checks, not "didn't
// throw" as the sole trust signal): an empty page for a segment that
// PREVIOUSLY had real notes is now treated as inconclusive, not
// authoritative -- the existing notes/pageState for that segment are left
// untouched and the situation is surfaced via `refreshError` instead of
// silently trusted. A segment that was already empty (nothing to protect)
// still converges normally on an empty result, and a segment that
// genuinely has fresh non-empty data still fully replaces the old set --
// this suite proves the fix doesn't overcorrect into permanently-stuck
// stale data either.
//
// Uses the shared ThrowingTestDataService double (AppStateAuthAccountTests.swift)
// and its pre-existing fetchNotesPageQueue/fetchGroupNotesPageQueue seams --
// no new test-double surface was needed since "push an empty NotesPage as a
// PROVEN SUCCESS (not an error)" was already expressible with the existing
// queue-of-pages seam.

import XCTest
@testable import FellowScript

private func note(_ id: String, groupId: String = "") -> FSNote {
    FSNote(
        id: id, user: "user-1", title: "Note \(id)", text: "body",
        public: false, group_id: groupId, is_reply: false,
        timestamp: "2026-09-09 00:00:00", verses: [], replies: []
    )
}

@MainActor
final class NotesRefreshEmptyButSuccessfulRegressionTests: XCTestCase {

    private func freshUserId() -> String { "notes-empty-200-\(UUID().uuidString)" }

    // MARK: 1 — the actual reported live symptom: a previously-populated GROUP
    // (mirrors the spec's real "Godly Goobers") whose refresh returns a
    // genuinely-successful, genuinely-empty page must not go empty on screen.

    func test_refresh_groupReturnsEmptyButSuccessfulPage_previouslyPopulatedGroup_isNotWipedToEmpty() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        // Round 1: "Godly Goobers"-equivalent group starts with real notes,
        // matching the spec's screenshot (a populated group, not an
        // already-empty one).
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: [
                "g1": note("g1", groupId: "group-abc"),
                "g2": note("g2", groupId: "group-abc"),
            ],
            nextCursorCreatedAt: "gc1", nextCursorId: "g2", hasMore: true
        )]
        await vm.load(service: service, userId: userId)

        vm.currentGroupId = "group-abc"
        XCTAssertEqual(vm.filteredNotes.count, 2, "sanity check: the group starts with both real notes visible")
        XCTAssertTrue(vm.hasMoreForCurrentSegment, "sanity check: pageState reflects hasMore: true from round 1")

        // Round 2 (pull-to-refresh): the group's fetch does NOT throw --
        // it's a genuinely well-formed 200 response, just with an empty
        // `notes` dict. This is the exact live scenario the intake spec
        // flagged as never confirmed or ruled out by the prior task.
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: [:], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false
        )]
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p2": note("p2")], nextCursorCreatedAt: "c2", nextCursorId: "p2", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)

        XCTAssertEqual(vm.filteredNotes.count, 2,
                        "THE FIX: an empty-but-successful (non-throwing) refresh for a previously-populated group must NOT clobber its visible notes to empty")
        XCTAssertNotNil(vm.notes["g1"]); XCTAssertNotNil(vm.notes["g2"])
        XCTAssertTrue(vm.hasMoreForCurrentSegment,
                      "the group's pageState (hasMore: true from round 1) must be left as-is when this round's result is treated as inconclusive, not authoritative")
        XCTAssertNotNil(vm.notes["p2"], "Personal's own genuinely fresh data must still converge normally, proving this fix is scoped to the ambiguous-empty case only")
        XCTAssertEqual(vm.refreshError, "Wednesday Night Study: refresh returned no notes for a previously-populated group -- kept existing notes",
                        "the ambiguous result must be surfaced (Q26/Q27) instead of silently trusted or silently discarded")
        XCTAssertFalse(vm.isLoading, "refresh() must still complete (not hang) on an empty-but-successful result")
    }

    // MARK: 2 — same distinction for the Personal segment

    func test_refresh_personalReturnsEmptyButSuccessfulPage_previouslyPopulatedPersonal_isNotWipedToEmpty() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1"), "p2": note("p2")], nextCursorCreatedAt: "c1", nextCursorId: "p2", hasMore: true
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")], nextCursorCreatedAt: "gc1", nextCursorId: "g1", hasMore: false
        )]
        await vm.load(service: service, userId: userId)

        XCTAssertEqual(vm.notes.filter { $0.value.group_id.isEmpty }.count, 2, "sanity check: Personal starts with two real notes")
        XCTAssertTrue(vm.hasMoreForCurrentSegment, "sanity check: Personal's pageState reflects hasMore: true from round 1")

        // Round 2: Personal's fetch succeeds (no throw) with an empty page,
        // while the group's fetch succeeds with genuinely fresh data --
        // proving the fix doesn't make ALL segments sticky, only the
        // ambiguous-empty one.
        service.fetchNotesPageQueue = [NotesPage(
            notes: [:], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g2": note("g2", groupId: "group-abc")], nextCursorCreatedAt: "gc2", nextCursorId: "g2", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)

        XCTAssertEqual(vm.notes.filter { $0.value.group_id.isEmpty }.count, 2,
                        "an empty-but-successful refresh for a previously-populated Personal segment must not clobber it to empty")
        XCTAssertNotNil(vm.notes["p1"]); XCTAssertNotNil(vm.notes["p2"])
        XCTAssertTrue(vm.hasMoreForCurrentSegment, "Personal's pageState (hasMore: true from round 1) must be left as-is")
        XCTAssertNil(vm.notes["g1"], "the group's own genuinely fresh (converging) result must still fully replace its stale note")
        XCTAssertNotNil(vm.notes["g2"])
        XCTAssertEqual(vm.refreshError, "Personal: refresh returned no notes for a previously-populated segment -- kept existing notes")
    }

    // MARK: 3 — no overcorrection: a segment that was ALREADY empty must still
    // converge normally on an empty result (nothing to protect, no false
    // refreshError).

    func test_refresh_groupReturnsEmptyPage_groupWasAlreadyEmpty_convergesNormally_noSpuriousError() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        // Round 1: the group starts with ZERO notes (a real, legitimately
        // empty group -- not the bug case).
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: [:], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false
        )]
        await vm.load(service: service, userId: userId)
        vm.currentGroupId = "group-abc"
        XCTAssertEqual(vm.filteredNotes.count, 0, "sanity check: this group is legitimately empty from round 1")

        // Round 2: still empty, still a proven success (no throw).
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: [:], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false
        )]
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)

        XCTAssertEqual(vm.filteredNotes.count, 0, "a legitimately-empty group refreshing to empty again must remain empty, not error")
        XCTAssertNil(vm.refreshError, "there is nothing ambiguous about an already-empty segment staying empty -- no refreshError should be raised")
    }

    // MARK: 4 — no permanent stickiness: after an ambiguous empty-but-successful
    // round is kept-in-place, a LATER round with genuinely fresh non-empty
    // data must still fully converge (proves the fix isn't a one-way trap).

    func test_refresh_afterAnAmbiguousEmptyRound_aSubsequentGenuineNonEmptyRefresh_stillConverges() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")], nextCursorCreatedAt: "gc1", nextCursorId: "g1", hasMore: false
        )]
        await vm.load(service: service, userId: userId)
        vm.currentGroupId = "group-abc"

        // Round 2: ambiguous empty-but-successful result -- kept in place.
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: [:], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false
        )]
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)
        XCTAssertNotNil(vm.notes["g1"], "sanity check: round 2's ambiguous empty result left the old note in place")

        // Round 3: a genuinely DIFFERENT non-empty page -- must fully
        // replace the old note, proving the ambiguous-empty guard doesn't
        // make this group permanently stuck on stale data forever.
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g2": note("g2", groupId: "group-abc")], nextCursorCreatedAt: "gc2", nextCursorId: "g2", hasMore: false
        )]
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)

        XCTAssertNil(vm.notes["g1"], "a later genuinely fresh, non-empty result must fully replace the old note -- this fix must not be a permanent trap")
        XCTAssertNotNil(vm.notes["g2"])
        XCTAssertNil(vm.refreshError, "a fully successful, non-ambiguous round must clear any prior refreshError")
    }
}
