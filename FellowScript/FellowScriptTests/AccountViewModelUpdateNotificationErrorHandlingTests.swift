// AccountViewModelUpdateNotificationErrorHandlingTests.swift — regression
// coverage for task 20260808-ios-backend-integration-audit, step 17
// (backend) / step 18 (frontend): incident #1's silent-swallow-into-
// false-success pattern, found on the notifications domain.
//
// Root cause (backend step 17): api/backend/interactions/notifications.py's
// update_notification (timestamps branch) used to log+rollback+swallow a DB
// write failure with no re-raise, so PUT /notification/{user_id}/{notif_id}
// unconditionally responded 200 {"ok": true} even when nothing was actually
// persisted. Fixed by re-raising, turning a real failure into a genuine 500.
//
// That alone wasn't enough end to end — the iOS client had two matching
// gaps (frontend step 18):
//   1. NetworkService.updateNotification used unchecked `requestRaw` (no
//      throwIfError), so even a real 500 from the now-fixed backend would
//      never surface as a thrown Swift error.
//   2. AccountViewModel.updateNotification called it with `try?` and then
//      unconditionally mutated the local `notifications` array as if the
//      edit had saved — the exact same class of bug as incident #1's
//      AccountView.saveProfile, one screen over in the same file.
//
// Fixed by switching to checkedRequestRaw and restructuring
// AccountViewModel.updateNotification into do/catch (mirroring the
// existing updateEvent/toggleAgent/renameAgent pattern): the local mutation
// only happens after the network call succeeds, and failure surfaces via
// the existing `agentMsg` alert.
//
// These tests exercise the ViewModel directly via the ThrowingTestDataService
// seam (defined in AppStateAuthAccountTests.swift) — no live network
// involved, but the seam's error/success behavior is exactly what
// NetworkService.updateNotification now produces post-fix (throws on
// failure instead of silently returning).

import XCTest
@testable import FellowScript

@MainActor
final class AccountViewModelUpdateNotificationErrorHandlingTests: XCTestCase {

    private func makeViewModel(service: ThrowingTestDataService, existing: FSNotification) -> AccountViewModel {
        let vm = AccountViewModel()
        vm.service = service
        vm.profileData = FSUser(user_id: "user-1", username: "alice", email: "alice@example.com")
        vm.notifications = [existing]
        return vm
    }

    /// Before the fix, this exact sequence (server rejects the write) still
    /// left `notifications` showing the NEW name/prompt/timestamps as if the
    /// save had succeeded, with zero visible feedback to the user.
    func test_updateNotification_doesNotApplyEditLocally_whenServerCallFails() async {
        let existing = FSNotification(id: "notif-1", user_id: "user-1", name: "Old name", prompt: "Old prompt")
        let service = ThrowingTestDataService()
        service.updateNotificationError = AppError.networkError("Failed to save reminder")
        let vm = makeViewModel(service: service, existing: existing)

        XCTAssertNil(vm.agentMsg, "sanity: no stale message before the call")

        await vm.updateNotification(notif: existing, name: "New name", prompt: "New prompt", timestamps: Array(repeating: nil, count: 31))

        XCTAssertEqual(service.updateNotificationCallCount, 1)
        XCTAssertEqual(service.lastUpdateNotificationArgs?.userId, "user-1")
        XCTAssertEqual(service.lastUpdateNotificationArgs?.notifId, "notif-1")
        XCTAssertEqual(service.lastUpdateNotificationArgs?.name, "New name")

        // The load-bearing assertion: a rejected save must NOT be reflected
        // in local state — this is the exact false-success bug being fixed.
        XCTAssertEqual(vm.notifications.first?.name, "Old name",
                        "a failed server-side save must leave the pre-existing name in place, not silently apply the rejected edit")
        XCTAssertEqual(vm.notifications.first?.prompt, "Old prompt",
                        "a failed server-side save must leave the pre-existing prompt in place")

        XCTAssertNotNil(vm.agentMsg, "a rejected notification save must surface a visible error, not fail silently")
    }

    /// Happy-path regression guard: a successful save still applies the
    /// edit locally exactly as before, and does not set agentMsg.
    func test_updateNotification_appliesEditLocally_onSuccess() async {
        let existing = FSNotification(id: "notif-1", user_id: "user-1", name: "Old name", prompt: "Old prompt")
        let service = ThrowingTestDataService()
        service.updateNotificationError = nil
        let vm = makeViewModel(service: service, existing: existing)

        let newTimestamps = Array(repeating: nil as String?, count: 31)
        await vm.updateNotification(notif: existing, name: "New name", prompt: "New prompt", timestamps: newTimestamps)

        XCTAssertEqual(service.updateNotificationCallCount, 1)
        XCTAssertEqual(vm.notifications.first?.name, "New name",
                        "a successful save must apply the edit locally")
        XCTAssertEqual(vm.notifications.first?.prompt, "New prompt")
        XCTAssertNil(vm.agentMsg, "a successful notification save must not set an error message")
    }

    /// Guard clause regression: with no profileData (not signed in / not yet
    /// loaded), updateNotification must be a no-op and never call the
    /// service.
    func test_updateNotification_isNoOp_whenNoProfileData() async {
        let existing = FSNotification(id: "notif-1", user_id: "user-1", name: "Old name", prompt: "Old prompt")
        let service = ThrowingTestDataService()
        let vm = AccountViewModel()
        vm.service = service
        vm.profileData = nil
        vm.notifications = [existing]

        await vm.updateNotification(notif: existing, name: "New name", prompt: "New prompt", timestamps: Array(repeating: nil, count: 31))

        XCTAssertEqual(service.updateNotificationCallCount, 0)
        XCTAssertEqual(vm.notifications.first?.name, "Old name")
    }
}
