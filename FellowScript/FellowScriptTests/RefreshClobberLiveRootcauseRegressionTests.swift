// RefreshClobberLiveRootcauseRegressionTests.swift — testing-gate coverage
// for task 20260910-refresh-clobber-live-rootcause, step 5. This is the
// FOURTH attempt at the group-notes / Account pull-to-refresh data-loss bug;
// the prior three each "fixed" it at the code-reading/synthetic-test level
// and each still reproduced live. This file proves the mechanisms frontend
// step 2's live+server capture actually confirmed (step2-root-cause.md,
// backend.json) and frontend step 3 fixed (frontend.json) -- not the prior
// tasks' synthetic shapes, which this task's spec explicitly says were
// insufficient:
//
//   1. Cross-screen cache-key collision (mechanism 2, confirmed live at
//      count=31->15 on every launch): DashboardView.load() used to write a
//      personal-only page into "notes:<uid>", the exact shared key
//      NotesViewModel.fetchAndCache owns and writes the full merged
//      personal+group set into. Dashboard now owns its own
//      "dashboardNotes:<uid>" key and never touches the shared one
//      (cache_ownership_rule, architecture.json).
//   2. Cache-first-over-live-state (mechanism 3, confirmed live at
//      08:05:56 in this task's capture): NotesViewModel.fetchAndCache's
//      disk-cache-first read used to be reapplied over LIVE in-memory state
//      on every call, including an explicit pull-to-refresh -- so any
//      stale/poisoned disk write since the screen last loaded got reapplied
//      on top of what the user was already looking at, before any network
//      request even resolved. Cache-first is now initial-load-only (gated
//      on showLoadingSpinner, i.e. hasLoadedOnce).
//   3. Cancelled-round persistence (mechanism 4, spec item (c), Q14
//      fail-closed): a refresh/load round where any segment/fetch was
//      cooperatively cancelled proves nothing -- neither a proven fresh
//      success nor a proven failure -- so it must not write ANY of its
//      DiskCache keys, on both NotesViewModel.fetchAndCache and
//      AccountViewModel.load().
//   4. loadSubscription() cancellation-vs-genuine-failure (mechanism 5,
//      spec open question 2): a cooperatively-cancelled fetchUserSubscription
//      must never set subMsg (the exact banner-wording-change symptom the
//      user reported); a genuine failure still must.
//   5. loadSubscription() in-flight de-duplication (the SECOND,
//      previously-unknown root cause frontend step 2's live capture
//      discovered: only 1 of 8 device-observed requests ever reached origin
//      in one capture window, the rest blocked by Cloudflare-edge 403s from
//      a concurrent-request burst) -- AccountView's independent `.task` and
//      `.refreshable` calls must now collapse into one in-flight request.
//   6. fetchHeartbeats decode-failure handling (mechanism 6, spec scope
//      item 3, Q27): a decode failure now throws instead of fabricating an
//      empty success, and the disk write for "events:<uid>" must preserve
//      previously-proven data rather than persist a fabricated empty result.
//
// Uses ThrowingTestDataService (AppStateAuthAccountTests.swift), extended in
// this task's testing step with a `fetchUserSubscriptionDelayNanoseconds`
// seam (mirroring the existing fetchAgentsDelayNanoseconds/
// fetchHeartbeatsDelayNanoseconds pattern) so mechanism 5's test can prove
// the collapse via real wall-clock overlap, not just by inspecting the guard
// flag directly.
//
// Every "persists nothing" test below plants a sentinel directly on disk
// (via DiskCache.shared, bypassing the view model entirely) that no real
// write from the call under test could ever produce -- so a pass proves NO
// write happened at all, not merely that a write happened to re-persist
// equivalent content (the vacuous-pass trap the 20260909 testing gate itself
// warned about repeating).

import XCTest
@testable import FellowScript

private func note(_ id: String, groupId: String = "") -> FSNote {
    FSNote(
        id: id, user: "user-1", title: "Note \(id)", text: "body",
        public: false, group_id: groupId, is_reply: false,
        timestamp: "2026-09-10 00:00:00", verses: [], replies: []
    )
}

