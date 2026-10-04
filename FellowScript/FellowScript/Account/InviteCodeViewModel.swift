// InviteCodeViewModel.swift — state for the Account tab's friend invite code
// surfaces (task 20261003-ios-friend-offer-code-redeem, design-notes.md):
//   A. "Have a friend's invite code?"  (invitee: redeem for an Apple offer code)
//   B. "Share your invite code"        (owner: copy / share the personal code)
// Throw-not-fabricate: failures leave prior state untouched. The cached friend
// code survives a failed refresh. The Apple offer code is held only in a local
// variable for the duration of the redeem call; it is never published, cached
// or logged.

import SwiftUI
import StoreKit
import Combine

@MainActor
final class InviteCodeViewModel: ObservableObject {
    var service: DataServiceProtocol = MockDataService.shared

    // Surface B
    @Published var friendCode: FSFriendCode? = nil
    @Published var friendCodeLoading = false
    @Published var friendCodeFailed = false      // last refresh failed
    /// Uniform 404: promo flag off, hide the share section.
    @Published var shareHidden = false

    // Surface A
    @Published var redeemHidden = false          // 404 from the offer-code endpoint
    @Published var redeemBusy = false
    @Published var redeemMsg: String? = nil      // error, shown under the field
    @Published var redeemInfo: String? = nil     // "Code accepted..."
    @Published var codeInput = ""

    private static func cacheKey(_ userId: String) -> String { "friendcode_\(userId)" }

    /// Load the cached code instantly, then refresh. A failed refresh keeps
    /// whatever is already shown.
    func loadFriendCode(userId: String) async {
        guard !userId.isEmpty else { return }
        if friendCode == nil, let cached = await DiskCache.shared.load(FSFriendCode.self, forKey: Self.cacheKey(userId)) {
            friendCode = cached
        }
        friendCodeLoading = true
        defer { friendCodeLoading = false }
        do {
            if let fresh = try await service.fetchFriendCode(userId: userId) {
                friendCode = fresh
                shareHidden = false
                friendCodeFailed = false
                await DiskCache.shared.save(fresh, forKey: Self.cacheKey(userId))
            } else {
                shareHidden = true
                friendCode = nil
                friendCodeFailed = false
            }
        } catch {
            print("[InviteCodeViewModel] loadFriendCode failed: \(error)")
            friendCodeFailed = true
        }
    }

    /// Accepts a pasted link (`...?code=X`) as well as a bare code.
    static func normalize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: t), let v = comps.queryItems?.first(where: { $0.name == "code" })?.value, !v.isEmpty {
            return String(v.prefix(64))
        }
        return String(t.prefix(64))
    }

    /// Validate with the server, then open Apple's redemption flow. Safe to
    /// retry (the server is idempotent). `onRedeemed` runs after the App Store
    /// UI was presented so the caller can resync the subscription once.
    func redeem(userId: String, onRedeemed: @escaping () async -> Void) async {
        let code = Self.normalize(codeInput)
        guard !code.isEmpty, !redeemBusy, !userId.isEmpty else { return }
        redeemBusy = true; redeemMsg = nil; redeemInfo = nil
        defer { redeemBusy = false }
        do {
            let offer = try await service.requestIosOfferCode(userId: userId, code: code)
            redeemInfo = "Code accepted. Opening the App Store…"
            await Self.presentRedeem(offer)
            codeInput = ""
            await onRedeemed()
        } catch InviteCodeError.disabled {
            redeemHidden = true
        } catch let e as InviteCodeError {
            redeemMsg = e.errorDescription
        } catch {
            redeemMsg = InviteCodeError.unavailable.errorDescription
        }
    }

    /// Apple's sheet cannot be pre-filled, so the redeem URL (which carries the
    /// code) is opened first and the system sheet is the fallback. The URL is
    /// only opened if it is an https apps.apple.com URL.
    private static func presentRedeem(_ offer: FSIosOfferCode) async {
        #if os(iOS)
        if let url = URL(string: offer.redeem_url), url.scheme == "https", url.host?.lowercased() == "apps.apple.com",
           await UIApplication.shared.open(url) {
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        do {
            try await AppStore.presentOfferCodeRedeemSheet(in: scene)
        } catch {
            print("[InviteCodeViewModel] presentOfferCodeRedeemSheet failed: \(error)")
        }
        #endif
    }
}
