// AccountEventsCacheFirstClobberLiveStateRegressionTests.swift —
// testing-gate coverage for task 20260929-account-events-missing-list, step
// 2. This is the SIXTH fix attempt at the "account events missing" symptom;
// the prior five all fought at load()'s FINAL commit
// generation/committedGeneration guard. Frontend step 1's evidenced root
// cause is a completely different, earlier block in the same method: the
// cache-first reads at the top of AccountViewModel.load() used to assign
// straight to @Published state (profileData/agents/events/noteCount+
// highlightCount) on EVERY call -- the initial `.task`, a `.refreshable`
// pull, or a `.task` re-fire alike -- with no generation/committedGeneration
// check at all, unlike every other commit path in this heavily-guarded
// function. DiskCache is a single actor serializing ALL of this app's cache
// traffic (Notes/Dashboard/Chat/Account together), so a round's own
// "events:<uid>" cache read is a genuine `await` that can resolve well after
// a fresh, correctly-committed round has already set real data in memory --
// at which point applying that stale disk snapshot silently reverts the
// Events section back to whatever was last written to disk, with no error
// shown (statsMsg untouched, since this isn't a fetch failure at all).
//
// RefreshClobberLiveRootcauseRegressionTests.swift ("mechanism 3:
// cache-first-over-live-state") already fixed the identical mechanism for
// the sibling NotesViewModel, gating cache-first application to
// initial-load-only via hasLoadedOnce/showLoadingSpinner -- but that task's
// own header comment explicitly named AccountViewModel.load()'s cache-first
// block as "unchanged, pre-existing, out-of-this-task's-scope behavior",
// not verified safe. This file is the regression coverage AccountViewModel's
// own mirrored `hasLoadedOnce` fix (this task's frontend step 1) was
// missing.
//
// Isolation strategy: a round where fetchAgents itself fails outright makes
// `eventsUsable == false`, which makes load()'s FINAL commit block skip
// `events = allEvents` entirely (see load()'s own comment: "if
// fetchAgents itself failed... there's no agent list to walk at all... `events`
// is left untouched by the write below"). That isolates this test to the
// cache-first block specifically: under the pre-fix code, the ONLY thing
// that could still change `vm.events` in such a round is the unconditional
// cache-first reapplication this task fixed. Under the fix, nothing in a
// non-initial round may touch `vm.events` via the cache-first path, so the
// already-live, correctly-committed value must survive untouched.

import XCTest
@testable import FellowScript

@MainActor
final class AccountEventsCacheFirstClobberLiveStateRegressionTests: XCTestCase {

    private func freshUser(_ label: String) -> FSUser {
        FSUser(user_id: "cachefirst-clobber-\(label)-\(UUID().uuidString)", username: "user-\(label)", email: "\(label)@example.com")
    }

    /// THE core regression: a stale/poisoned disk snapshot for
    /// "events:<uid>" written between two load() rounds (exactly what a
    /// different, faster overlapping round -- or a prior app session -- can
    /// leave behind) must never overwrite this VM's already-live, correctly
    /// proven `events` on a subsequent (non-initial) round.
    func test_load_secondRound_staleDiskCacheForEvents_doesNotClobberAlreadyLiveEvents() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("stale")
        let agent = FSAgent(id: "agent-1", user_id: user.user_id, role: "r", enabled: true, chats: [])
        service.fetchAgentsResult = [agent]
        service.fetchHeartbeatsResultsByAgent["agent-1"] = [FSHeartbeat(id: "hb-real", agent_id: "agent-1", user_id: user.user_id, prompt: "p1")]

        // Round 1 (initial load): genuinely succeeds, proving real events.
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.events.map(\.id), ["hb-real"], "sanity check: initial load populates real events")
        XCTAssertTrue(vm.eventsLoaded, "sanity check: a clean initial round proves eventsLoaded")

        // Simulate a different, faster overlapping round (or a stale prior
        // session) having since written an empty/poisoned snapshot to disk
        // for this exact key -- the live mechanism frontend step 1
        // identified: DiskCache is single-actor-serialized across the whole
        // app, so this write is a perfectly realistic thing to have landed
        // on disk without this VM's own in-memory state having changed.
        await DiskCache.shared.save([FSHeartbeat](), forKey: "events:\(user.user_id)")

        // Round 2 (e.g. a `.refreshable` pull): fetchAgents itself fails
        // outright, so `eventsUsable == false` and the FINAL commit block
        // cannot touch `vm.events` either way -- isolating this test to the
        // cache-first read's own behavior.
        service.fetchAgentsError = AppError.networkError("simulated transient agents failure")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.events.map(\.id), ["hb-real"],
                       "THE FIX: a non-initial load() round must not reapply a stale/poisoned disk-cache read for \"events:<uid>\" over this VM's already-live, correctly-proven events")
        XCTAssertTrue(vm.eventsLoaded, "eventsLoaded, once proven true by an earlier clean round, must never be un-proven by a later round that couldn't establish anything either way")
        XCTAssertNotNil(vm.statsMsg, "the genuine (non-cancellation) fetchAgents failure this round must still surface statsMsg")
        XCTAssertFalse(vm.isLoading)
    }

    /// Same mechanism, different field: `noteCount` must also survive a
    /// stale "counts:<uid>" disk snapshot on a second round, proving the fix
    /// isn't narrowly scoped to just the events key. Isolated the same way:
    /// this round's OWN fetchNotesCount fails outright, so the final commit
    /// block's `if let noteCountResult { noteCount = ... }` never runs
    /// either -- the only thing that could still move `noteCount` on a
    /// pre-fix build is the unconditional cache-first reapplication.
    func test_load_secondRound_staleDiskCacheForCounts_doesNotClobberAlreadyLiveNoteCount() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("counts")
        service.fetchNotesCountResult = 7
        service.fetchHighlightsResult = ["h1": "text"]

        // Round 1 (initial load): genuinely succeeds with a real note count.
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.noteCount, 7, "sanity check: initial load populates the real note count")

        // Poison disk with a stale/wrong counts pair under the same key --
        // exactly what a different, faster overlapping round could leave
        // behind per the mechanism frontend step 1 identified.
        await DiskCache.shared.save([0, 1], forKey: "counts:\(user.user_id)")

        // Round 2: fetchNotesCount itself fails outright this time, so
        // noteCount's final-commit assignment is skipped -- isolating this
        // test to the cache-first read's own behavior for this field.
        service.fetchNotesCountError = AppError.networkError("simulated transient notes-count failure")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.noteCount, 7,
                       "THE FIX: a non-initial load() round must not reapply a stale/poisoned disk-cache read for \"counts:<uid>\" over this VM's already-live, correctly-proven noteCount")
        XCTAssertNotNil(vm.statsMsg, "the genuine (non-cancellation) fetchNotesCount failure this round must still surface statsMsg")
        XCTAssertFalse(vm.isLoading)
    }
}
