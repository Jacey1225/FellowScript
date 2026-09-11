// AccountEventsSupersededRoundRegressionTests.swift
// task: 20260910-account-events-refresh-regression (independent second-
// opinion pass after build 43 still showed zero Account Events live).
//
// The live mechanism, reconstructed from production nginx/uvicorn logs plus
// a verified decode of the account's real heartbeat payload:
//   1. AccountView's `.task` starts a load() round (gen 1). All 7 fetches
//      succeed; the heartbeats call returns a 200 with the account's 2 real
//      events ~1.5s later.
//   2. Before that round reaches its commit point, a SECOND load() starts
//      (gen 2) -- a `.refreshable` pull whose Task is cooperatively
//      cancelled within milliseconds. Every one of its fetches throws
//      URLError.cancelled instantly (an already-cancelled Task's URLSession
//      call never sends a request), so it commits nothing, writes nothing,
//      and flips `isLoading` false via its own `defer`.
//   3. Round 1 then arrives at `guard generation == loadGeneration` -- and
//      because round 2 bumped `loadGeneration`, round 1 throws its real
//      events away. Nothing ever commits `events`; `isLoading` is false; no
//      alert (cancellation never sets statsMsg); no cache write (cancelled
//      round). The Events section renders "No events yet" on a fresh view
//      model every single launch, exactly the user's screenshot.
//
// These tests reproduce that interleaving against the view model directly
// and pin the three properties the fix establishes.

import XCTest
@testable import FellowScript

@MainActor
final class AccountEventsSupersededRoundRegressionTests: XCTestCase {

    private func makeUser(_ id: String) -> FSUser {
        FSUser(user_id: id, username: "alice", email: "alice@example.com")
    }