// MARK: - 1. Cross-screen cache-key ownership (mechanism 2)

@MainActor
final class DashboardNotesCacheOwnershipRegressionTests: XCTestCase {

    private func freshUserId() -> String { "cache-owner-\(UUID().uuidString)" }

    func test_dashboardLoad_writesOwnNamespacedKey_neverTouchesNotesViewModelsSharedKey() async {
        let userId = freshUserId()

        // Seed "notes:<uid>" with a sentinel merged set a real NotesViewModel
        // would have written (personal + a group note) -- DashboardView.load()
        // must never touch this key at all, let alone overwrite it with its
        // own narrower personal-only payload.
        let sentinel: [String: FSNote] = ["p1": note("p1"), "g1": note("g1", groupId: "group-abc")]
        await DiskCache.shared.save(sentinel, forKey: "notes:\(userId)")

        let dashVm = DashboardViewModel()
        let service = ThrowingTestDataService()
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false
        )]
        await dashVm.load(service: service, userId: userId)

        let afterDashboard: [String: FSNote]? = await DiskCache.shared.load([String: FSNote].self, forKey: "notes:\(userId)")
        XCTAssertEqual(afterDashboard?.count, 2,
                        "THE FIX: DashboardView.load() must never write NotesViewModel's shared \"notes:<uid>\" key -- the pre-existing merged (personal+group) sentinel must be completely untouched")
        XCTAssertNotNil(afterDashboard?["g1"], "the group note in the shared key must survive a Dashboard load unrelated to it")

        let dashboardOwnKey: [String: FSNote]? = await DiskCache.shared.load([String: FSNote].self, forKey: "dashboardNotes:\(userId)")
        XCTAssertEqual(dashboardOwnKey?.count, 1,
                        "Dashboard must write its own personal-only page into its OWN namespaced key instead of the shared one")
        XCTAssertNotNil(dashboardOwnKey?["p1"])
        XCTAssertFalse(dashVm.isLoading)
    }
}

// MARK: - 2. NotesViewModel.refresh() no longer reapplies disk cache over live in-memory state (mechanism 3)

@MainActor
final class NotesRefreshCacheReapplyRegressionTests: XCTestCase {

    private func freshUserId() -> String { "cache-reapply-\(UUID().uuidString)" }

    /// Isolates mechanism 3 from mechanism 2: this test doesn't care who
    /// poisoned the shared key (that's mechanism 2's own, separately-tested
    /// fix) -- it plants the poisoned personal-only payload directly, then
    /// proves refresh() itself no longer reapplies that disk read over live
    /// in-memory state before its own network fetches resolve.
    func test_refresh_priorPoisonedDiskCache_doesNotClobberLiveGroupNotes_beforeFetchResolves() async {
        let userId = freshUserId()
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")], nextCursorCreatedAt: "gc1", nextCursorId: "g1", hasMore: false
        )]
        await vm.load(service: service, userId: userId)
        XCTAssertNotNil(vm.notes["g1"], "sanity check: initial load populates the group note")

        // Simulate any writer poisoning the shared key between the initial
        // load and this pull-to-refresh with a personal-only payload -- the
        // exact shape the live capture observed.
        await DiskCache.shared.save(["p1": note("p1")], forKey: "notes:\(userId)")

        // The refresh round's own fetches fail outright, so the ONLY way the
        // group note could still be on screen afterward is if the cache-first
        // read at the top of this call was never applied to live in-memory
        // state in the first place.
        service.fetchNotesError = AppError.networkError("simulated personal-notes failure")
        service.fetchGroupNotesErrorsByGroup["group-abc"] = AppError.networkError("simulated group-notes failure")
        await vm.refresh(service: service, userId: userId)

        XCTAssertNotNil(vm.notes["g1"],
                        "THE FIX: refresh() must not reapply a poisoned disk-cache read over live in-memory state -- the group note must survive even though the disk cache was personal-only at the moment refresh() started")
        XCTAssertNotNil(vm.notes["p1"])
        XCTAssertFalse(vm.isLoading, "refresh() must still complete (not hang) when both segments fail")
    }
}

