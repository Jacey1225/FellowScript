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

    static let individualID = "com.fellowscript.app.individual"
    static let groupID      = "com.fellowscript.app.group"
    static let productIDs   = [individualID, groupID]

    @Published var products:   [Product] = []
    @Published var purchasing  = false
    @Published var loaded      = false
    @Published var lastError:  String?

    private var updatesTask: Task<Void, Never>?

    enum StoreError: Error { case failedVerification }

    // ── Product ↔ plan mapping ─────────────────────────────────────────────────

    func planType(for productID: String) -> String {
        productID == Self.groupID ? "group" : "individual"
    }
    func productID(for planType: String) -> String {
        planType == "group" ? Self.groupID : Self.individualID
    }
    func product(for planType: String) -> Product? {
        products.first { $0.id == productID(for: planType) }
    }
    /// Localized price like "$9.99" for a plan, or nil if products aren't loaded.
    func displayPrice(for planType: String) -> String? {
        product(for: planType)?.displayPrice
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

    /// Purchase a plan. Returns true when a verified purchase completed.
    func purchase(planType: String, userId: String, service: DataServiceProtocol) async -> Bool {
        guard let product = product(for: planType) else {
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