    /// A service standing in for the "phantom" round: every fetch behaves the
    /// way URLSession does inside an already-cancelled Task -- throws
    /// URLError(.cancelled) immediately, sending nothing.
    private func cancelledEverywhereService() -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        let cancelled = URLError(.cancelled)
        s.fetchUserError           = cancelled
        s.fetchAgentsError         = cancelled
        s.fetchNotesCountError     = cancelled
        s.fetchHighlightsError     = cancelled
        s.fetchContactsError       = cancelled
        s.fetchFriendRequestsError = cancelled
        return s
    }

    private func realService(userId: String, agentDelay: UInt64, heartbeatsDelay: UInt64) -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        let agent = FSAgent(id: "agent-live-1", user_id: userId, name: "Devotions Agent", role: "guide", enabled: true, chats: [])
        s.fetchAgentsResult = [agent]
        s.fetchAgentsDelayNanoseconds = agentDelay
        s.fetchHeartbeatsResultsByAgent["agent-live-1"] = [
            FSHeartbeat(id: "hb-1", agent_id: "agent-live-1", user_id: userId,
                        timestamps: Array(repeating: "10:00", count: 31), prompt: "Morning devotion", group_id: nil),
            FSHeartbeat(id: "hb-2", agent_id: "agent-live-1", user_id: userId,
                        timestamps: Array(repeating: "10:00", count: 31), prompt: "Group devotion", group_id: "g1", notes_public: true),
        ]
        s.fetchHeartbeatsDelayNanoseconds = heartbeatsDelay
        return s
    }

    // THE BUG: a fast-cancelled newer round must not make the in-flight
    // older round discard its real, fully-fetched events.
    func test_load_inFlightRealRound_survivesNewerInstantlyCancelledRound_eventsStillCommit() async throws {
        let vm = AccountViewModel()
        let user = makeUser("account-events-superseded-user-1")
        let real = realService(userId: user.user_id, agentDelay: 250_000_000, heartbeatsDelay: 250_000_000)

        let realRound = Task { await vm.load(service: real, user: user) }
        try await Task.sleep(nanoseconds: 60_000_000)   // real round is mid-flight

        // The phantom: starts after the real round, finishes instantly with
        // every fetch cancelled, commits nothing.
        await vm.load(service: cancelledEverywhereService(), user: user)
        XCTAssertTrue(vm.events.isEmpty, "sanity: the cancelled round itself must not fabricate events")
        XCTAssertNil(vm.statsMsg, "a cancelled round must not raise the failure alert (pre-existing contract)")

        await realRound.value
        XCTAssertEqual(vm.events.map(\.id), ["hb-1", "hb-2"],
                       "THE FIX: the older round's real heartbeats must still commit -- pre-fix, the cancelled newer round bumped the generation and the real round silently discarded its result at the commit guard, leaving events empty forever")
        XCTAssertEqual(vm.agents.map(\.id), ["agent-live-1"])
        XCTAssertTrue(vm.eventsLoaded, "a cleanly completed walk must mark events as loaded")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.statsMsg)

        let cached: [FSHeartbeat]? = await DiskCache.shared.load([FSHeartbeat].self, forKey: "events:\(user.user_id)")
        XCTAssertEqual(cached?.map(\.id), ["hb-1", "hb-2"],
                       "the real round's commit must also reach disk so the next cold launch's cache-first read isn't empty")
    }

    // While the older real round is still running, the cancelled newer
    // round's own `defer` must not flip isLoading false -- the view would
    // otherwise fall out of the loading row into an empty-state copy for
    // the remainder of the real round.
    func test_load_isLoadingStaysTrue_whileOlderRoundStillInFlight_afterNewerRoundCancelled() async throws {
        let vm = AccountViewModel()
        let user = makeUser("account-events-superseded-user-2")
        let real = realService(userId: user.user_id, agentDelay: 300_000_000, heartbeatsDelay: 300_000_000)

        let realRound = Task { await vm.load(service: real, user: user) }
        try await Task.sleep(nanoseconds: 60_000_000)
        await vm.load(service: cancelledEverywhereService(), user: user)

        XCTAssertTrue(vm.isLoading,
                      "THE FIX: isLoading must reflect every round still in flight, not just the most recently started one")
        await realRound.value
        XCTAssertFalse(vm.isLoading, "once the last live round finishes, isLoading must clear")
    }

    // THE BUG (security-gate bounce after this file's own fix shipped): a
    // NEWER round that hits a genuine, non-cancellation failure (e.g. the
    // fetchHeartbeats decode-failure-throws path the spec calls out) must
    // not be able to claim `committedGeneration` either -- only cancellation
    // was excluded before this fix, so a genuinely-failing newer round could
    // still discard an older, in-flight round's real, successfully-fetched
    // events, reproducing the identical "events permanently empty" symptom
    // via a different trigger.
    func test_load_inFlightRealRound_survivesNewerRoundsGenuineNonCancellationFailure_eventsStillCommit() async throws {
        let vm = AccountViewModel()
        let user = makeUser("account-events-superseded-user-8")
        let real = realService(userId: user.user_id, agentDelay: 250_000_000, heartbeatsDelay: 250_000_000)

        let realRound = Task { await vm.load(service: real, user: user) }
        try await Task.sleep(nanoseconds: 60_000_000)   // real round is mid-flight

        // The newer round: its own agent list fetches fine, but its
        // heartbeats fetch genuinely throws (not a cancellation) -- the
        // decode-failure-throws shape the spec explicitly calls out as an
        // unverified gap. Finishes fast, well before the older real round.
        let failing = realService(userId: user.user_id, agentDelay: 0, heartbeatsDelay: 0)
        failing.fetchHeartbeatsErrorsByAgent["agent-live-1"] = AppError.networkError("simulated decode failure")
        await vm.load(service: failing, user: user)
        XCTAssertNotNil(vm.statsMsg, "sanity: the genuine failure must raise the existing failure alert")

        await realRound.value
        XCTAssertEqual(vm.events.map(\.id), ["hb-1", "hb-2"],
                       "THE FIX: the older round's real heartbeats must still commit -- pre-fix, a newer round's genuine (non-cancellation) failure advanced committedGeneration exactly like a real commit would, and the real round silently discarded its result at the commit guard")
        XCTAssertTrue(vm.eventsLoaded, "a cleanly completed walk must mark events as loaded")
        XCTAssertFalse(vm.isLoading)

        let cached: [FSHeartbeat]? = await DiskCache.shared.load([FSHeartbeat].self, forKey: "events:\(user.user_id)")
        XCTAssertEqual(cached?.map(\.id), ["hb-1", "hb-2"],
                       "the real round's commit must also reach disk so the next cold launch's cache-first read isn't empty")
    }

    // The pre-existing contract must survive: when a NEWER round genuinely
    // commits first, a slower OLDER round finishing later must not clobber
    // it (AccountStatsLoadRaceRegressionTests covers the stats side; this
    // pins it for events specifically).
    func test_load_slowerOlderRound_stillCannotClobber_newerRoundThatGenuinelyCommittedFirst() async throws {
        let vm = AccountViewModel()
        let user = makeUser("account-events-superseded-user-3")
        let slowStale = realService(userId: user.user_id, agentDelay: 400_000_000, heartbeatsDelay: 400_000_000)
        slowStale.fetchHeartbeatsResultsByAgent["agent-live-1"] = [
            FSHeartbeat(id: "hb-stale", agent_id: "agent-live-1", user_id: user.user_id,
                        timestamps: Array(repeating: nil, count: 31), prompt: "stale", group_id: nil)
        ]
        let fastFresh = realService(userId: user.user_id, agentDelay: 0, heartbeatsDelay: 0)

        let staleRound = Task { await vm.load(service: slowStale, user: user) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.load(service: fastFresh, user: user)
        XCTAssertEqual(vm.events.map(\.id), ["hb-1", "hb-2"], "the fresh round commits first")

        await staleRound.value
        XCTAssertEqual(vm.events.map(\.id), ["hb-1", "hb-2"],
                       "the slower, older round finishing after a newer genuine commit must still be discarded -- the original clobber protection is intact")
    }

    // A single round whose heartbeats walk was cancelled with no cached
    // baseline leaves events empty, but must NOT claim to have established
    // emptiness -- that's the difference between "No events yet" and
    // "haven't loaded yet" in the view.
    func test_load_cancelledHeartbeatsWalk_noBaseline_doesNotMarkEventsLoaded_andNoAlert() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-superseded-user-4")
        let s = realService(userId: user.user_id, agentDelay: 0, heartbeatsDelay: 0)
        s.fetchHeartbeatsErrorsByAgent["agent-live-1"] = URLError(.cancelled)

        await vm.load(service: s, user: user)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertFalse(vm.eventsLoaded,
                       "a cancelled walk proves nothing about the account's events -- the view must not render the confirmed-empty copy off this state")
        XCTAssertNil(vm.statsMsg, "cancellation is not a genuine failure (pre-existing contract)")
        XCTAssertFalse(vm.isLoading)
    }

    // A genuinely failed walk with no baseline: still not "loaded", and the
    // existing failure alert still fires.
    func test_load_failedHeartbeatsWalk_noBaseline_doesNotMarkEventsLoaded_butStillAlerts() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-superseded-user-5")
        let s = realService(userId: user.user_id, agentDelay: 0, heartbeatsDelay: 0)
        s.fetchHeartbeatsErrorsByAgent["agent-live-1"] = AppError.networkError("simulated 403")

        await vm.load(service: s, user: user)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertFalse(vm.eventsLoaded)
        XCTAssertNotNil(vm.statsMsg, "a genuine failure must still surface the existing alert")
    }

    // A clean round that finds genuinely zero events IS proof of emptiness.
    func test_load_cleanWalk_genuinelyZeroEvents_marksEventsLoaded() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-superseded-user-6")
        let s = realService(userId: user.user_id, agentDelay: 0, heartbeatsDelay: 0)
        s.fetchHeartbeatsResultsByAgent["agent-live-1"] = []

        await vm.load(service: s, user: user)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertTrue(vm.eventsLoaded, "a clean, genuinely-empty walk is the one state that may render \"No events yet\"")
        XCTAssertNil(vm.statsMsg)
    }

    // An account with no agents at all has, trivially, no events -- that
    // must still count as loaded rather than sticking on the "haven't loaded"
    // copy forever.
    func test_load_noAgents_marksEventsLoaded() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-superseded-user-7")
        let s = ThrowingTestDataService()
        s.fetchAgentsResult = []

        await vm.load(service: s, user: user)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertTrue(vm.eventsLoaded)
    }
}