// MARK: - 3. End-to-end: Dashboard load, then Notes refresh, still shows group notes (mechanisms 2+3 together)

@MainActor
final class DashboardWritesThenNotesRefreshRegressionTests: XCTestCase {

    private func freshUserId() -> String { "dash-then-notes-\(UUID().uuidString)" }

    /// The literal acceptance-criterion scenario, end to end, using two
    /// separate view-model instances the way the real app does (Dashboard
    /// and Notes are two independent screens/StartupCoordinator-owned view
    /// models, never sharing one instance).
    func test_dashboardLoad_thenNotesRefresh_groupNotesSurvive() async {
        let userId = freshUserId()
        let notesVm = NotesViewModel()
        let notesService = ThrowingTestDataService()
        notesService.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        notesService.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")], nextCursorCreatedAt: "gc1", nextCursorId: "g1", hasMore: false
        )]
        await notesVm.load(service: notesService, userId: userId)
        XCTAssertNotNil(notesVm.notes["g1"], "sanity check: the initial Notes load populates the group note")

        // Dashboard preloads/refreshes on the Home tab -- a routine,
        // unrelated navigation that used to silently clobber the shared
        // "notes:<uid>" key with its own narrower personal-only payload.
        let dashVm = DashboardViewModel()
        let dashService = ThrowingTestDataService()
        dashService.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false
        )]
        await dashVm.load(service: dashService, userId: userId)

        // Now the user pulls to refresh on the Notes screen. Make this
        // round's own fetches fail outright so the test can't pass "by
        // accident" via a fresh successful fetch re-populating the group --
        // if the group note survives, it can only be because neither
        // mechanism clobbered it.
        notesService.fetchNotesError = AppError.networkError("simulated personal-notes failure")
        notesService.fetchGroupNotesErrorsByGroup["group-abc"] = AppError.networkError("simulated group-notes failure")
        await notesVm.refresh(service: notesService, userId: userId)

        XCTAssertNotNil(notesVm.notes["g1"],
                        "THE FIX: a Dashboard load must not clobber the shared cache key, and a Notes refresh must not reapply a clobbered/poisoned disk cache over live in-memory state -- the group note must survive both")
        XCTAssertNotNil(notesVm.notes["p1"])
        XCTAssertFalse(notesVm.isLoading)
    }
}

// MARK: - 4. Cancelled round persists nothing -- Notes (mechanism 3, spec item (c))

@MainActor
final class NotesRefreshCancelledRoundPersistsNothingRegressionTests: XCTestCase {

    private func freshUserId() -> String { "cancel-persist-notes-\(UUID().uuidString)" }

    func test_refresh_everySegmentCancelled_doesNotWriteNotesCacheKeyAtAll() async {
        let userId = freshUserId()
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        service.fetchGroupNotesPageQueue = [NotesPage(
            notes: ["g1": note("g1", groupId: "group-abc")], nextCursorCreatedAt: "gc1", nextCursorId: "g1", hasMore: false
        )]
        await vm.load(service: service, userId: userId)

        // Plant a sentinel directly on disk with a bogus extra entry that no
        // real merged write from this VM could ever produce -- proving,
        // after a cancelled round, that NO write happened at all, as opposed
        // to merely re-persisting equivalent "kept existing" content (which
        // would look identical to "no write" if this test only compared
        // counts).
        var sentinel = vm.notes
        sentinel["sentinel-untouched"] = note("sentinel-untouched")
        await DiskCache.shared.save(sentinel, forKey: "notes:\(userId)")

        service.fetchNotesError = CancellationError()
        service.fetchGroupNotesErrorsByGroup["group-abc"] = CancellationError()
        await vm.refresh(service: service, userId: userId)

        let afterRefresh: [String: FSNote]? = await DiskCache.shared.load([String: FSNote].self, forKey: "notes:\(userId)")
        XCTAssertNotNil(afterRefresh?["sentinel-untouched"],
                        "THE FIX: a refresh round where every segment was cooperatively cancelled must not write \"notes:<uid>\" AT ALL -- the sentinel planted directly on disk (which no real write from this call could produce) must survive untouched")
        XCTAssertFalse(vm.isLoading)
    }

