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
        1: "com.fellowscript.access.one",   2: "com.fellowscript.access.two",
        3: "com.fellowscript.access.three", 4: "com.fellowscript.access.four",
        5: "com.fellowscript.access.five",  6: "com.fellowscript.access.six",
        7: "com.fellowscript.access.seven", 8: "com.fellowscript.access.eight",
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
                do {
                    try await report(jws: verification.jwsRepresentation, userId: userId, service: service)
                } catch {
                    // Apple has been paid, but the backend didn't accept the
                    // sync (network failure, transient 5xx, or a rejection
                    // like "already linked to a different account" — see
                    // NetworkService.syncAppleSubscription). Do NOT finish()
                    // the transaction or report success here: leaving it
                    // unfinished keeps it in Transaction.currentEntitlements,
                    // so the next syncEntitlements() call (every AccountView
                    // load, and explicitly via restore()) retries the sync
                    // instead of the entitlement being silently dropped while
                    // the UI claims the purchase succeeded.
                    lastError = "Your purchase went through with Apple, but we couldn't confirm it with FellowScript yet. It will retry automatically the next time you open this screen — contact support if it doesn't resolve."
                    return false
                }
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
    /// Returns false (and sets `lastError`) if any entitlement failed to sync
    /// with the backend, so callers can surface that instead of a silent
    /// false-success "restore" (mirrors purchase()'s handling).
    @discardableResult
    func restore(userId: String, service: DataServiceProtocol) async -> Bool {
        // Logged instead of silently discarded (dependency-errors #9) --
        // restore() still calls syncEntitlements() afterward regardless, so
        // this doesn't change control flow, only whether a sync failure
        // leaves a diagnostic trail.
        do {
            try await AppStore.sync()
        } catch {
            print("[StoreKitManager] AppStore.sync() failed during restore: \(error)")
        }
        return await syncEntitlements(userId: userId, service: service)
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
        guard let sub = products.first(where: { $0.subscription != nil })?.subscription else { return nil }
        let statuses: [Product.SubscriptionInfo.Status]
        do {
            statuses = try await sub.status
        } catch {
            // compile-errors #5: `try?` previously made a thrown status-fetch
            // failure (e.g. a transient StoreKit/network error) indistinguishable
            // from "no active renewal" -- both silently returned nil here, so a
            // caller (SubscriptionCard) couldn't tell a real fetch failure from a
            // genuine "you don't have an active subscription" state. Logged
            // instead of silently discarded, matching restore()'s
            // print(...)-on-catch convention above -- still returns nil either
            // way since this method's return type has no room for a distinct
            // "failed" case, but now leaves a diagnostic trail rather than none.
            print("[StoreKitManager] currentRenewal() status fetch failed: \(error)")
            return nil
        }
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
    /// Returns false (and sets `lastError`) if syncing any entitlement failed —
    /// a failure on one entitlement doesn't stop the rest from being reported.
    @discardableResult
    func syncEntitlements(userId: String, service: DataServiceProtocol) async -> Bool {
        var allSucceeded = true
        for await verification in Transaction.currentEntitlements {
            if case .verified(let txn) = verification,
               Self.productIDs.contains(txn.productID) {
                do {
                    try await report(jws: verification.jwsRepresentation, userId: userId, service: service)
                } catch {
                    // Previously discarded via `try?` — the exact silent-swallow
                    // pattern this audit is hunting for, on the entitlement
                    // reconciliation path (app launch + Manage Subscriptions
                    // restore) rather than the initial purchase.
                    allSucceeded = false
                }
            }
        }
        if !allSucceeded {
            lastError = "Couldn't fully sync your subscription with the server. Reopen this screen to retry."
        }
        return allSucceeded
    }

    /// Present Apple's Manage Subscriptions sheet (the only place an Apple
    /// subscription can be canceled — it can't be canceled from our server).
    func showManageSubscriptions() async {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        // Logged instead of silently discarded (dependency-errors #9) -- a
        // failed presentation just means the sheet silently fails to show,
        // but that should leave a diagnostic trail rather than none at all.
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            print("[StoreKitManager] AppStore.showManageSubscriptions failed: \(error)")
        }
        #endif
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    /// Propagates any sync failure (network error or a backend rejection like
    /// "already linked to a different account") instead of swallowing it —
    /// callers decide what to do (see purchase()/syncEntitlements()).
    private func report(jws: String, userId: String, service: DataServiceProtocol) async throws {
        _ = try await service.syncAppleSubscription(userId: userId, jws: jws)
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified:         throw StoreError.failedVerification
        }
    }
}
