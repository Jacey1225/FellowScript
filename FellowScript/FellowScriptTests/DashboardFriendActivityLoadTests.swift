// DashboardFriendActivityLoadTests.swift — coverage for task
// 20260826-friend-activity-dashboard-implementation, testing step 5
// (re-entry pass): the changed DashboardViewModel.load() path.
//
// frontend step 3 added a 6th concurrent fetch (`fetchFriendActivityTask`)
// to DashboardViewModel.load()'s existing 5-way `async let` group, plus a
// cache-first DiskCache warm-start for `friendActivity` alongside the
// pre-existing notes/highlights/agents/lastAgentMsg ones. This file proves,
// using the shared ThrowingTestDataService double (defined in
// AppStateAuthAccountTests.swift, extended there in this pass with a
// controllable `fetchFriendActivityResult`/`fetchFriendActivityDelayNanoseconds`/
// `fetchFriendActivityCallCount` seam mirroring the existing fetchContacts
// seam):
//
//   1. fetchFriendActivity is actually wired into load() — after a real
//      load() call, vm.friendActivity reflects exactly what the service
//      returned (not left at its `.empty` default), and it's called exactly
//      once (no duplicate fetch).
//   2. The empty-state cases the acceptance criteria call out explicitly —
//      no friends at all, and friends with zero tracked activity — both
//      come through vm.friendActivity unchanged from what the backend
//      reported (nothing invented/defaulted client-side), and in
//      particular vm.friendActivity.check_in stays nil so DashboardView's
//      `if let checkIn = vm.friendActivity.check_in` correctly omits the
//      CheckInRow rather than rendering a bogus nudge.
//   3. A service failure (fetchFriendActivity throws) is handled the same
//      way every other load() source already is (`try?` + `?? .empty`
//      fallback) — load() must not crash or leave friendActivity in a
//      stale/undefined state.
//   4. Cache-first warm start: a prior successful load() persists
//      friendActivity to DiskCache (`friendActivity:<userId>`), and a
//      SECOND DashboardViewModel loading the same userId shows that cached
//      feed immediately (before its own, deliberately delayed, fresh fetch
//      resolves) — mirrors this file's sibling StartupCoordinatorTests'
//      real-time-wait technique for proving cache-first behavior rather
//      than just reading the source.

import XCTest
@testable import FellowScript

@MainActor
final class DashboardFriendActivityLoadTests: XCTestCase {

    /// A fresh, per-test user id — DashboardViewModel.load() is cache-first
    /// via the real on-disk DiskCache.shared, keyed by userId, so it
    /// persists across test runs in the same simulator container. A fresh
    /// id per test keeps each one's cache state genuinely empty (same
    /// rationale as StartupCoordinatorTests.freshUserId()).
    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    // MARK: 1 — fetchFriendActivity is wired into the load() fetch group

    func test_load_populatesFriendActivity_fromService_calledExactlyOnce() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        await vm.load(service: service, userId: userId)

