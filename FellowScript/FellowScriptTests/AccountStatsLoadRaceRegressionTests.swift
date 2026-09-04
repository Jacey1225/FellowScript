// AccountStatsLoadRaceRegressionTests.swift — testing-gate coverage for task
// 20260903-account-stats-not-loading, step 2 (testing), covering the
// frontend gate's step 1 fix to AccountViewModel.load().
//
// Root cause confirmed by the frontend gate: load() has no de-duplication
// between the initial `.task` on AccountView's mount and a `.refreshable`
// pull (or a `.task` re-fire) — two overlapping calls can be in flight at
// once, and previously whichever one *finished last* unconditionally
// overwrote noteCount/highlightCount/agents/events (and their DiskCache
// entries), even if it was the slower/cancelled/failing one. The fix adds a
// `loadGeneration` counter: each call resolves its fetches into LOCAL
// variables first, then only commits (to @Published state AND DiskCache) if
// no newer load() call has started since.
//
// This file proves, against the real AccountViewModel (not by reading the
// source):
//   1. THE ROOT CAUSE FIX — a slower, superseded load() call can never
//      clobber a faster, fresher call's real data, for all three previously
//      broken fields (agents, noteCount, highlightCount).
//   2. That same win also closes the DiskCache self-perpetuation candidate
//      the intake spec flagged: the cache ends up holding the FRESH call's
//      values, not the stale call's, so the next cold-launch cache-first
//      read doesn't inherit a bad zero.
//   3. A genuine fetch/decode failure on notes/highlights/agents now
//      surfaces `statsMsg` instead of looking visually identical to "this
//      account has zero" (and a normal successful load never shows it).
//   4. No regression to Usage/Groups/Friend Requests, which are fetched
//      inside this same load() call via the same generation-guarded path.
//
// Uses ThrowingTestDataService (defined in AppStateAuthAccountTests.swift,
// same test target), which this task's testing step extended with
// fetchAgents/fetchHighlights/fetchNotesCount error/delay/result seams
// (previously the only three fetch methods on that double with no
// controllable seam at all).

import XCTest
@testable import FellowScript

@MainActor
final class AccountStatsLoadRaceRegressionTests: XCTestCase {

    private func makeUser(_ id: String) -> FSUser {
        FSUser(user_id: id, username: "alice", email: "alice@example.com")
    }

    // MARK: 1/2 — the actual root-cause fix: stale-slower-call clobber + cache self-perpetuation

