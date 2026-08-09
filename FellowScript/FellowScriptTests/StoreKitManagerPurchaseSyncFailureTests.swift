// StoreKitManagerPurchaseSyncFailureTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, step 15 (frontend), finding 1
// (CRITICAL): "the single most severe finding in this domain and arguably
// the whole audit ... since real money is at stake" (backend step 14).
//
// Drives StoreKitManager.purchase() through a REAL StoreKit purchase using
// Apple's StoreKitTest framework (SKTestSession + FellowScript.storekit, the
// same config file already checked into this project) — NOT a mock of
// StoreKitManager itself — so this exercises the actual `product.purchase()`
// / `checkVerified` / `report(jws:)` / `txn.finish()` control flow that was
// broken, not just the layer below it (see
// NetworkServiceSyncAppleSubscriptionErrorHandlingTests.swift for that).
//
// Pre-fix behavior: purchase() called `try? await report(...)`, discarding
// any sync failure, then unconditionally called `txn.finish()` and returned
// `true` — Apple had been paid, StoreKit would never re-present the
// transaction (finish() is permanent), and the UI told the user the purchase
// succeeded, even though the backend never granted the plan. A real
// paid-but-unentitled state with no recovery path.
//
// Fix: report(jws:) now `throws` and propagates a backend rejection;
// purchase() wraps it in do/catch and, on failure, sets `lastError` and
// returns `false` WITHOUT calling `txn.finish()`. The transaction stays in
// `Transaction.unfinished` / `Transaction.currentEntitlements`, so the next
// `syncEntitlements()` call (every AccountView load, and restore()) retries
// it automatically without StoreKit needing to re-present the purchase sheet.
//
// ⚠️ EXECUTION STATUS: this file is verified with `swiftc -parse` only in
// this environment (no Xcode / no `xcrun simctl` — same constraint noted by
// every prior frontend/testing step in this pipeline: steps 3, 6, 9, 10, 12,
// 13, 15). SKTestSession requires an actual iOS Simulator or device test
// host to run; it cannot execute headless via the Swift compiler alone.
// Flagged for an actual run via `xcodebuild test` once Xcode is available —
// this is, by a wide margin, the single highest-value test in this whole
// audit to actually execute given what's at stake (real payments), so doing
// so should be a priority the next time Xcode is available.

import XCTest
import StoreKit
import StoreKitTest
@testable import FellowScript

@MainActor
final class StoreKitManagerPurchaseSyncFailureTests: XCTestCase {
    var session: SKTestSession!

    override func setUp() async throws {
        try await super.setUp()
        session = try SKTestSession(configurationFileNamed: "FellowScript")
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
        try await super.tearDown()
    }

    /// The critical case: backend sync rejects a real, Apple-verified
    /// purchase. purchase() must report failure and must NOT finish() the
    /// transaction — finishing it would permanently prevent StoreKit from
    /// ever re-presenting it, stranding the user in a paid-but-unentitled
    /// state with no automatic recovery.
    func test_purchase_doesNotFinishTransaction_orReportSuccess_whenBackendSyncFails() async throws {
        let manager = StoreKitManager.shared
        await manager.loadProducts()
        XCTAssertFalse(manager.products.isEmpty, "StoreKitTest config must expose the FellowScript.storekit products")

        let service = ThrowingTestDataService()
        service.syncAppleSubscriptionError = AppError.networkError("Non-production transaction ignored")

        let productID = try XCTUnwrap(StoreKitManager.productID[1])
        let ok = await manager.purchase(memberCount: 1, userId: "test-user-1", service: service)

        XCTAssertFalse(ok, "purchase() must return false when the backend rejects the sync")
        XCTAssertEqual(service.syncAppleSubscriptionCallCount, 1)
        let lastError = try XCTUnwrap(manager.lastError)
        XCTAssertTrue(lastError.contains("couldn't confirm it with FellowScript"),
                       "lastError must clearly explain the purchase went through with Apple but wasn't confirmed: \(lastError)")

        // The load-bearing assertion: the transaction must remain UNFINISHED,
        // proving purchase() did not call txn.finish() on the failure path.
        var stillUnfinished = false
        for await result in Transaction.unfinished {
            if case .verified(let txn) = result, txn.productID == productID {
                stillUnfinished = true
                await txn.finish() // clean up test state regardless of outcome
            }
        }
        XCTAssertTrue(stillUnfinished,
                       "the paid Apple transaction must still be unfinished after a failed backend sync — " +
                       "this is what lets syncEntitlements() retry it automatically instead of the entitlement " +
                       "being silently and permanently dropped")
    }

    /// Happy-path regression guard: when the backend sync succeeds,
    /// purchase() must still return true and finish() the transaction as
    /// before — the fix must not turn successful purchases into false
    /// failures or leave every transaction permanently unfinished.
    func test_purchase_finishesTransaction_andReturnsTrue_whenBackendSyncSucceeds() async throws {
        let manager = StoreKitManager.shared
        await manager.loadProducts()

        let service = ThrowingTestDataService()
        service.syncAppleSubscriptionResult = FSSubscription(
            id: "sub-ok", user_id: "test-user-2", plan_type: "group",
            status: "active", price_cents: 1000, max_members: 1
        )

        let productID = try XCTUnwrap(StoreKitManager.productID[1])
        let ok = await manager.purchase(memberCount: 1, userId: "test-user-2", service: service)

        XCTAssertTrue(ok, "purchase() must return true when the backend sync succeeds")
        XCTAssertEqual(service.syncAppleSubscriptionCallCount, 1)

        var stillUnfinished = false
        for await result in Transaction.unfinished {
            if case .verified(let txn) = result, txn.productID == productID {
                stillUnfinished = true
                await txn.finish()
            }
        }
        XCTAssertFalse(stillUnfinished, "a successfully-synced transaction must be finished, unchanged from pre-fix behavior")
    }
}
