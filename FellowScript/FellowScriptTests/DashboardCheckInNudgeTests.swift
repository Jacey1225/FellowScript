// DashboardCheckInNudgeTests.swift — testing coverage for task
// 20260906-friend-nudges, testing step 4 (re-entry pass, after frontend's
// bounce fix restored FellowScriptTests' compilability).
//
// Covers DashboardViewModel.sendCheckInNudge(userId:) — CheckInRow's send
// action — against the shared `DataServiceProtocol.sendNudge` /
// `NudgeResult` contract (see NetworkServiceSendNudgeTests.swift for the
// sibling coverage of NetworkService.sendNudge's own HTTP-status mapping;
// this file covers the ViewModel-side state machine that CheckInRow's
// `nudgeState`/`isDisabled`/`badgeText`/`iconName` all key off).
//
// Exercises the real DashboardViewModel against ThrowingTestDataService's
// new controllable `sendNudgeResult`/`sendNudgeCallCount`/
// `lastSendNudgeUserId`/`lastSendNudgeFriendId` seam (added in this same
// pass, mirroring the existing fetchFriendActivityResult/fetchBlockedUsersResult
// seams on that same shared double) rather than the real network, since the
// state-machine logic under test lives entirely in DashboardViewModel, not in
// any HTTP handling.
//
// Covers:
//   1. Happy path: idle -> sending (observable mid-flight via a delayed
//      response) -> sent, and the exact (userId, friendId) pair sent matches
//      checkInPick.friend_id, not some other friend.
//   2. Rate-limited: idle -> sending -> rateLimited, and (unlike .failed)
//      stays there — CheckInRow's own isDisabled logic depends on this not
//      reverting, since a rate-limited row must stay non-tappable.
//   3. Failed: idle -> sending -> failed -> (after the documented ~300ms
//      pulse) back to idle, so a genuine delivery failure invites an
//      immediate retry rather than permanently disabling the row.
//   4. Re-entrancy guard: calling sendCheckInNudge again while already
//      `.sending` is a no-op — the service is called exactly once, not
//      twice, mirroring openFriendNote's isLoadingFriendNote guard this
//      method's own doc comment cites as precedent.
//   5. No-candidate guard: with no checkInPick (e.g. a friend list with zero
//      check-in candidates), calling sendCheckInNudge does nothing and never
//      calls the service at all — CheckInRow isn't even rendered in this
//      state (DashboardView's `if let checkIn = vm.checkInPick`), so this
//      guards against a stray/late call reaching the network regardless.

import XCTest
@testable import FellowScript

