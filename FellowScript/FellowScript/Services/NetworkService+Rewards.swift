// NetworkService+Rewards.swift — owner rewards (task 20261001-promo-owner-rewards,
// api/routes/promo.py). An owner of an invite/creator code earns a percent-off-
// next-month reward; Apple subscribers claim it in-app via a server-signed
// StoreKit 2 promotional offer. Every method throws on failure
// (throw-not-fabricate); nothing here grants a discount -- the server signs only
// for an authenticated owner with an earned reward, and the reward is marked
// claimed only when Apple's verified transaction reaches /subscriptions/apple/sync.

import Foundation

struct FSRewardSummary: Decodable, Equatable {
    let percent_off: Int
    let earned: Int
    let claimed: Int
    let expired: Int
    let next_expiry: String?
    let provider: String?
    let can_claim_apple: Bool
    let apple_application_username: String
}

/// Response of POST /rewards/{user_id}/apple/claim. Field names mirror the
/// StoreKit promotional-offer parameters.
struct FSApplePromoSignature: Decodable, Equatable {
    let keyIdentifier: String
    let nonce: String
    let timestamp: Int
    let signature: String
    let productIdentifier: String
    let offerIdentifier: String
    let applicationUsername: String
}

extension NetworkService {

    /// GET /rewards/{userId}. Returns nil on the uniform 404 (feature flag off),
    /// so the whole reward UI stays hidden. Any other failure throws.
    func fetchRewardSummary(userId: String) async throws -> FSRewardSummary? {
        let (data, response) = try await getRawResponse("/rewards/\(encodeURIComponent(userId))")
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try throwIfError(response, data)
        guard let summary = decode(FSRewardSummary.self, from: data, endpoint: "GET /rewards/{user_id}") else {
            throw AppError.networkError("Couldn't load your reward.")
        }
        return summary
    }

    /// POST /rewards/{userId}/apple/claim. Never retried (a claim reserves the
    /// reward server-side). 404 = nothing to claim / not eligible, 409 = a claim
    /// is already in progress; both surface the server's wording.
    func claimAppleReward(userId: String) async throws -> FSApplePromoSignature {
        var req = URLRequest(url: url("/rewards/\(encodeURIComponent(userId))/apple/claim"))
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw AppError.networkError("No reward is available to claim right now.") }
            if http.statusCode == 409 { throw AppError.networkError("A reward claim is already in progress. Try again in a few minutes.") }
        }
        try throwIfError(response, data)
        guard let sig = decode(FSApplePromoSignature.self, from: data, endpoint: "POST /rewards/{user_id}/apple/claim") else {
            throw AppError.networkError("Couldn't start your reward claim.")
        }
        return sig
    }
}
