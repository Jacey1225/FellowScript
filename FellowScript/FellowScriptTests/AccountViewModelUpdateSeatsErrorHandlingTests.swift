// AccountViewModelUpdateSeatsErrorHandlingTests.swift — regression coverage
// for task: 20260808-ios-backend-integration-audit, step 15 (frontend),
// finding 2 (HIGH): AccountViewModel.updateSeats() used to call
// `service.updateSubscriptionSeats(...)` through unchecked `requestRaw`
// wrapped in `try?` at the call site too — a double swallow. A 403 ("only
// the plan host may do this") or 404 (plan gone) was silently treated as
// success at both layers: no error ever reached the user, the seat count
// just silently failed to change on reload with zero explanation.
//
// Fixed by (a) NetworkService.updateSubscriptionSeats switching to
// checkedRequestRaw so a rejection actually throws, and (b)
// AccountViewModel.updateSeats() replacing `try?` with do/catch that sets
// `subMsg`, mirroring the existing requestJoin()/acceptRequest() pattern in
// the same view model.
//
// Uses the ThrowingTestDataService seam (defined in AppStateAuthAccountTests
// .swift) to drive the ViewModel directly — no network/StoreKit involved,
// since fetchUserSubscription's mock default (nil) keeps loadSubscription()'s
// post-update reload from touching StoreKitManager.

import XCTest
@testable import FellowScript

@MainActor
final class AccountViewModelUpdateSeatsErrorHandlingTests: XCTestCase {

    private func makeViewModel(service: ThrowingTestDataService) -> AccountViewModel {
        let vm = AccountViewModel()
        vm.service = service
        vm.profileData = FSUser(user_id: "host-1", username: "host", email: "host@example.com")
        vm.subscription = FSSubscription(id: "sub-1", user_id: "host-1", plan_type: "group",
                                          status: "active", price_cents: 1799, max_members: 2)
        return vm
    }

    /// Before the fix, this exact sequence (403 rejection) produced NO
    /// subMsg and no visible feedback — the seat count would just silently
    /// fail to change. After the fix, the rejection must be surfaced.
    func test_updateSeats_surfacesError_on403HostOnlyRejection() async {
        let service = ThrowingTestDataService()
        service.updateSubscriptionSeatsError = AppError.networkError("Only the plan host may do this")
        let vm = makeViewModel(service: service)

        XCTAssertNil(vm.subMsg, "sanity: no stale message before the call")
        await vm.updateSeats(memberCount: 4)

        XCTAssertEqual(service.updateSubscriptionSeatsCallCount, 1)
        XCTAssertEqual(service.lastUpdateSubscriptionSeatsArgs?.subscriptionId, "sub-1")
        XCTAssertEqual(service.lastUpdateSubscriptionSeatsArgs?.memberCount, 4)
        XCTAssertNotNil(vm.subMsg, "a rejected seat-count update must surface a visible error, not fail silently")
        XCTAssertFalse(vm.subBusy, "busy flag must be cleared even on failure")
    }

    /// Same class of failure, the other status the backend returns for this
    /// route (plan already gone).
    func test_updateSeats_surfacesError_on404PlanGone() async {
        let service = ThrowingTestDataService()
        service.updateSubscriptionSeatsError = AppError.networkError("Subscription not found")
        let vm = makeViewModel(service: service)

        await vm.updateSeats(memberCount: 3)

        XCTAssertEqual(vm.subMsg, "Subscription not found")
    }

    /// Happy-path regression guard: a successful update must NOT set subMsg
    /// (the fix must not turn successful writes into false failures).
    func test_updateSeats_noErrorMessage_onSuccess() async {
        let service = ThrowingTestDataService()
        service.updateSubscriptionSeatsError = nil
        let vm = makeViewModel(service: service)

        await vm.updateSeats(memberCount: 5)

        XCTAssertEqual(service.updateSubscriptionSeatsCallCount, 1)
        XCTAssertNil(vm.subMsg, "a successful seat-count update must not set an error message")
    }

    /// Guard clause regression: with no active subscription, updateSeats()
    /// must be a no-op and never call the service.
    func test_updateSeats_isNoOp_whenNoActiveSubscription() async {
        let service = ThrowingTestDataService()
        let vm = AccountViewModel()
        vm.service = service
        vm.profileData = FSUser(user_id: "host-1", username: "host", email: "host@example.com")
        vm.subscription = nil

        await vm.updateSeats(memberCount: 4)

        XCTAssertEqual(service.updateSubscriptionSeatsCallCount, 0)
    }
}
