// NotesGroupRefreshNullDataRegressionTests.swift — regression coverage for
// task 20260904-notes-group-refresh-null-data, testing NotesViewModel's own
// frontend-gate fix (Lightweight spec: no separate testing gate follows, so
// this coverage is authored alongside the fix, mirroring
// DashboardStaleReloadRegressionTests' failure-hardening tests for
// DashboardViewModel.load()).
//
// Root cause: NotesViewModel.fetchAndCache built a fresh, EMPTY accumulator
// (`allNotes`/`newPageState`) every call. A failed personal-notes fetch or an
// individual failed group's `fetchGroupNotes` call collapses to nil via
// `try?`, and the per-group loop's `guard let page else { continue }` simply
// skipped merging that segment -- but the accumulator started from `[:]`, not
// from the existing good `notes`/`pageState`, so the subsequent unconditional
// `notes = allNotes` / `pageState = newPageState` replaced the full,
// previously-good set with a partial or empty one. This exactly matches
// "group notes null out on refresh": a transient failure fetching one or
// more groups (or Personal) silently wiped those groups' (or all) notes from
// the screen instead of leaving the last-known-good data in place.
//
// Fixed the same way DashboardViewModel.load() was fixed
// (20260901-dashboard-stale-reload-ui): only ever splice a segment's fresh
// result into `notes`/`pageState` on that segment's own proven (non-nil)
// success; a segment whose fetch fails this round keeps whatever was already
// there, and `pageState`'s cursor/hasMore for that segment is left alone too
// (so `loadMoreIfNeeded` doesn't misbehave after a partial refresh failure).
//
// Uses the shared ThrowingTestDataService double (AppStateAuthAccountTests.swift),
// extended in this pass with a `fetchGroupNotesErrorsByGroup` seam (keyed by
// groupId, mirroring the existing `fetchHeartbeatsErrorsByAgent` per-id
// pattern) so a specific group's fetchGroupNotes call can be made to fail
// while Personal's (or another group's) fetch succeeds in the same round.
// fetchContacts (unforced) forwards to MockDataService's real fixture, which
// always returns exactly one group, "group-abc" ("Wednesday Night Study") --
// the same fixed group id NotesPaginationRegressionTests already relies on.
//
// Test-double gap fix (task 20260905-notes-group-refresh-clobber-rootcause,
// testing step): test 3 below (`..._stillConvergesToFreshGroupData`) used to
// leave `service.fetchNotesPageQueue` un-repopulated across rounds 2 and 3 --
// ThrowingTestDataService.fetchNotes only forwards to
// MockDataService.shared.fetchNotes (a fixed, non-empty fixture set, keyed
// by ids that are NOT "p1") once its queue runs dry, and per the file's own
// header comment above, that fallback existing at all is intentional (so
// every OTHER suite sharing this double is unaffected by a queue some other
// test drained). This suite, though, explicitly wants Personal held at "p1"
// unchanged across every round while only the group segment's fetch outcome
// varies -- so leaving the queue empty let a *personal* segment
// double-authoring gap (an unintended, undocumented reliance on that
// fallback) flip `vm.notes["p1"]` to nil via a real, successful, non-"p1"
// personal fetch, which is a wholly different mechanism from the group-
// clobber bug this suite exists to catch. Every round now explicitly
// re-queues a "p1" personal page so the suite's group-segment assertions
// aren't riding on an implicit, unrelated fallback behavior.
//
// Root cause of the actual user-facing "group notes wiped to empty on
// refresh" symptom (traced by this task, fixed in NetworkService+Notes.swift
// and NotesViewModel.swift): NetworkService.fetchNotes/fetchGroupNotes used
// to fabricate a successful, non-throwing, EMPTY NotesPage on a decode
// failure instead of throwing -- indistinguishable, at the ViewModel's
// merge/splice layer, from a genuinely-empty backend page. Group notes were
// far more exposed than personal because fetchGroupNotes' manual per-
// username/per-note JSONSerialization parsing has many more silent-failure
// branches than fetchNotes' single strongly-typed JSONDecoder path. Fixed by
// making those decode-failure branches throw a real, distinct error instead
// of returning a fabricated empty page -- see
// `test_refresh_groupFetchThrowsDecodeFailureError_previouslyNonEmptyGroupSegment_isNotWipedToEmpty`
// below (ViewModel-level, using the exact error type/message the production
// fix now throws) and NetworkServiceGetErrorHandlingTests.swift's
// `test_fetchGroupNotes_throws_onMalformedResponseShape_insteadOfReturningEmptyPage`
// / `test_fetchNotes_throws_onUndecodableBody_insteadOfReturningEmptyPage`
// (network-level, proving the actual production code path throws rather
// than fabricating success).

