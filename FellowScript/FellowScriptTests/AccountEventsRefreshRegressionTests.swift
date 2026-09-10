// AccountEventsRefreshRegressionTests.swift — testing-gate coverage for task
// 20260910-account-events-refresh-regression (spec: Account Events vanish on
// pull-to-refresh and on force-quit + relaunch, reported live AFTER task
// 20260910-refresh-clobber-live-rootcause's own step 6 had verified Events
// survived every refresh/cancellation round it tested).
//
// Root cause traced by frontend step 2/3 (step2-static-analysis-findings.md,
// frontend.json): NetworkService+Agents.swift's fetchAgents(userId:) was the
// one sibling fetch in that file that still fabricated a "successful" `[]`
// on a top-level decode failure instead of throwing, unlike fetchHeartbeats
// (already hardened by the PRIOR task on this bug family) and
// fetchNotesCount/fetchHighlights' beacon-tagging. Traced consequence
// through AccountViewModel.load(): a non-nil-but-empty agentsResult makes
// `eventsUsable = (agentsResult != nil)` evaluate true even though nothing
// was actually fetched, so BOTH `agents` and `events` get wiped in-memory --
// and because this reads as a successful (non-cancelled) round, that wipe
// gets persisted to disk on the very next unconditional cache write,
// poisoning the very next cold-launch cache-first read too. This reproduces
// the reported symptom on both axes: "gone on refresh" (in-memory wipe) AND
// "gone on force-quit relaunch" (poisoned disk cache).
//
// Fix (frontend step 3): fetchAgents now throws AppError.networkError on a
// decode failure, exactly mirroring fetchHeartbeats' own established
// pattern -- verified already, at the NetworkService layer alone, by
// AccountStatsDecodeFailureBeaconTests' corrected
// test_fetchAgents_malformedShape_decodeFails_throwsAndFiresBeacon.
//
// What THIS file adds, closing the exact gap frontend step 3's own summary
// flagged ("a dedicated AccountViewModel.load()-level test proving a
// genuine fetchAgents decode failure no longer wipes agents/events...not
// the mock"): AccountViewModelLoadCacheClobberRegressionTests' existing
// test_load_fetchAgentsFails_leavesAgentsAndEventsInPlace_othersStillUpdate
// (PullToRefreshCacheClobberSweepRegressionTests.swift) only ever drives
// AccountViewModel.load() via ThrowingTestDataService's fetchAgentsError
// seam -- it proves load()'s own reaction to an already-thrown error, but
// never actually exercises NetworkService+Agents.swift's decode() call site
// this task's fix touched. This file drives that real call site (via the
// new fetchAgentsCallsRealNetworkService seam on ThrowingTestDataService +
// StubURLProtocol, both already shared test infrastructure) through
// AccountViewModel.load() end to end, and -- unlike any prior test on this
// bug family -- also asserts directly on what DiskCache actually persists,
// proving the fix closes the disk-poisoning half of the symptom, not just
// the in-memory half.
//
// Verified failing pre-fix: with NetworkService+Agents.swift's fetchAgents
// temporarily reverted to `guard let dict = decode(...) else { return [] }`,
// both tests below fail exactly as expected (see testing.json for the
// revert-and-rerun record) -- confirming these tests actually exercise the
// regression, not just the already-passing post-fix behavior.

import XCTest
@testable import FellowScript