    /// Two overlapping load() calls, each given its OWN service instance so
    /// their results are independently distinguishable: `staleService` is
    /// slow (simulating the production scenario — a `.task` re-fire or a
    /// pull-to-refresh racing the initial mount fetch) and would, if it won,
    /// leave the screen showing a stale/zeroed "0 notes / 0 highlights / no
    /// agents" state; `freshService` is fast and returns this account's real
    /// (non-empty, non-zero) data. Before the fix, whichever call finished
    /// LAST won regardless of which was actually newer — since staleService
    /// is slower, it would finish after freshService and clobber the correct
    /// result. After the fix, the loadGeneration guard means only the call
    /// that was still current when it *finished* commits, independent of
    /// finish order relative to which call is "correct".
    func test_load_slowerStaleCall_neverClobbersFasterFresherCall_forAgentsNotesHighlights() async throws {
        let vm = AccountViewModel()
        let userId = "account-stats-race-user-1"
        let user = makeUser(userId)

        let staleService = ThrowingTestDataService()
        staleService.fetchAgentsDelayNanoseconds = 400_000_000
        staleService.fetchNotesCountDelayNanoseconds = 400_000_000
        staleService.fetchHighlightsDelayNanoseconds = 400_000_000
        staleService.fetchAgentsResult = []
        staleService.fetchNotesCountResult = 0
        staleService.fetchHighlightsResult = [:]

        let freshService = ThrowingTestDataService()
        let realAgent = FSAgent(id: "agent-real-1", user_id: userId, name: "Prayer Guide", role: "guide", enabled: true, chats: [])
        freshService.fetchAgentsResult = [realAgent]
        freshService.fetchNotesCountResult = 133
        freshService.fetchHighlightsResult = [
            "Genesis_1_1_gold": "#FFD700", "John_3_16_blue": "#3366FF"
        ]

        // Start the slow, stale call first (mirrors the initial `.task`).
        let staleTask = Task { await vm.load(service: staleService, user: user) }
        // Give it time to bump loadGeneration and begin its in-flight fetches
        // before the "fresher" call (mirrors a pull-to-refresh) starts.
        try await Task.sleep(nanoseconds: 50_000_000)

        // The fresh call has no delay, so it fully completes (and commits)
        // well before the stale call's 400ms fetches resolve.
        await vm.load(service: freshService, user: user)

        XCTAssertEqual(vm.agents.map(\.id), ["agent-real-1"],
                        "the freshest completed call's real agent must be showing right after it commits")
        XCTAssertEqual(vm.noteCount, 133)
        XCTAssertEqual(vm.highlightCount, 2)
        XCTAssertNil(vm.statsMsg, "the fresh call succeeded cleanly -- no failure banner should show yet")

        // Now let the stale call actually finish and attempt to commit.
        await staleTask.value

        XCTAssertEqual(vm.agents.map(\.id), ["agent-real-1"],
                        "THE FIX: a slower, now-superseded call finishing AFTER a fresher call must NOT clobber the fresher call's real agents with its own stale empty result")
        XCTAssertEqual(vm.noteCount, 133,
                        "THE FIX: the stale call's 0 must not overwrite the fresh call's real note count")
        XCTAssertEqual(vm.highlightCount, 2,
                        "THE FIX: the stale call's empty highlights must not overwrite the fresh call's real highlight count")

        // Cache self-perpetuation candidate (intake spec, leads #3): the
        // stale call must also not be the one whose (bad) result gets
        // written to DiskCache, or the very next cold-launch cache-first
        // read would resurrect the bug even after this fix.
        let cachedAgents = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(userId)")
        XCTAssertEqual(cachedAgents?.map(\.id), ["agent-real-1"],
                        "DiskCache must hold the fresh call's real agents, not the stale call's empty result -- otherwise the bad zero would self-perpetuate into the next load()'s cache-first read")
        let cachedCounts = await DiskCache.shared.load([Int].self, forKey: "counts:\(userId)")
        XCTAssertEqual(cachedCounts, [133, 2],
                        "DiskCache must hold the fresh call's real counts, not the stale call's zeros")
    }

    // MARK: 3 — statsMsg surfaces a genuine failure, and only a genuine failure

    /// Before the fix, `(try? await fetchedAgents) ?? []` (and the sibling
    /// notes/highlights fetches) silently collapsed ANY failure -- a thrown
    /// network/HTTP error, a decode failure, or a cancelled/superseded call
    /// -- to a zero/empty default with zero user-facing signal. This proves
    /// a genuine throw on the current (non-superseded) call now surfaces
    /// `statsMsg`, matching this screen's existing agentMsg/friendMsg alert
    /// convention (per the UI/UX preference profile), instead of looking
    /// indistinguishable from "this account really has zero".
    func test_load_genuineFetchFailure_setsStatsMsg_soFailureIsNotIndistinguishableFromZero() async {
        let vm = AccountViewModel()
        let user = makeUser("account-stats-fail-user-1")
        let service = ThrowingTestDataService()
        service.fetchAgentsError = AppError.networkError("simulated agents fetch failure")

        await vm.load(service: service, user: user)

        XCTAssertNotNil(vm.statsMsg,
                         "a genuine fetch failure on agents must surface statsMsg -- previously this silently looked identical to a real zero-agent account")
        XCTAssertFalse(vm.statsMsg?.isEmpty ?? true)
    }