import XCTest
@testable import FellowScript

private func note(_ id: String, groupId: String = "") -> FSNote {
    FSNote(
        id: id, user: "user-1", title: "Note \(id)", text: "body",
        public: false, group_id: groupId, is_reply: false,
        timestamp: "2026-09-04 00:00:00", verses: [], replies: []
    )
}

@MainActor
final class NotesGroupRefreshNullDataRegressionTests: XCTestCase {

    /// A fresh, per-test user id -- NotesViewModel.fetchAndCache is
    /// cache-first via the real on-disk DiskCache.shared, keyed by userId, so
    /// it persists across test runs in the same simulator container (same
    /// rationale as DashboardStaleReloadRegressionTests.freshUserId()).
    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    // MARK: 1 — a failed personal-notes fetch during refresh() must not wipe already-good notes (personal OR group)

    func test_refresh_personalNotesFetchFails_leavesGoodPersonalAndGroupNotesInPlace_doesNotWipeToEmpty() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        // Round 1: a successful initial load populates both segments, each
        // with hasMore: true so a later "was pageState reset?" check is
        // meaningful (the buggy code would silently reset both to the
        // NotesPageState default of hasMore: true too, so this alone isn't a
        // regression guard -- see the false-assertion note below).
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")],
            nextCursorCreatedAt: "personal-c1", nextCursorId: "p1", hasMore: true
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")],
            nextCursorCreatedAt: "group-c1", nextCursorId: "g1", hasMore: false
        )]
        await vm.load(service: service, userId: userId)

        XCTAssertNotNil(vm.notes["p1"], "sanity check: the first load must populate the personal note")
        XCTAssertNotNil(vm.notes["g1"], "sanity check: the first load must populate the group note")
        XCTAssertTrue(vm.hasMoreForCurrentSegment, "sanity check: personal segment's pageState must reflect hasMore: true from round 1")

        // Round 2: pull-to-refresh, personal notes fetch fails outright;
        // the group's fetch succeeds with the SAME data (proving this is a
        // genuine, distinguishable success, not just "nothing happened").
        service.fetchNotesError = AppError.networkError("simulated personal-notes failure")
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")],
            nextCursorCreatedAt: "group-c1", nextCursorId: "g1", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)

        XCTAssertNotNil(vm.notes["p1"],
                         "a failed personal-notes fetch must leave the already-good personal note in place, not wipe it")
        XCTAssertNotNil(vm.notes["g1"],
                         "the group's own (successful) notes must be unaffected by the personal fetch's failure")
        XCTAssertFalse(vm.notes.isEmpty,
                        "regression guard for the exact bug: notes must never collapse to empty just because one segment's fetch failed")
        XCTAssertTrue(vm.hasMoreForCurrentSegment,
                       "personal segment's pageState (hasMore: true from round 1) must be left as-is when its own fetch fails this round, " +
                       "so loadMoreIfNeeded doesn't misbehave after a partial refresh failure")
        XCTAssertFalse(vm.isLoading, "refresh() must still complete (not hang) when the personal fetch fails")
    }

    // MARK: 2 — a failed individual group's fetchGroupNotes during refresh() must not wipe that group's already-good notes

    func test_refresh_groupNotesFetchFails_leavesGoodGroupNotesInPlace_personalStillConverges() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")],
            nextCursorCreatedAt: "personal-c1", nextCursorId: "p1", hasMore: false
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")],
            nextCursorCreatedAt: "group-c1", nextCursorId: "g1", hasMore: true
        )]
        await vm.load(service: service, userId: userId)

        XCTAssertNotNil(vm.notes["p1"])
        XCTAssertNotNil(vm.notes["g1"])
        vm.currentGroupId = "group-abc"
        XCTAssertTrue(vm.hasMoreForCurrentSegment, "sanity check: group-abc's pageState must reflect hasMore: true from round 1")

        // Round 2: this specific group's fetch fails, while Personal's own
        // fetch succeeds with genuinely NEW data -- proving the fix doesn't
        // make Personal "sticky" too; only the failed group's segment is
        // preserved untouched.
        service.fetchGroupNotesErrorsByGroup["group-abc"] = AppError.networkError("simulated group-notes failure")
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p2": note("p2")],
            nextCursorCreatedAt: "personal-c2", nextCursorId: "p2", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)

        XCTAssertNotNil(vm.notes["g1"],
                         "a failed fetchGroupNotes call for this group must leave its already-good notes in place, not wipe them")
        XCTAssertTrue(vm.hasMoreForCurrentSegment,
                       "group-abc's pageState (hasMore: true from round 1) must be left as-is when its own fetch fails this round")
        XCTAssertNil(vm.notes["p1"], "Personal's own successful refresh must still fully replace its stale note (p1 -> p2), " +
                     "proving this fix doesn't prevent convergence for segments that DID succeed")
        XCTAssertNotNil(vm.notes["p2"], "Personal's freshly-fetched note must be present after its own successful refresh")
        XCTAssertFalse(vm.isLoading, "refresh() must still complete (not hang) when a group's fetch fails")
    }

    // MARK: 3 — convergence still holds: a failed group fetch followed by a later successful one picks up the fresh data

    func test_refresh_afterAFailedGroupFetch_aSubsequentSuccessfulRefresh_stillConvergesToFreshGroupData() async {
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
        XCTAssertNotNil(vm.notes["g1"])

        // Test-double gap fix (see file header): re-queue an explicit "p1"
        // personal page for EVERY round below. Without this, round 1's
        // single-page fetchNotesPageQueue entry is already consumed by
        // `load()` above, so a later `refresh()` call falls through
        // ThrowingTestDataService.fetchNotes' documented empty-queue
        // fallback to MockDataService.shared.fetchNotes -- a real,
        // successful personal fetch that legitimately replaces "p1" with
        // the mock's own (different-keyed) fixture notes. That's correct
        // per current splice semantics for a genuine personal-segment
        // success, but it flips this suite's unrelated group-segment
        // assertions on "p1" for the wrong reason -- a test-authoring gap,
        // not the group-clobber bug this suite exists to catch.
        service.fetchGroupNotesErrorsByGroup["group-abc"] = AppError.networkError("simulated group-notes failure")
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)
        XCTAssertNotNil(vm.notes["g1"], "sanity check: the failed refresh left the old group note in place")
        XCTAssertNotNil(vm.notes["p1"], "personal notes must be unaffected by the group segment's failed refresh")

        // A distinct, freshly-shaped group note proves the NEXT successful
        // refresh genuinely replaces the group's segment, rather than this
        // fix accidentally making stale group data sticky forever.
        service.fetchGroupNotesErrorsByGroup["group-abc"] = nil
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g2": note("g2", groupId: "group-abc")], nextCursorCreatedAt: "gc2", nextCursorId: "g2", hasMore: false
        )]
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)

        XCTAssertNil(vm.notes["g1"], "this fix must not prevent convergence -- a subsequent successful group fetch must fully replace the old group note")
        XCTAssertNotNil(vm.notes["g2"], "the group's freshly-fetched note must now be present")
        XCTAssertNotNil(vm.notes["p1"], "personal notes must be unaffected by the group segment's convergence")
    }

    // MARK: 4 — the actual user-facing symptom: a group's own decode failure must not silently masquerade as "this group is now empty"

    /// Root-cause regression (task 20260905-notes-group-refresh-clobber-rootcause):
    /// before the production fix, NetworkService.fetchGroupNotes fabricated a
    /// successful, non-throwing, EMPTY NotesPage whenever its manual
    /// JSONSerialization parse hit a decode failure -- indistinguishable
    /// right here, at the ViewModel's splice layer, from "the group
    /// genuinely has zero notes now". Since `personalSucceeded`/
    /// `succeededGroupIds` only care whether the call threw, not why it
    /// didn't, that fabricated "success" clobbered a previously non-empty
    /// group's notes down to nothing every time a real decode failure
    /// happened -- exactly the live symptom the user reported, and exactly
    /// what `20260905-pull-to-refresh-cache-clobber` incorrectly waved
    /// through as "already fixed" for Notes/Groups.
    ///
    /// This test proves the fix using the SAME error type/message
    /// NetworkService+Notes.swift's fetchGroupNotes now actually throws on a
    /// decode failure (see that file's `AppError.networkError("Could not
    /// load this group's notes right now.")` call site) -- a real,
    /// distinguishable thrown error now reaches this splice logic instead of
    /// a fabricated empty page, so the group's previously non-empty notes
    /// are correctly left in place rather than wiped. The companion
    /// NetworkServiceGetErrorHandlingTests.swift tests
    /// (`test_fetchGroupNotes_throws_onMalformedResponseShape_...` /
    /// `test_fetchNotes_throws_onUndecodableBody_...`) prove the network
    /// layer itself now actually throws in that situation, rather than
    /// fabricating the empty page this test assumes never reaches here.
    func test_refresh_groupFetchThrowsDecodeFailureError_previouslyNonEmptyGroupSegment_isNotWipedToEmpty() async {
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        // Round 1: the group starts with THREE notes -- multiple, not just
        // one -- so this test can't pass by accident the way a single-note
        // check might if some other unrelated code path happened to leave
        // exactly one stray entry behind.
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: [
                "g1": note("g1", groupId: "group-abc"),
                "g2": note("g2", groupId: "group-abc"),
                "g3": note("g3", groupId: "group-abc"),
            ],
            nextCursorCreatedAt: "gc1", nextCursorId: "g3", hasMore: false
        )]
        await vm.load(service: service, userId: userId)

        vm.currentGroupId = "group-abc"
        XCTAssertEqual(vm.filteredNotes.count, 3, "sanity check: the group starts with all three notes visible")

        // Round 2: simulate the exact production failure mode -- the
        // group's own fetch throws the same AppError.networkError the real
        // decode-failure fix now throws, in place of the old fabricated
        // empty NotesPage. Personal's own fetch succeeds with unrelated new
        // data, proving this isn't just "nothing happened this round."
        service.fetchGroupNotesErrorsByGroup["group-abc"] =
            AppError.networkError("Could not load this group's notes right now.")
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p2": note("p2")], nextCursorCreatedAt: "c2", nextCursorId: "p2", hasMore: false
        )]
        await vm.refresh(service: service, userId: userId)

        XCTAssertEqual(vm.filteredNotes.count, 3,
                        "the actual user-facing symptom: a group's own decode failure (now a real thrown error, " +
                        "not a fabricated empty page) must NOT wipe that group's visible note list to empty")
        XCTAssertNotNil(vm.notes["g1"]); XCTAssertNotNil(vm.notes["g2"]); XCTAssertNotNil(vm.notes["g3"])
        XCTAssertNotNil(vm.notes["p2"], "Personal's own successful refresh must still converge despite the group's failure")
        // NotesViewModel.fetchAndCache prefixes every segment's error with
        // that segment's own name (`"\(title): \(error.localizedDescription)"`,
        // mirroring the existing `"Personal: ..."` convention for the
        // personal segment) so a user with multiple groups can tell WHICH
        // one failed -- the mock group's fixed title is "Wednesday Night
        // Study" (see this file's own header comment). Asserting the raw,
        // unprefixed message here was a test-authoring bug (this assertion
        // was added by this task, not part of the production fix under
        // test): the message DOES surface (Q26/Q27) exactly as designed,
        // just with the segment-identifying prefix this test's first
        // version of the assertion didn't account for.
        XCTAssertEqual(vm.refreshError, "Wednesday Night Study: Could not load this group's notes right now.",
                        "the swallowed error must now surface visibly (Q26/Q27), prefixed with the failing segment's name, instead of vanishing with no trace")
    }
}
