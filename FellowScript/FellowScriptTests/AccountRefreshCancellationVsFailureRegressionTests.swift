// AccountRefreshCancellationVsFailureRegressionTests.swift — testing-gate
// coverage for task 20260909-notes-account-refresh-data-loss, step 6,
// proving the frontend gate's step 4 fixes to AccountViewModel.load():
//
//   1. Cancellation-vs-genuine-failure distinction: every one of the 7
//      concurrent fetches' catch blocks (plus the per-agent fetchHeartbeats
//      walk) used to treat ANY thrown error identically -- including
//      Swift/SwiftUI cooperatively cancelling the underlying Task (a normal
//      part of `.refreshable`'s lifecycle) -- as a genuine failure feeding
//      `statsFailed`, unconditionally painting the "We couldn't load some
//      of your account data..." banner from the spec's own screenshot. The
//      fix adds `isCancellation(_:)` and a separate `wasCancelled` flag so a
//      cancellation is now treated as inconclusive (nothing shown, existing
//      data left alone) rather than a false failure banner. This is
//      specifically NOT the same bug PullToRefreshCacheClobberSweepRegressionTests
//      / AccountStatsLoadRaceRegressionTests already cover -- those prove a
//      genuine throw still surfaces statsMsg and doesn't wipe cached data;
//      this proves a COOPERATIVE CANCELLATION must NOT surface statsMsg at
//      all, which those suites never exercised (they only ever threw
//      AppError, never CancellationError/URLError(.cancelled)).
//
//   2. fetchFriendRequests concurrency fix: it was declared as a plain
//      sequential call issued only after the other 5 of the "7 concurrent
//      fetches" had already resolved, instead of a real `async let`
//      alongside them -- needlessly lengthening every load()/refresh call
//      and making a cooperative mid-flight cancellation more likely in
//      practice. Now promoted to a genuine `async let`.
//
// Uses ThrowingTestDataService (AppStateAuthAccountTests.swift), extended in
// this task's testing step with a `fetchFriendRequestsDelayNanoseconds` seam
// (mirroring the existing fetchAgentsDelayNanoseconds/fetchNotesCountDelayNanoseconds
// pattern) to prove #2 via real wall-clock overlap.

import XCTest
@testable import FellowScript

@MainActor
final class AccountRefreshCancellationVsFailureRegressionTests: XCTestCase {

    private func makeUser(_ id: String) -> FSUser {
        FSUser(user_id: id, username: "alice", email: "alice@example.com")
    }

    // MARK: 1 — a cooperatively-cancelled fetch must NOT surface the failure banner

    /// The actual reported live symptom for the Account screen: "the user
    /// always gets an error message saying the app could not refresh their
    /// data" on pull-to-refresh. `CancellationError` is exactly what a
    /// `.refreshable` Task getting superseded/torn down throws -- this
    /// proves that specific, routine shape no longer trips `statsMsg`.
    func test_load_fetchAgentsThrowsCancellationError_doesNotSetStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-cancel-vs-fail-1")
        let service = ThrowingTestDataService()
        service.fetchAgentsError = CancellationError()

        await vm.load(service: service, user: user)