@MainActor
final class DashboardCheckInNudgeTests: XCTestCase {

    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    /// Loads `vm` with a feed whose only check-in candidate is `friend-quiet`
    /// so `checkInPick` is deterministic (no reliance on `.randomElement()`
    /// picking a specific entry out of a larger pool).
    private func loadWithSingleCandidate(_ vm: DashboardViewModel, service: ThrowingTestDataService, userId: String) async {
        service.fetchFriendActivityResult = FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(friend_id: "friend-quiet", username: "Quiet Friend",
                                       last_active_at: nil, note_preview: nil)
            ],
            check_in_candidates: [
                FSCheckInCandidate(friend_id: "friend-quiet", username: "Quiet Friend", days_since_contact: 9)
            ]
        )
        await vm.load(service: service, userId: userId)
    }

    // MARK: 1 — happy path, observable mid-flight .sending, correct friend_id sent

    func test_sendCheckInNudge_success_goesIdleToSendingToSent_withCorrectFriendId() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()
        await loadWithSingleCandidate(vm, service: service, userId: userId)

        XCTAssertEqual(vm.checkInNudgeState, .idle, "a freshly loaded candidate must start tappable")

        service.sendNudgeDelayNanoseconds = 300_000_000
        service.sendNudgeResult = .sent

        let sendTask = Task { await vm.sendCheckInNudge(userId: userId) }

        // Give sendCheckInNudge's synchronous `.sending` assignment a moment
        // to land, comfortably before the delayed service call resolves —
        // mirrors DashboardFriendActivityLoadTests' cache-first delay
        // technique for observing a real intermediate state.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.checkInNudgeState, .sending, "must show a real mid-flight state, not jump straight to the result")

        await sendTask.value
        XCTAssertEqual(vm.checkInNudgeState, .sent)
        XCTAssertEqual(service.sendNudgeCallCount, 1)
        XCTAssertEqual(service.lastSendNudgeUserId, userId)
        XCTAssertEqual(service.lastSendNudgeFriendId, "friend-quiet",
                       "must nudge the actual checkInPick's friend, not an arbitrary/hardcoded id")
    }

    // MARK: 2 — rate-limited stays rate-limited (does not revert to idle)

    func test_sendCheckInNudge_rateLimited_setsAndKeepsRateLimitedState() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()
        await loadWithSingleCandidate(vm, service: service, userId: userId)
        service.sendNudgeResult = .rateLimited

        await vm.sendCheckInNudge(userId: userId)

        XCTAssertEqual(vm.checkInNudgeState, .rateLimited)

        // Unlike .failed, a rate-limited result must not revert on its own —
        // give it well past the .failed pulse's ~300ms window and confirm it
        // is still showing the rate-limited state (CheckInRow's isDisabled
        // depends on this staying true).
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(vm.checkInNudgeState, .rateLimited,
                       "a rate-limited row must stay non-tappable, not silently revert to idle")
    }

    // MARK: 3 — failed pulses then returns to idle, inviting a retry

    func test_sendCheckInNudge_failed_pulsesFailed_thenReturnsToIdle() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()
        await loadWithSingleCandidate(vm, service: service, userId: userId)
        service.sendNudgeResult = .failed

        let sendTask = Task { await vm.sendCheckInNudge(userId: userId) }

        // Catch the transient .failed pulse before the documented ~300ms
        // sleep back to .idle elapses.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.checkInNudgeState, .failed, "a genuine delivery failure must show a distinct failed pulse")

        await sendTask.value
        XCTAssertEqual(vm.checkInNudgeState, .idle,
                       "a failed send must return to idle so the user can immediately retry, unlike rate-limited/sent")
    }

    // MARK: 4 — re-entrancy guard: a double-tap mid-flight is a no-op

    func test_sendCheckInNudge_doubleTapWhileSending_onlyCallsServiceOnce() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()
        await loadWithSingleCandidate(vm, service: service, userId: userId)
        service.sendNudgeDelayNanoseconds = 300_000_000
        service.sendNudgeResult = .sent

        let firstTap  = Task { await vm.sendCheckInNudge(userId: userId) }
        try? await Task.sleep(nanoseconds: 50_000_000) // let the first tap actually reach `.sending`
        XCTAssertEqual(vm.checkInNudgeState, .sending)

        // A second tap while the first is still in flight must be a no-op —
        // `.sending` itself is the re-entrancy lock, per this method's own
        // doc comment.
        await vm.sendCheckInNudge(userId: userId)
        await firstTap.value

        XCTAssertEqual(service.sendNudgeCallCount, 1,
                       "a double-tap mid-flight must not fire a second network call")
        XCTAssertEqual(vm.checkInNudgeState, .sent)
    }

    // MARK: 5 — no check-in candidate: sendCheckInNudge does nothing

    func test_sendCheckInNudge_noCheckInPick_doesNothing_serviceNeverCalled() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()
        service.fetchFriendActivityResult = .empty // no candidates at all
        await vm.load(service: service, userId: userId)

        XCTAssertNil(vm.checkInPick, "empty feed must not produce a check-in candidate")

        await vm.sendCheckInNudge(userId: userId)

        XCTAssertEqual(service.sendNudgeCallCount, 0,
                       "with no checkInPick, sendCheckInNudge must never reach the network")
        XCTAssertEqual(vm.checkInNudgeState, .idle)
    }
}