    /// Same proof via URLError(.cancelled), the other real cancellation
    /// shape an in-flight URLSession task throws.
    func test_refresh_segmentThrowsURLErrorCancelled_doesNotWriteNotesCacheKeyAtAll() async {
        let userId = freshUserId()
        let vm = NotesViewModel()
        let service = ThrowingTestDataService()
        service.fetchNotesPageQueue = [NotesPage(
            notes: ["p1": note("p1")], nextCursorCreatedAt: "c1", nextCursorId: "p1", hasMore: false
        )]
        await vm.load(service: service, userId: userId)

        var sentinel = vm.notes
        sentinel["sentinel-untouched"] = note("sentinel-untouched")
        await DiskCache.shared.save(sentinel, forKey: "notes:\(userId)")

        service.fetchNotesError = URLError(.cancelled)
        await vm.refresh(service: service, userId: userId)

        let afterRefresh: [String: FSNote]? = await DiskCache.shared.load([String: FSNote].self, forKey: "notes:\(userId)")
        XCTAssertNotNil(afterRefresh?["sentinel-untouched"],
                        "URLError(.cancelled) must be recognized as a cancellation for the persist-nothing guard too, not just CancellationError")
    }
}

// MARK: - 5. Cancelled round persists nothing -- Account (mechanism 3, mirrors NotesViewModel)

@MainActor
final class AccountLoadCancelledRoundPersistsNothingRegressionTests: XCTestCase {

    private func freshUser(_ label: String) -> FSUser {
        FSUser(user_id: "cancel-persist-acct-\(label)-\(UUID().uuidString)", username: "user-\(label)", email: "\(label)@example.com")
    }

    /// AccountViewModel.load()'s cache-first read (unlike NotesViewModel's,
    /// which this task gated to initial-load-only) unconditionally reapplies
    /// disk state to in-memory on EVERY call, including a refresh -- that's
    /// unchanged, pre-existing, out-of-this-task's-scope behavior (the
    /// security gate reviewed it and found no fail-closed regression). That
    /// means a sentinel planted directly on disk before a cancelled round
    /// gets read right back into memory at the TOP of that same round, so a
    /// naive "disk content unchanged" check can't tell a skipped write apart
    /// from a write that merely re-persists the exact same cache-seeded
    /// value it just read. To actually isolate the write guard, this test
    /// gives ONE fetch (agents) a genuinely NEW, successful result --
    /// legitimately different from whatever's on disk -- while a DIFFERENT
    /// concurrent fetch (notes count) is cancelled, making the overall round
    /// `wasCancelled`. If the write guard is intact, that fresh agents data
    /// must NEVER reach disk this round, even though it's sitting correctly
    /// in `vm.agents` in memory -- proving the guard is round-level (Q14:
    /// an ambiguous round can't partially persist), not per-fetch.
    func test_load_oneFetchCancelled_anotherFetchGenuinelySucceedsWithNewData_freshDataNeverReachesDisk() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("cancel")
        let agentA = FSAgent(id: "agent-a", user_id: user.user_id, role: "r", enabled: true, chats: [])
        service.fetchAgentsResult = [agentA]

        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.agents.map(\.id), ["agent-a"], "sanity check: the first load populates agents")
        let diskAfterRoundOne: [FSAgent]? = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(user.user_id)")
        XCTAssertEqual(diskAfterRoundOne?.map(\.id), ["agent-a"], "sanity check: round 1's real write landed on disk")

        // Round 2: agents genuinely, successfully refreshes to NEW data...
        let agentB = FSAgent(id: "agent-b", user_id: user.user_id, role: "r", enabled: true, chats: [])
        service.fetchAgentsResult = [agentA, agentB]
        // ...while a DIFFERENT concurrent fetch in the same round is
        // cancelled, making the whole round ambiguous.
        service.fetchNotesCountError = CancellationError()
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.agents.map(\.id), ["agent-a", "agent-b"],
                       "the agents fetch's own genuine success must still land in memory -- the round-level cancellation guard doesn't block in-memory state, only the disk write")

        let afterRoundTwo: [FSAgent]? = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(user.user_id)")
        XCTAssertEqual(afterRoundTwo?.map(\.id), ["agent-a"],
                      "THE FIX: a round where ANY fetch was cooperatively cancelled must not write \"agents:<uid>\" (or user:/events:/counts:) AT ALL, even though this round's agents fetch itself genuinely succeeded with new data -- disk must still show round 1's value, not the fresh agent-b")
        XCTAssertFalse(vm.isLoading)
    }
}

