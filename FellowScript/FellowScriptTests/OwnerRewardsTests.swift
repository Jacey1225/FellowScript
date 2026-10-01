// OwnerRewardsTests.swift -- task 20261001-promo-owner-rewards, testing step 4.
// Covers the iOS owner-reward surface: NetworkService decode/404/409 contract
// (via StubURLProtocol), AccountViewModel reward state (flag-off hidden, failed
// refresh preserves last summary, claim never marks success on failure), and
// StoreKitManager.claimOwnerReward fail-closed paths that run before any
// StoreKit purchase sheet (server error, unknown product, malformed nonce /
// signature / applicationUsername). The successful promotional purchase needs
// an offer in the .storekit config and is not exercised here.

import XCTest
@testable import FellowScript

private let summaryJSON = """
{"percent_off":50,"earned":2,"claimed":1,"expired":0,"next_expiry":null,
 "provider":"apple","can_claim_apple":true,
 "apple_application_username":"11111111-1111-1111-1111-111111111111"}
"""

private func makeSummary(earned: Int = 1, provider: String? = "apple", canClaim: Bool = true) -> FSRewardSummary {
    let json = """
    {"percent_off":50,"earned":\(earned),"claimed":0,"expired":0,"next_expiry":null,
     "provider":\(provider.map { "\"\($0)\"" } ?? "null"),"can_claim_apple":\(canClaim),
     "apple_application_username":"11111111-1111-1111-1111-111111111111"}
    """
    return try! JSONDecoder().decode(FSRewardSummary.self, from: Data(json.utf8))
}

private func makeSignature(product: String = "com.fellowscript.access.one",
                           nonce: String = "22222222-2222-2222-2222-222222222222",
                           signature: String = Data([1, 2, 3]).base64EncodedString(),
                           username: String = "11111111-1111-1111-1111-111111111111") -> FSApplePromoSignature {
    let json = """
    {"keyIdentifier":"G6DRYNCNRS","nonce":"\(nonce)","timestamp":1700000000,
     "signature":"\(signature)","productIdentifier":"\(product)",
     "offerIdentifier":"invite_reward_50","applicationUsername":"\(username)"}
    """
    return try! JSONDecoder().decode(FSApplePromoSignature.self, from: Data(json.utf8))
}

// MARK: - NetworkService

final class NetworkServiceOwnerRewardsTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(StubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(StubURLProtocol.self); super.tearDown() }

    private func stub(_ status: Int, _ body: String) {
        StubURLProtocol.stubStatusCode = status
        StubURLProtocol.stubBody = Data(body.utf8)
    }

    func test_fetchRewardSummary_decodes200() async throws {
        stub(200, summaryJSON)
        let s = try await NetworkService.shared.fetchRewardSummary(userId: "u1")
        XCTAssertEqual(s?.earned, 2)
        XCTAssertEqual(s?.provider, "apple")
        XCTAssertEqual(s?.can_claim_apple, true)
        XCTAssertEqual(s?.percent_off, 50)
    }

    func test_fetchRewardSummary_404_returnsNil_featureOff() async throws {
        stub(404, #"{"detail":"Not found"}"#)
        let s = try await NetworkService.shared.fetchRewardSummary(userId: "u1")
        XCTAssertNil(s)
    }

    func test_fetchRewardSummary_403_throws() async {
        stub(403, #"{"detail":"Forbidden"}"#)
        do { _ = try await NetworkService.shared.fetchRewardSummary(userId: "u1"); XCTFail("must throw") }
        catch { /* expected */ }
    }

    func test_fetchRewardSummary_malformedBody_throwsNotFabricates() async {
        stub(200, #"{"unexpected":true}"#)
        do { _ = try await NetworkService.shared.fetchRewardSummary(userId: "u1"); XCTFail("must throw") }
        catch { /* expected */ }
    }

    func test_claimAppleReward_decodesSignature_andPostsToClaimPath() async throws {
        stub(200, """
        {"keyIdentifier":"G6DRYNCNRS","nonce":"n","timestamp":5,"signature":"c2ln",
         "productIdentifier":"com.fellowscript.access.one","offerIdentifier":"invite_reward_50",
         "applicationUsername":"u"}
        """)
        let before = StubURLProtocol.requestLog.count
        let sig = try await NetworkService.shared.claimAppleReward(userId: "u1")
        XCTAssertEqual(sig.keyIdentifier, "G6DRYNCNRS")
        XCTAssertEqual(sig.offerIdentifier, "invite_reward_50")
        let req = StubURLProtocol.requestLog.dropFirst(before).last
        XCTAssertEqual(req?.method, "POST")
        XCTAssertTrue(req?.path.hasSuffix("/rewards/u1/apple/claim") ?? false)
    }

    func test_claimAppleReward_404_andNoRetry() async {
        stub(404, #"{"detail":"nope"}"#)
        let before = StubURLProtocol.requestLog.count
        do { _ = try await NetworkService.shared.claimAppleReward(userId: "u1"); XCTFail("must throw") }
        catch AppError.networkError(let m) { XCTAssertTrue(m.contains("No reward")) }
        catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(StubURLProtocol.requestLog.count - before, 1, "a claim must never be retried")
    }

    func test_claimAppleReward_409_inProgressMessage() async {
        stub(409, #"{"detail":"x"}"#)
        do { _ = try await NetworkService.shared.claimAppleReward(userId: "u1"); XCTFail("must throw") }
        catch AppError.networkError(let m) { XCTAssertTrue(m.contains("already in progress")) }
        catch { XCTFail("wrong error \(error)") }
    }

    func test_claimAppleReward_500_throwsAndNoRetry() async {
        stub(500, #"{"detail":"err"}"#)
        let before = StubURLProtocol.requestLog.count
        do { _ = try await NetworkService.shared.claimAppleReward(userId: "u1"); XCTFail("must throw") }
        catch { /* expected */ }
        XCTAssertEqual(StubURLProtocol.requestLog.count - before, 1)
    }

    func test_claimAppleReward_malformedBody_throws() async {
        stub(200, #"{"foo":1}"#)
        do { _ = try await NetworkService.shared.claimAppleReward(userId: "u1"); XCTFail("must throw") }
        catch { /* expected */ }
    }
}

// MARK: - AccountViewModel + StoreKitManager fail-closed paths

@MainActor
final class AccountViewModelOwnerRewardsTests: XCTestCase {

    private func makeVM(_ svc: ThrowingTestDataService) -> AccountViewModel {
        let vm = AccountViewModel()
        vm.service = svc
        return vm
    }

    func test_loadRewardSummary_flagOff_nilKeepsUIHidden() async {
        let svc = ThrowingTestDataService(); svc.rewardSummaryResult = nil
        let vm = makeVM(svc)
        await vm.loadRewardSummary(userId: "u1")
        XCTAssertNil(vm.rewardSummary)
        XCTAssertEqual(svc.rewardSummaryCallCount, 1)
    }

    func test_loadRewardSummary_populates() async {
        let svc = ThrowingTestDataService(); svc.rewardSummaryResult = makeSummary(earned: 3)
        let vm = makeVM(svc)
        await vm.loadRewardSummary(userId: "u1")
        XCTAssertEqual(vm.rewardSummary?.earned, 3)
    }

    func test_loadRewardSummary_failedRefresh_preservesLastKnownSummary() async {
        let svc = ThrowingTestDataService(); svc.rewardSummaryResult = makeSummary(earned: 2)
        let vm = makeVM(svc)
        await vm.loadRewardSummary(userId: "u1")
        svc.rewardSummaryError = AppError.networkError("boom")
        await vm.loadRewardSummary(userId: "u1")
        XCTAssertEqual(vm.rewardSummary?.earned, 2, "a failed refresh must not clear the cached summary")
    }

    func test_claimReward_withoutProfile_isNoOp() async {
        let svc = ThrowingTestDataService()
        let vm = makeVM(svc)
        XCTAssertNil(vm.profileData)
        await vm.claimReward()
        XCTAssertEqual(svc.claimRewardCallCount, 0)
        XCTAssertFalse(vm.rewardBusy)
        XCTAssertNil(vm.rewardMsg)
    }

    func test_claimReward_serverRejects_surfacesMessage_noSuccess_busyCleared() async {
        let svc = ThrowingTestDataService()
        svc.claimRewardError = AppError.networkError("No reward is available to claim right now.")
        svc.rewardSummaryResult = makeSummary(earned: 1)
        let vm = makeVM(svc)
        vm.profileData = MockDataService.mockUser
        await vm.claimReward()
        XCTAssertEqual(svc.claimRewardCallCount, 1)
        XCTAssertEqual(vm.rewardMsg, "No reward is available to claim right now.")
        XCTAssertFalse(vm.rewardMsg?.contains("Reward applied") ?? false)
        XCTAssertFalse(vm.rewardBusy)
        XCTAssertEqual(vm.rewardSummary?.earned, 1, "summary reloaded after claim attempt")
        XCTAssertEqual(svc.rewardSummaryCallCount, 1)
    }

    func test_storeKit_claim_unknownProduct_failsClosed() async {
        let svc = ThrowingTestDataService()
        svc.claimRewardResult = makeSignature(product: "com.evil.product")
        let ok = await StoreKitManager.shared.claimOwnerReward(userId: "u1", service: svc)
        XCTAssertFalse(ok)
        XCTAssertNotNil(StoreKitManager.shared.lastError)
        XCTAssertFalse(StoreKitManager.shared.purchasing)
    }

    func test_storeKit_claim_malformedFields_failClosed() async {
        let bad = [
            makeSignature(nonce: "not-a-uuid"),
            makeSignature(signature: "!!!not base64!!!"),
            makeSignature(username: "not-a-uuid"),
        ]
        for sig in bad {
            let svc = ThrowingTestDataService(); svc.claimRewardResult = sig
            let ok = await StoreKitManager.shared.claimOwnerReward(userId: "u1", service: svc)
            XCTAssertFalse(ok)
            XCTAssertNotNil(StoreKitManager.shared.lastError)
            XCTAssertFalse(StoreKitManager.shared.purchasing)
        }
    }

    func test_storeKit_claim_serverError_setsLastError() async {
        let svc = ThrowingTestDataService()
        svc.claimRewardError = AppError.networkError("A reward claim is already in progress. Try again in a few minutes.")
        let ok = await StoreKitManager.shared.claimOwnerReward(userId: "u1", service: svc)
        XCTAssertFalse(ok)
        XCTAssertEqual(StoreKitManager.shared.lastError, "A reward claim is already in progress. Try again in a few minutes.")
    }

    func test_decode_summary_exposesAppleApplicationUsername() {
        XCTAssertEqual(makeSummary().apple_application_username, "11111111-1111-1111-1111-111111111111")
    }
}