        XCTAssertNil(vm.statsMsg,
                      "THE FIX: a cooperatively-cancelled fetch (CancellationError) must not be treated as a genuine failure -- it must not surface the 'couldn't load your data' banner")
        XCTAssertFalse(vm.isLoading, "load() must still complete (not hang) when a fetch is cancelled")
    }

    /// URLError(.cancelled) is the other real shape a cancelled in-flight
    /// URLSession task throws (as opposed to Swift's own CancellationError)
    /// -- `isCancellation(_:)` explicitly checks for both.
    func test_load_fetchAgentsThrowsURLErrorCancelled_doesNotSetStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-cancel-vs-fail-2")
        let service = ThrowingTestDataService()
        service.fetchAgentsError = URLError(.cancelled)

        await vm.load(service: service, user: user)

        XCTAssertNil(vm.statsMsg,
                      "URLError(.cancelled) must be recognized as a cancellation, not a genuine network failure -- must not surface statsMsg")
    }

    /// Same distinction proven for fetchFriendRequests specifically (the
    /// other fetch this exact task's fix touched), not just fetchAgents.
    func test_load_fetchFriendRequestsThrowsCancellationError_doesNotSetStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-cancel-vs-fail-3")
        let service = ThrowingTestDataService()
        service.fetchFriendRequestsError = CancellationError()

        await vm.load(service: service, user: user)

        XCTAssertNil(vm.statsMsg, "a cancelled fetchFriendRequests must not surface statsMsg either")
    }

    /// Same distinction proven for the per-agent fetchHeartbeats withTaskGroup
    /// walk -- a third, independently-fixed catch site per the frontend
    /// gate's summary.
    func test_load_perAgentHeartbeatsFetchThrowsCancellationError_doesNotSetStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-cancel-vs-fail-4")
        let service = ThrowingTestDataService()
        let agent = FSAgent(id: "agent-a", user_id: user.user_id, role: "r", enabled: true, chats: [])
        service.fetchAgentsResult = [agent]
        service.fetchHeartbeatsErrorsByAgent["agent-a"] = CancellationError()

        await vm.load(service: service, user: user)

        XCTAssertNil(vm.statsMsg, "a cancelled per-agent heartbeats fetch must not surface statsMsg")
    }

    // MARK: 2 — regression guard: a GENUINE (non-cancellation) failure must
    // still surface the banner -- proves the cancellation fix didn't
    // overcorrect into silencing real failures too.

    func test_load_fetchAgentsThrowsGenuineNetworkError_stillSetsStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-cancel-vs-fail-5")
        let service = ThrowingTestDataService()
        service.fetchAgentsError = AppError.networkError("simulated genuine agents failure")

        await vm.load(service: service, user: user)

        XCTAssertNotNil(vm.statsMsg,
                         "a genuine (non-cancellation) fetch failure must still surface statsMsg -- the cancellation fix must not silence real failures")
    }

    /// A generic URLError that ISN'T .cancelled (e.g. a real timeout) must
    /// still be treated as a genuine failure, not swept into the
    /// cancellation-is-inconclusive bucket.
    func test_load_fetchAgentsThrowsURLErrorTimedOut_stillSetsStatsMsg() async {
        let vm = AccountViewModel()
        let user = makeUser("account-cancel-vs-fail-6")
        let service = ThrowingTestDataService()
        service.fetchAgentsError = URLError(.timedOut)

        await vm.load(service: service, user: user)

        XCTAssertNotNil(vm.statsMsg,
                         "URLError(.timedOut) is a genuine network failure, not a cancellation -- must still surface statsMsg")
    }

    // MARK: 3 — documented interaction: if one fetch is merely cancelled while
    // a DIFFERENT concurrent fetch genuinely fails in the same round,
    // `wasCancelled` intentionally wins (per the production code's own Q14
    // fail-closed rationale: an ambiguous round can't honestly assert either
    // "your data is fine" or "we couldn't load it"). This is a deliberate
    // design choice flagged during the security gate's review (non-blocking:
    // affects only error-message visibility, not data integrity/auth/PII),
    // not an unintended regression -- this test documents the actual,
    // intended current behavior rather than silently leaving it unverified.
    func test_load_oneFetchCancelled_anotherFetchGenuinelyFails_bannerIsSuppressed_byDesign() async {
        let vm = AccountViewModel()
        let user = makeUser("account-cancel-vs-fail-7")
        let service = ThrowingTestDataService()
        service.fetchAgentsError = CancellationError()
        service.fetchNotesCountError = AppError.networkError("simulated genuine notes-count failure")

        await vm.load(service: service, user: user)

        XCTAssertNil(vm.statsMsg,
                      "documented current behavior: wasCancelled wins over statsFailed when both are set in the same round, " +
                      "so a genuine failure alongside an unrelated cancellation does not surface the banner this round")
    }

    // MARK: 4 — fetchFriendRequests concurrency fix

    /// Before the fix, fetchFriendRequests was issued (and awaited) only
    /// after fetchUser/fetchAgents/fetchNotesCount/fetchHighlights/fetchUsage
    /// had ALL already resolved -- i.e. its own network call didn't even
    /// START until they finished, making the two delays additive. After the
    /// fix (a real `async let` alongside them), its call starts immediately
    /// and overlaps with the others, so two 300ms delays should cost ~300ms
    /// total, not ~600ms+.
    func test_load_fetchFriendRequests_runsConcurrentlyWithOtherFetches_notSeriallyAfterThem() async {
        let vm = AccountViewModel()
        let user = makeUser("account-concurrency-1")
        let service = ThrowingTestDataService()
        service.fetchAgentsDelayNanoseconds = 300_000_000
        service.fetchFriendRequestsDelayNanoseconds = 300_000_000

        let start = Date()
        await vm.load(service: service, user: user)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.55,
                           "THE FIX: fetchFriendRequests must run CONCURRENTLY with fetchAgents (both delayed 300ms) -- total load() time should be ~300ms, " +
                           "not ~600ms+, which is what the old serial-after-the-other-5-fetches bug would produce")
    }

    /// Functional regression guard alongside the timing proof above: the
    /// concurrency fix must not have broken fetchFriendRequests' own result
    /// actually landing.
    func test_load_fetchFriendRequests_stillPopulatesResult_afterConcurrencyFix() async {
        let vm = AccountViewModel()
        let user = makeUser("account-concurrency-2")
        let service = ThrowingTestDataService()
        service.fetchFriendRequestsResult = [(id: "req-1", username: "dana", profile_photo_url: nil)]

        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.friendRequests.map(\.id), ["req-1"],
                        "fetchFriendRequests' real result must still land in friendRequests after being promoted to a concurrent async let")
        XCTAssertEqual(service.fetchFriendRequestsCallCount, 1)
    }
}