// MARK: - 6. loadSubscription() cancellation-vs-genuine-failure (mechanism 5, spec open question 2)

@MainActor
final class LoadSubscriptionCancellationVsFailureRegressionTests: XCTestCase {

    func test_loadSubscription_fetchThrowsCancellationError_doesNotSetSubMsg() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        let uid = "subcancel-\(UUID().uuidString)"
        service.fetchUserSubscriptionError = CancellationError()

        await vm.loadSubscription(userId: uid)

        XCTAssertNil(vm.subMsg,
                     "THE FIX: a cooperatively-cancelled fetchUserSubscription must not surface the 'could not refresh your subscription status' banner -- this is the exact wording-change symptom the user reported live")
        XCTAssertFalse(vm.subLoading)
    }

    func test_loadSubscription_fetchThrowsURLErrorCancelled_doesNotSetSubMsg() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        let uid = "subcancel-\(UUID().uuidString)"
        service.fetchUserSubscriptionError = URLError(.cancelled)

        await vm.loadSubscription(userId: uid)

        XCTAssertNil(vm.subMsg, "URLError(.cancelled) must be recognized as a cancellation, not a genuine network failure -- must not surface subMsg")
    }

    /// Regression guard: proves the cancellation fix didn't overcorrect into
    /// silencing real failures too -- mirrors
    /// AccountRefreshCancellationVsFailureRegressionTests' identical guard
    /// for load()'s statsMsg.
    func test_loadSubscription_fetchThrowsGenuineFailure_stillSetsSubMsg() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        let uid = "subcancel-\(UUID().uuidString)"
        service.fetchUserSubscriptionError = AppError.networkError("simulated genuine subscription failure")

        await vm.loadSubscription(userId: uid)

        XCTAssertEqual(vm.subMsg, "Could not refresh your subscription status. Pull down to refresh and try again.",
                       "a genuine (non-cancellation) fetch failure must still surface the exact banner wording the user reported")
        XCTAssertFalse(vm.subLoading)
    }

    /// A generic URLError that ISN'T .cancelled (e.g. a real timeout) must
    /// still be treated as a genuine failure.
    func test_loadSubscription_fetchThrowsURLErrorTimedOut_stillSetsSubMsg() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        let uid = "subcancel-\(UUID().uuidString)"
        service.fetchUserSubscriptionError = URLError(.timedOut)

        await vm.loadSubscription(userId: uid)

        XCTAssertNotNil(vm.subMsg, "URLError(.timedOut) is a genuine network failure, not a cancellation -- must still surface subMsg")
    }
}

// MARK: - 7. loadSubscription() in-flight de-duplication (the second, newly-discovered root cause)

@MainActor
final class LoadSubscriptionInFlightDeduplicationRegressionTests: XCTestCase {

    /// Reproduces exactly what frontend step 2's live capture found:
    /// AccountView's independent `.task` and `.refreshable` (plus this
    /// class's own mutation-resync callers) firing loadSubscription()
    /// concurrently -- only 1 of 8 device-observed requests ever reached
    /// origin in one capture window, the rest blocked by Cloudflare-edge
    /// 403s from the resulting request burst.
    func test_concurrentTaskAndRefreshableTriggeredCalls_collapseIntoOneInFlightRequest() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        let uid = "subdedup-\(UUID().uuidString)"
        service.fetchUserSubscriptionDelayNanoseconds = 200_000_000
        // Isolate this test to loadSubscription's OWN fetchUserSubscription
        // call: with no active plan (MockDataService's default), it also
        // walks fetchContacts' friends to build `joinablePlans`, calling
        // fetchUserSubscription again per friend -- irrelevant noise for
        // this test's actual subject (the in-flight guard), so make that
        // walk a no-op the same way a genuine transient failure would.
        service.fetchContactsError = AppError.networkError("not exercised by this test")

