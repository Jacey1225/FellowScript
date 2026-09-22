// ChatFriendNudgeButtonTests.swift — testing coverage for task
// 20260922-chat-friend-nudge-button (Lightweight spec; the frontend gate
// writes this minimal suite directly since this task's spec names no
// separate testing step).
//
// Covers ChatViewModel.sendNudge(userId:friendId:)/nudgeState(for:) — the
// per-friend nudge state machine driving each friend row's ChatNudgeButton
// (ChatRootView.swift) — against the shared `DataServiceProtocol.sendNudge`
// / `NudgeResult` contract (see DashboardCheckInNudgeTests.swift for the
// sibling Dashboard-side coverage of the same contract, and
// NetworkServiceSendNudgeTests.swift for the HTTP-status mapping). Exercises
// the real ChatViewModel against ThrowingTestDataService's existing
// controllable sendNudge seam (AppStateAuthAccountTests.swift) rather than
// the real network, since the state-machine logic under test lives entirely
// in ChatViewModel, not in any HTTP handling.
//
// Covers:
//   1. Happy path: idle -> sending -> sent for a specific friend, and the
//      exact (userId, friendId) pair sent matches the call's arguments.
//   2. Rate-limited: idle -> sending -> rateLimited, and stays there.
//   3. Failed: idle -> sending -> failed -> (after the ~300ms pulse) back to
//      idle, inviting an immediate retry.
//   4. Re-entrancy guard: calling sendNudge again for the same friend while
//      already `.sending` is a no-op — the service is called exactly once.
//   5. Per-row independence (this task's core new acceptance criterion,
//      unlike Dashboard's single-candidate design): nudging one friend must
//      never change another, unrelated friend's displayed state, regardless
//      of which one resolves first.
//   6. NudgeUIState.from(_:) — the shared NudgeResult mapping this task
//      extracted so Dashboard and Chat don't each reimplement it — maps all
//      three outcomes correctly.

import XCTest
@testable import FellowScript

@MainActor
final class ChatFriendNudgeButtonTests: XCTestCase {

    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    private func makeViewModel(service: ThrowingTestDataService) -> ChatViewModel {
        let vm = ChatViewModel()
        vm.service = service
        return vm
    }

    // MARK: 1 — happy path, observable mid-flight .sending, correct pair sent

    func test_sendNudge_success_goesIdleToSendingToSent_withCorrectUserAndFriendId() async {
        let service = ThrowingTestDataService()
        let vm = makeViewModel(service: service)
        let userId = freshUserId()

        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .idle, "a never-nudged friend must start tappable")

        service.sendNudgeDelayNanoseconds = 200_000_000
        service.sendNudgeResult = .sent

        let sendTask = Task { await vm.sendNudge(userId: userId, friendId: "friend-a") }

        // Give sendNudge's synchronous `.sending` assignment a moment to
        // land, comfortably before the delayed service call resolves —
        // mirrors DashboardCheckInNudgeTests' identical technique.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .sending,
                       "must show a real mid-flight state, not jump straight to the result")

        await sendTask.value
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .sent)
        XCTAssertEqual(service.sendNudgeCallCount, 1)
        XCTAssertEqual(service.lastSendNudgeUserId, userId)
        XCTAssertEqual(service.lastSendNudgeFriendId, "friend-a")
    }

    // MARK: 2 — rate-limited stays rate-limited (does not revert to idle)

    func test_sendNudge_rateLimited_setsAndKeepsRateLimitedState() async {
        let service = ThrowingTestDataService()
        let vm = makeViewModel(service: service)
        service.sendNudgeResult = .rateLimited

        await vm.sendNudge(userId: freshUserId(), friendId: "friend-a")

        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .rateLimited)

        // Unlike .failed, a rate-limited result must not revert on its own —
        // give it well past the .failed pulse's ~300ms window and confirm
        // it's still rate-limited (ChatNudgeButton.isDisabled depends on
        // this staying true).
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .rateLimited,
                       "a rate-limited row must stay non-tappable, not silently revert to idle")
    }

    // MARK: 3 — failed pulses then returns to idle, inviting a retry

    func test_sendNudge_failed_pulsesFailed_thenReturnsToIdle() async {
        let service = ThrowingTestDataService()
        let vm = makeViewModel(service: service)
        service.sendNudgeResult = .failed

        let sendTask = Task { await vm.sendNudge(userId: freshUserId(), friendId: "friend-a") }

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .failed,
                       "a genuine delivery failure must show a distinct failed pulse")

        await sendTask.value
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .idle,
                       "a failed send must return to idle so the user can immediately retry")
    }

    // MARK: 4 — re-entrancy guard: a double-tap mid-flight is a no-op

    func test_sendNudge_doubleTapSameFriendWhileSending_onlyCallsServiceOnce() async {
        let service = ThrowingTestDataService()
        let vm = makeViewModel(service: service)
        let userId = freshUserId()
        service.sendNudgeDelayNanoseconds = 200_000_000
        service.sendNudgeResult = .sent

        let firstTap = Task { await vm.sendNudge(userId: userId, friendId: "friend-a") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .sending)

        // A second tap on the SAME friend while the first is still in flight
        // must be a no-op — `.sending` is the re-entrancy lock.
        await vm.sendNudge(userId: userId, friendId: "friend-a")
        await firstTap.value

        XCTAssertEqual(service.sendNudgeCallCount, 1,
                       "a double-tap on the same friend mid-flight must not fire a second network call")
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .sent)
    }

    // MARK: 5 — per-row independence: nudging one friend never moves another's state

    func test_sendNudge_perFriendStateIsIndependent_doesNotAffectOtherFriends() async {
        let service = ThrowingTestDataService()
        let vm = makeViewModel(service: service)
        let userId = freshUserId()

        // ThrowingTestDataService's sendNudge seam is a single shared
        // (result, delay) pair, not independently configurable per
        // concurrent in-flight call -- so this proves independence
        // sequentially instead of via two genuinely overlapping sends:
        // settle friend-a first, then nudge a different friend with a
        // different outcome, and confirm friend-a's already-settled entry in
        // ChatViewModel's per-friend dictionary is untouched by it.
        service.sendNudgeResult = .sent
        await vm.sendNudge(userId: userId, friendId: "friend-a")
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .sent)
        XCTAssertEqual(vm.nudgeState(for: "friend-b"), .idle,
                       "an unrelated, never-nudged friend must stay idle")

        service.sendNudgeResult = .rateLimited
        await vm.sendNudge(userId: userId, friendId: "friend-b")

        XCTAssertEqual(vm.nudgeState(for: "friend-b"), .rateLimited)
        XCTAssertEqual(vm.nudgeState(for: "friend-a"), .sent,
                       "nudging a different friend must not change friend-a's already-settled state")
        XCTAssertEqual(service.sendNudgeCallCount, 2)
    }

    // MARK: 6 — shared NudgeResult -> NudgeUIState mapping

    func test_nudgeUIState_from_mapsAllThreeOutcomes() {
        XCTAssertEqual(NudgeUIState.from(.sent), .sent)
        XCTAssertEqual(NudgeUIState.from(.rateLimited), .rateLimited)
        XCTAssertEqual(NudgeUIState.from(.failed), .failed)
    }
}