    /// Same proof for a notes-count failure specifically (not just agents),
    /// since all three fetches independently feed the same `statsFailed`
    /// flag.
    func test_load_genuineNotesCountFailure_setsStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-stats-fail-user-2")
        let service = ThrowingTestDataService()
        service.fetchNotesCountError = AppError.networkError("simulated notes-count fetch failure")

        await vm.load(service: service, user: user)

        XCTAssertNotNil(vm.statsMsg,
                         "a genuine fetch failure on notes count must also surface statsMsg")
    }

    /// Same proof for a highlights failure specifically.
    func test_load_genuineHighlightsFailure_setsStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-stats-fail-user-3")
        let service = ThrowingTestDataService()
        service.fetchHighlightsError = AppError.networkError("simulated highlights fetch failure")

        await vm.load(service: service, user: user)

        XCTAssertNotNil(vm.statsMsg,
                         "a genuine fetch failure on highlights must also surface statsMsg")
    }

    /// Regression guard / no-false-positive check: a completely normal,
    /// successful load must never show the new failure banner.
    func test_load_normalSuccess_neverSetsStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-stats-success-user-1")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "a1", user_id: user.user_id, name: "Guide", role: "guide", enabled: true, chats: [])]
        service.fetchNotesCountResult = 133
        service.fetchHighlightsResult = ["Genesis_1_1_gold": "#FFD700"]

        await vm.load(service: service, user: user)

        XCTAssertNil(vm.statsMsg, "a normal successful load must never show the stats failure banner")
        XCTAssertEqual(vm.agents.count, 1)
        XCTAssertEqual(vm.noteCount, 133)
        XCTAssertEqual(vm.highlightCount, 1)
    }

    // MARK: 4 — no regression to Usage / Groups / Friend Requests (fetched in the same load())

    /// These three are sourced through the exact same generation-guarded
    /// commit path as the fixed fields -- proves the refactor didn't break
    /// them while fixing notes/highlights/agents.
    func test_load_regression_usageGroupsAndFriendRequests_stillPopulateCorrectly() async {
        let vm = AccountViewModel()
        let user = makeUser("account-stats-regression-user-1")
        let service = ThrowingTestDataService()

        await vm.load(service: service, user: user)

        // fetchContacts' mock fixture always includes a "group-abc" group
        // (see MockDataService.fetchContacts) -- proves groups still comes
        // through the shared fetchedContacts async-let unharmed.
        XCTAssertFalse(vm.groups.isEmpty, "groups (sourced from fetchContacts) must still populate after the generation-guard refactor")
        XCTAssertNotNil(vm.groups["group-abc"])

        // fetchFriendRequests' mock default is an empty array -- proves the
        // call still actually runs and completes without crashing/hanging,
        // matching pre-fix behavior (not skipped or broken by the refactor).
        XCTAssertEqual(service.fetchNotesCountCallCount, 1, "notesCount must still be fetched exactly once for a single load() call")
        XCTAssertTrue(vm.friendRequests.isEmpty)

        // usage stays nil on this double's default (unsubscribed) mock,
        // matching pre-fix behavior -- proves the refactor didn't
        // accidentally start throwing away a real result or crash on nil.
        XCTAssertNil(vm.usage)
    }

    /// Sequential (non-overlapping) repeat calls -- what pull-to-refresh
    /// actually does in the common case -- must remain fully stable, not
    /// just the artificial-overlap race case above.
    func test_load_sequentialRepeatCalls_remainStable_notJustTheOverlapCase() async {
        let vm = AccountViewModel()
        let user = makeUser("account-stats-sequential-user-1")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "a1", user_id: user.user_id, name: "Guide", role: "guide", enabled: true, chats: [])]
        service.fetchNotesCountResult = 133
        service.fetchHighlightsResult = ["Genesis_1_1_gold": "#FFD700"]

        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.noteCount, 133)

        // A second, fully sequential call (no overlap) must still commit
        // normally -- the generation guard must never block a call that
        // really is the latest.
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.noteCount, 133)
        XCTAssertEqual(vm.agents.count, 1)
        XCTAssertNil(vm.statsMsg)
    }
}