        async let first: Void = vm.loadSubscription(userId: uid)
        // Let the first call actually start (and land inside its in-flight
        // window) before firing the second -- a genuine overlap, not a
        // same-instant race that could pass by luck either way.
        try? await Task.sleep(nanoseconds: 50_000_000)
        async let second: Void = vm.loadSubscription(userId: uid)
        _ = await (first, second)

        XCTAssertEqual(service.fetchUserSubscriptionCallCount, 1,
                       "THE FIX: a second loadSubscription() call landing while one is already in flight must collapse into the existing call, not fire its own concurrent network request")
        XCTAssertFalse(vm.subLoading)
    }

    /// Regression guard: the guard must only collapse calls that GENUINELY
    /// overlap -- two fully sequential calls (the first already finished
    /// before the second starts) must each still fire their own request, or
    /// a real explicit pull-to-refresh after a stale subscription state
    /// would get silently dropped.
    func test_sequentialCalls_afterTheFirstCompletes_eachStillFiresItsOwnRequest() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        let uid = "subdedup-seq-\(UUID().uuidString)"
        // Same isolation as the test above -- irrelevant to this test's
        // subject (whether two non-overlapping calls each fire their own
        // request).
        service.fetchContactsError = AppError.networkError("not exercised by this test")

        await vm.loadSubscription(userId: uid)
        await vm.loadSubscription(userId: uid)

        XCTAssertEqual(service.fetchUserSubscriptionCallCount, 2,
                       "two fully sequential (non-overlapping) calls must each still fire their own request -- the in-flight guard must not collapse calls that never actually overlapped")
    }
}

// MARK: - 8. fetchHeartbeats decode-failure handling (mechanism 6, spec scope item 3, Q27)

@MainActor
final class AccountEventsCacheClobberDiskWriteRegressionTests: XCTestCase {

    private func freshUser(_ label: String) -> FSUser {
        FSUser(user_id: "events-diskwrite-\(label)-\(UUID().uuidString)", username: "user-\(label)", email: "\(label)@example.com")
    }

