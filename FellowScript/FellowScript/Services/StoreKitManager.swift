// StoreKit 2 layer for auto-renewable subscriptions.
// Loads products, runs the purchase flow, listens for renewals/refunds, checks
// entitlements (restore), and forwards each verified transaction's signed JWS to
// the backend (/subscriptions/apple/sync), which is the source of truth.
//
// Product IDs must match App Store Connect AND api/backend/subscription/apple_service.py.

import Foundation
import Combine
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class StoreKitManager: ObservableObject {
    static let shared = StoreKitManager()
    private init() {}

    // One fixed-price product per member count (1-8) — StoreKit can't compute an
    // arbitrary price, so the host's selected group size maps to a specific product.
    static let productID: [Int: String] = [
        1: "com.fellowscript.app.group1", 2: "com.fellowscript.app.group2",
        3: "com.fellowscript.app.group3", 4: "com.fellowscript.app.group4",
        5: "com.fellowscript.app.group5", 6: "com.fellowscript.app.group6",
        7: "com.fellowscript.app.group7", 8: "com.fellowscript.app.group8",
    ]
    static let productIDs = Array(productID.values)

    @Published var products:   [Product] = []
    @Published var purchasing  = false
    @Published var loaded      = false
    @Published var lastError:  String?

    private var updatesTask: Task<Void, Never>?

    enum StoreError: Error { case failedVerification }

    // ── Product ↔ member-count mapping ─────────────────────────────────────────

    func memberCount(for productID: String) -> Int? {
        Self.productID.first { $0.value == productID }?.key
    }
    func productID(for memberCount: Int) -> String? {
        Self.productID[memberCount]
    }
    func product(for memberCount: Int) -> Product? {
        guard let id = productID(for: memberCount) else { return nil }
        return products.first { $0.id == id }
    }
    /// Localized price like "$17.99" for a member count, or nil if products aren't loaded.
    func displayPrice(for memberCount: Int) -> String? {
        product(for: memberCount)?.displayPrice
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────────

    /// Begin listening for transaction updates. Safe to call more than once.
    func startListening() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached {
            // Renewal/refund/Ask-to-Buy resolutions arrive here. AccountView
            // re-syncs entitlements on appear, so we just finish verified ones.
            for await update in Transaction.updates {
                if case .verified(let txn) = update {
                    await txn.finish()
                }
            }
        }
    }

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = fetched.sorted { $0.price < $1.price }
        } catch {
            lastError = "Could not load subscription options."
        }
        loaded = true
    }

    // ── Purchase / restore / manage ────────────────────────────────────────────

    /// Purchase a plan for the given member count. Returns true when a verified
    /// purchase completed.
    func purchase(memberCount: Int, userId: String, service: DataServiceProtocol) async -> Bool {
        guard let product = product(for: memberCount) else {
            lastError = "This plan isn't available right now."
            return false
        }
        purchasing = true
        defer { purchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let txn = try checkVerified(verification)
                await report(jws: verification.jwsRepresentation, userId: userId, service: service)
                await txn.finish()
                return true
            case .userCancelled:
                return false
            case .pending:
                lastError = "Your purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "Purchase could not be completed."
            return false
        }
    }

    /// Restore: sync with the App Store, then report current entitlements.
    func restore(userId: String, service: DataServiceProtocol) async {
        try? await AppStore.sync()
        await syncEntitlements(userId: userId, service: service)
    }

    /// The product IDs the user is currently entitled to (active subscriptions).
    /// Empty means no active FellowScript subscription on this Apple ID — used to
    /// reconcile a stale plan the backend still shows after cancel/expiry.
    func activeEntitlementProductIDs() async -> Set<String> {
        var ids: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, Self.productIDs.contains(txn.productID) {
                ids.insert(txn.productID)
            }
        }
        return ids
    }

    /// Whether the user's active FellowScript entitlement will auto-renew, plus
    /// when the current period ends. `willAutoRenew == false` means they cancelled
    /// (via the App Store) but still have access until `expirationDate`. Returns
    /// nil when there is no active entitlement. Requires `loadProducts()` first.
    struct EntitlementRenewal { let willAutoRenew: Bool; let expirationDate: Date? }

    func currentRenewal() async -> EntitlementRenewal? {
        guard let sub = products.first(where: { $0.subscription != nil })?.subscription,
              let statuses = try? await sub.status else { return nil }
        for status in statuses {
            guard case .verified(let txn) = status.transaction,
                  Self.productIDs.contains(txn.productID),
                  status.state == .subscribed
                    || status.state == .inGracePeriod
                    || status.state == .inBillingRetryPeriod
            else { continue }
            var willRenew = true
            if case .verified(let info) = status.renewalInfo { willRenew = info.willAutoRenew }
            return EntitlementRenewal(willAutoRenew: willRenew, expirationDate: txn.expirationDate)
        }
        return nil
    }

    /// Report all current active entitlements to the backend (launch + restore).
    func syncEntitlements(userId: String, service: DataServiceProtocol) async {
        for await verification in Transaction.currentEntitlements {
            if case .verified(let txn) = verification,
               Self.productIDs.contains(txn.productID) {
                await report(jws: verification.jwsRepresentation, userId: userId, service: service)
            }
        }
    }

    /// Present Apple's Manage Subscriptions sheet (the only place an Apple
    /// subscription can be canceled — it can't be canceled from our server).
    func showManageSubscriptions() async {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
        #endif
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    private func report(jws: String, userId: String, service: DataServiceProtocol) async {
        try? await service.syncAppleSubscription(userId: userId, jws: jws)
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified:         throw StoreError.failedVerification
        }
    }
}