/// Source-structural guard for the new view branch, matching the style of
/// AccountEventsSectionLoadingBranchRegressionTests: the "haven't loaded yet"
/// copy must sit between the loading row and the confirmed-empty copy, and
/// must render distinctly from both.
final class AccountEventsSectionNotYetLoadedBranchRegressionTests: XCTestCase {
    private func eventsSectionSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Account/AccountView+Events.swift")
        let full = try String(contentsOf: file, encoding: .utf8)
        guard let start = full.range(of: "var eventsSection: some View {"),
              let end = full.range(of: "func agentName(for agentId: String)") else {
            XCTFail("eventsSection markers not found"); return ""
        }
        return String(full[start.lowerBound..<end.lowerBound])
    }

    func test_eventsSection_notYetLoadedBranch_sitsBetweenLoadingAndConfirmedEmpty() throws {
        let source = try eventsSectionSource()
        guard let loading = source.range(of: "if vm.events.isEmpty && vm.isLoading {"),
              let notLoaded = source.range(of: "} else if vm.events.isEmpty && !vm.eventsLoaded {"),
              let empty = source.range(of: "} else if vm.events.isEmpty {") else {
            XCTFail("eventsSection must branch loading -> not-yet-loaded (`!vm.eventsLoaded`) -> confirmed-empty, in that order")
            return
        }
        XCTAssertTrue(loading.lowerBound < notLoaded.lowerBound && notLoaded.lowerBound < empty.lowerBound)
        let branch = String(source[notLoaded.upperBound..<empty.lowerBound])
        XCTAssertTrue(branch.contains("Pull down to refresh"), "the not-yet-loaded copy must point at the existing retry path")
        XCTAssertFalse(branch.contains("No events yet"), "must not reuse the confirmed-empty copy")
        XCTAssertFalse(branch.contains("ProgressView"), "must not pretend a round is still running")
    }
}