        XCTAssertEqual(service.fetchFriendActivityCallCount, 1,
                        "load() must fetch friend activity exactly once, not zero (unwired) or more (duplicate fetch)")
        XCTAssertEqual(vm.friendActivity, MockDataService.mockFriendActivity,
                        "vm.friendActivity must be populated from exactly what the service returned")
        XCTAssertFalse(vm.friendActivity.friends_active.isEmpty)
        XCTAssertNotNil(vm.friendActivity.check_in)
    }

    // MARK: 2 — empty states the acceptance criteria explicitly call out

    func test_load_noFriends_friendActivityIsEmpty_andCheckInIsNil() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        service.fetchFriendActivityResult = .empty
        let userId = freshUserId()

        await vm.load(service: service, userId: userId)

        XCTAssertEqual(vm.friendActivity, FSFriendActivityFeed.empty)
        XCTAssertTrue(vm.friendActivity.friends_active.isEmpty)
        XCTAssertNil(vm.friendActivity.check_in,
                      "no friends must never produce a check-in candidate")
    }

    func test_load_friendsWithNoTrackedActivity_stillPopulatesFriendsActive_withNilLastActiveAndNilPreview() async {
        // Mirrors the real backend contract (backend step 2): a friend with
        // zero user_activity rows still appears in friends_active with
        // last_active_at/note_preview both nil, and can still be a (nil-days)
        // check_in candidate — this is a distinct empty state from "no
        // friends at all" and must not be collapsed into it client-side.
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let neverActiveFeed = FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(friend_id: "friend-quiet", username: "Quiet Friend",
                                       last_active_at: nil, note_preview: nil)
            ],
            check_in: FSCheckInCandidate(friend_id: "friend-quiet", username: "Quiet Friend", days_since_contact: nil)
        )
        service.fetchFriendActivityResult = neverActiveFeed
        let userId = freshUserId()

        await vm.load(service: service, userId: userId)

        XCTAssertEqual(vm.friendActivity, neverActiveFeed,
                        "a friend with zero tracked activity must still surface in friends_active exactly as the backend reported it")
        XCTAssertEqual(vm.friendActivity.friends_active.count, 1)
        XCTAssertNil(vm.friendActivity.friends_active[0].last_active_at)
        XCTAssertNil(vm.friendActivity.friends_active[0].note_preview)
        XCTAssertNil(vm.friendActivity.check_in?.days_since_contact)
    }

    // MARK: 3 — a thrown fetch is handled like every other load() source

    func test_load_fetchFriendActivityThrows_fallsBackToEmpty_doesNotCrashOrHang() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        service.fetchFriendActivityError = AppError.networkError("simulated failure")
        let userId = freshUserId()

        await vm.load(service: service, userId: userId)

        XCTAssertEqual(vm.friendActivity, FSFriendActivityFeed.empty,
                        "a thrown fetchFriendActivity must fall back to .empty, same `try?` handling as every other load() source, not leave friendActivity undefined")
        XCTAssertFalse(vm.isLoading, "load() must still complete (not hang) when this one source fails")
    }

    // MARK: 4 — cache-first warm start actually shows cached data before the fresh fetch resolves

    func test_load_secondViewModel_showsCachedFriendActivityImmediately_beforeSlowFreshFetchResolves() async {
        let userId = freshUserId()

        // First load: populates DiskCache's "friendActivity:<userId>" entry
        // with the (non-empty) mock feed.
        let warmVM = DashboardViewModel()
        let warmService = ThrowingTestDataService()
        await warmVM.load(service: warmService, userId: userId)
        XCTAssertEqual(warmVM.friendActivity, MockDataService.mockFriendActivity)

        // Second, fresh DashboardViewModel instance for the SAME userId,
        // with fetchFriendActivity deliberately delayed well past the
        // cache-read window, mirroring StartupCoordinatorTests' hang
        // technique for proving cache-first is real (not just read from
        // source).
        let coldVM = DashboardViewModel()
        let coldService = ThrowingTestDataService()
        coldService.fetchFriendActivityDelayNanoseconds = 3_000_000_000
        coldService.fetchFriendActivityResult = .empty // distinct from the cached value, so equality proves which one rendered

        let loadTask = Task { await coldVM.load(service: coldService, userId: userId) }

        // Give the cache-first synchronous warm start a moment to land,
        // comfortably before the 3s delayed fresh fetch could possibly
        // resolve.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(coldVM.friendActivity, MockDataService.mockFriendActivity,
                        "before the slow fresh fetch resolves, the cached feed from the prior load() must already be showing")

        await loadTask.value
        XCTAssertEqual(coldVM.friendActivity, FSFriendActivityFeed.empty,
                        "once the fresh fetch resolves, it must overwrite the stale cached value (stale-while-revalidate, not cache-forever)")
    }
}