    /// Extends PullToRefreshCacheClobberSweepRegressionTests' 2e coverage
    /// (which only checks in-memory `vm.events`) with the disk-cache write
    /// assertion this task's spec scope item 3 is actually about -- "close
    /// the empty-in-memory fallback hole so a failed/cancelled heartbeats
    /// walk can never persist [] as if proven." NetworkServiceGetErrorHandlingTests
    /// / AccountEventsDecodeFailureRegressionTests.swift's corrected
    /// `test_fetchHeartbeats_genuinelyMalformedShape_decodeFails_throwsAndFiresBeacon`
    /// proves the network layer itself throws rather than fabricating `[]`;
    /// this proves what AccountViewModel.load() does with that throw once it
    /// reaches the splice/persist layer.
    func test_load_soleAgentsHeartbeatsFetchFails_diskCacheKeepsPreviouslyProvenEvents_neverFabricatedEmpty() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("solo")
        let agent = FSAgent(id: "agent-solo", user_id: user.user_id, role: "r", enabled: true, chats: [])
        service.fetchAgentsResult = [agent]
        service.fetchHeartbeatsResultsByAgent["agent-solo"] = [FSHeartbeat(id: "hb-1", agent_id: "agent-solo", user_id: user.user_id, prompt: "p1")]
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.events.map(\.id), ["hb-1"], "sanity check: the first load populates events")

        // The exact decode-failure shape NetworkService+Agents.fetchHeartbeats
        // now throws instead of returning `?? []`.
        service.fetchHeartbeatsResultsByAgent["agent-solo"] = nil
        service.fetchHeartbeatsErrorsByAgent["agent-solo"] = AppError.networkError("Could not read this agent's events.")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.events.map(\.id), ["hb-1"],
                       "a failed heartbeats fetch must fall back to the agent's own previously-proven events, not fabricate an empty result")
        XCTAssertNotNil(vm.statsMsg, "a genuine (non-cancellation) heartbeats decode failure must still surface statsMsg")

        let cachedEvents: [FSHeartbeat]? = await DiskCache.shared.load([FSHeartbeat].self, forKey: "events:\(user.user_id)")
        XCTAssertEqual(cachedEvents?.map(\.id), ["hb-1"],
                       "THE FIX: the disk cache write must persist the preserved, previously-proven event -- never a fabricated empty result from the failed fetch")
    }

    /// Isolates THIS task's specific incremental change (as opposed to the
    /// test above, which also passes under the prior task's older logic
    /// since its one agent already has a baseline).
    ///
    /// CORRECTED (task 20260910-refresh-clobber-live-rootcause, testing-gate
    /// bounce back to frontend step 3): this test originally asserted the
    /// opposite of what's below -- that agent-b's no-baseline failure must
    /// discard the WHOLE round's events update, blocking agent-a's own
    /// genuinely fresh success from landing at all. That assertion was
    /// itself the bug: it was produced by a round-level `eventsUsable =
    /// false` flag that gated the single, whole-round `events = allEvents`
    /// assignment, so one agent's no-baseline failure discarded a completely
    /// different agent's real, successfully-fetched data in the same round
    /// -- which broke a still-valid prior-task test
    /// (AccountEventsDecodeFailureRegressionTests.swift's
    /// test_load_partialHeartbeatsFailure_stillShowsSucceedingAgentsRealEvents,
    /// proving exactly the opposite property). The fix tracks unprovenness
    /// per-agent instead: agent-b's failure (no baseline to fall back on)
    /// contributes nothing to `allEvents` for agent-b specifically -- which
    /// is already the honest state, since there was never a known-good
    /// baseline for agent-b to lose -- while agent-a's genuinely fresh
    /// success still commits normally. `statsMsg` still surfaces because
    /// agent-b's fetch was a genuine (non-cancellation) failure.
    func test_load_multiAgent_oneAgentFreshSuccess_anotherNewAgentNoBaselineFails_thatAgentSuccessStillCommits_notDiscardedRoundWide() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("multi")
        let agentA = FSAgent(id: "agent-a", user_id: user.user_id, role: "r", enabled: true, chats: [])
        service.fetchAgentsResult = [agentA]
        service.fetchHeartbeatsResultsByAgent["agent-a"] = [FSHeartbeat(id: "hb-a1", agent_id: "agent-a", user_id: user.user_id, prompt: "p1")]
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.events.map(\.id), ["hb-a1"], "sanity check: round 1 populates agent-a's baseline event")

        // Round 2: a brand-new agent-b appears (e.g. the user just created
        // it) with NO prior baseline, and its heartbeats fetch fails; agent-a
        // ALSO genuinely, successfully refreshes to different fresh data.
        let agentB = FSAgent(id: "agent-b", user_id: user.user_id, role: "r", enabled: true, chats: [])
        service.fetchAgentsResult = [agentA, agentB]
        service.fetchHeartbeatsResultsByAgent["agent-a"] = [FSHeartbeat(id: "hb-a2", agent_id: "agent-a", user_id: user.user_id, prompt: "p2")]
        service.fetchHeartbeatsErrorsByAgent["agent-b"] = AppError.networkError("Could not read this agent's events.")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.events.map(\.id), ["hb-a2"],
                       "THE FIX: agent-a's genuinely fresh success must land even though agent-b (no baseline) failed in the same round -- agent-b's failure only excludes agent-b's own contribution, which was already unproven either way")
        XCTAssertNotNil(vm.statsMsg, "agent-b's genuine (non-cancellation) failure must still surface statsMsg")

        let cachedEvents: [FSHeartbeat]? = await DiskCache.shared.load([FSHeartbeat].self, forKey: "events:\(user.user_id)")
        XCTAssertEqual(cachedEvents?.map(\.id), ["hb-a2"],
                       "the disk cache must match the committed in-memory state (agent-a's fresh hb-a2), not a stale round-wide-discarded value")
    }
}