@MainActor
final class AccountEventsRefreshRegressionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    private func freshUser(_ label: String) -> FSUser {
        FSUser(user_id: "acct-events-refresh-\(label)-\(UUID().uuidString)", username: "user-\(label)", email: "\(label)@example.com")
    }

    /// Seeds a fully successful first load (mock-backed, no real network
    /// involved yet) so `agents`/`events` are populated both in memory and
    /// on disk -- the "already-displayed, already-cached good state" that
    /// the regression is about clobbering.
    private func seedGoodLoad(service: ThrowingTestDataService, user: FSUser) async -> AccountViewModel {
        let vm = AccountViewModel()
        service.fetchAgentsCallsRealNetworkService = false
        service.fetchAgentsResult = [FSAgent(id: "agent-real-1", user_id: user.user_id, name: "Guide", role: "guide", enabled: true, chats: [])]
        service.fetchHeartbeatsResultsByAgent["agent-real-1"] = [
            FSHeartbeat(id: "hb-real-1", agent_id: "agent-real-1", user_id: user.user_id,
                        timestamps: Array(repeating: "13:00", count: 31), prompt: "Reflect on Colossians.", group_id: nil)
        ]
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.agents.map(\.id), ["agent-real-1"], "sanity check: the seeding load must populate agents")
        XCTAssertEqual(vm.events.map(\.id), ["hb-real-1"], "sanity check: the seeding load must populate events")
        return vm
    }

    // MARK: 1 — pull-to-refresh: a genuine fetchAgents decode failure through
    // the REAL NetworkService must not wipe the already-displayed agents/
    // events in memory, and must not poison what gets persisted to disk.

    func test_pullToRefresh_realFetchAgentsDecodeFailure_leavesInMemoryStateIntact_andDoesNotPoisonDiskCache() async {
        let service = ThrowingTestDataService()
        let user = freshUser("refresh")
        let vm = await seedGoodLoad(service: service, user: user)

        // Arm the REAL NetworkService.fetchAgents call for a genuine
        // top-level decode failure -- a response shaped nothing like
        // {uuid: {...}}, matching AccountStatsDecodeFailureBeaconTests'
        // own reproduction of this exact failure mode.
        service.fetchAgentsCallsRealNetworkService = true
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = "[1, 2, 3]".data(using: .utf8)!

        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.agents.map(\.id), ["agent-real-1"],
                       "THE FIX: a genuine fetchAgents decode failure (via the real NetworkService, not a mock throw) must not wipe the already-displayed agents list to empty")
        XCTAssertEqual(vm.events.map(\.id), ["hb-real-1"],
                       "THE FIX: with no agent list to walk, events must be left entirely untouched -- this is the exact in-memory half of the reported 'events gone on refresh' symptom")
        XCTAssertNotNil(vm.statsMsg, "a genuine decode failure must still surface statsMsg, not be silently swallowed")
        XCTAssertFalse(vm.isLoading)

        // The disk half of the symptom: this round is NOT a cancellation, so
        // load() proceeds to its unconditional cache write -- before the
        // fix, that write persisted the wiped agents:[]/events:[] straight
        // over the good cached values. Read the cache directly (bypassing
        // AccountViewModel entirely) to prove it was NOT poisoned.
        let cachedAgents = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(user.user_id)")
        let cachedEvents = await DiskCache.shared.load([FSHeartbeat].self, forKey: "events:\(user.user_id)")
        XCTAssertEqual(cachedAgents?.map(\.id), ["agent-real-1"],
                       "THE FIX: the disk cache's agents entry must still hold the last known-good value, not an empty array written over it by this round's failed fetch")
        XCTAssertEqual(cachedEvents?.map(\.id), ["hb-real-1"],
                       "THE FIX: the disk cache's events entry must still hold the last known-good value -- this is the exact mechanism that made the prior bug survive a force-quit relaunch too, since the very next cold launch reads this same poisoned key")
    }

    // MARK: 2 — force-quit + relaunch: a FRESH AccountViewModel instance
    // (zero in-memory state, exactly like a cold launch) whose very first
    // load() call hits the real fetchAgents decode failure must still show
    // the previously cached good data via its own cache-first read, not an
    // empty screen.

    func test_forceQuitRelaunch_freshViewModel_realFetchAgentsDecodeFailure_stillShowsCachedEvents() async {
        let service = ThrowingTestDataService()
        let user = freshUser("relaunch")
        _ = await seedGoodLoad(service: service, user: user)

        // Simulate "force-quit + relaunch": a brand-new AccountViewModel,
        // exactly as a fresh app launch would construct one -- no state
        // carried over except what's on disk.
        let relaunchedVM = AccountViewModel()
        service.fetchAgentsCallsRealNetworkService = true
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = "[1, 2, 3]".data(using: .utf8)!

        await relaunchedVM.load(service: service, user: user)

        XCTAssertEqual(relaunchedVM.agents.map(\.id), ["agent-real-1"],
                       "THE FIX: a fresh instance's cache-first read must populate agents from disk, and a failing fetchAgents on this same load() call must not then overwrite that with an empty result -- reproduces the reported 'never see events after force-quit + relaunch' symptom and proves it's closed")
        XCTAssertEqual(relaunchedVM.events.map(\.id), ["hb-real-1"],
                       "THE FIX: events must still show from the cache-first read on relaunch, exactly matching what the user described failing")
        XCTAssertNotNil(relaunchedVM.statsMsg, "the genuine decode failure must still be surfaced, not hidden")
    }
}
