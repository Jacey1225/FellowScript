// NetworkService+Promo.swift — friend invite codes (task
// 20261003-ios-friend-offer-code-redeem, api/routes/promo.py). Two calls:
//   POST /promo/{id}/friend-code    the caller's own shareable code + link
//   POST /promo/{id}/ios-offer-code a friend's code -> one-time-use Apple offer code
// Every method throws on failure (throw-not-fabricate); nothing here grants a
// discount. The offer code is a bearer value: it is returned to the caller
// only, never logged, cached or persisted. Neither call is retried (the
// server is idempotent, but a retry is the user's explicit choice).

import Foundation

struct FSFriendCode: Codable, Equatable {
    let code: String
    let link: String
    let percent_off: Int
}

struct FSIosOfferCode: Decodable {
    let offer_code: String
    let redeem_url: String
    let expires_at: String?
}

/// Failure classes of the redeem call. Messages never say WHY a code was
/// rejected (the server answers every denial identically).
enum InviteCodeError: Error, Equatable, LocalizedError {
    case invalid          // 400 invalid_invite_code (uniform)
    case rateLimited      // 429
    case unavailable      // 503 / network / malformed response
    case disabled         // 404: feature off, hide the UI

    var errorDescription: String? {
        switch self {
        case .invalid:     return "That invite code isn't valid."
        case .rateLimited: return "Too many tries. Wait a minute and try again."
        case .unavailable: return "Couldn't prepare your offer right now. Try again shortly."
        case .disabled:    return "Invite codes aren't available right now."
        }
    }
}

extension NetworkService {

    /// POST /promo/{userId}/friend-code. Returns nil on the uniform 404 (promo
    /// flag off) so the share UI stays hidden. Any other failure throws.
    func fetchFriendCode(userId: String) async throws -> FSFriendCode? {
        var req = URLRequest(url: url("/promo/\(encodeURIComponent(userId))/friend-code"))
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try throwIfError(response, data)
        guard let code = decode(FSFriendCode.self, from: data, endpoint: "POST /promo/{user_id}/friend-code") else {
            throw AppError.networkError("Couldn't load your invite code.")
        }
        return code
    }

    /// POST /promo/{userId}/ios-offer-code. Throws InviteCodeError; never
    /// fabricates a code. Not retried.
    func requestIosOfferCode(userId: String, code: String) async throws -> FSIosOfferCode {
        var req = URLRequest(url: url("/promo/\(encodeURIComponent(userId))/ios-offer-code"))
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw InviteCodeError.unavailable
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 404: throw InviteCodeError.disabled
            case 429: throw InviteCodeError.rateLimited
            case 400, 401, 403, 422: throw InviteCodeError.invalid
            default: throw InviteCodeError.unavailable
            }
        }
        guard let offer = try? JSONDecoder().decode(FSIosOfferCode.self, from: data),
              !offer.offer_code.isEmpty else {
            throw InviteCodeError.unavailable
        }
        return offer
    }

    /// Signup with an optional invite code (backend SignupInfo.invite_code).
    /// A bad code never blocks signup; the server ignores it silently.
    func signUp(username: String, email: String, password: String, termsAccepted: Bool,
                inviteCode: String?) async throws -> FSUser {
        var body: [String: Any] = ["username": username, "email": email, "plain_pass": password,
                                   "terms_accepted": termsAccepted]
        if let inviteCode, !inviteCode.isEmpty { body["invite_code"] = inviteCode }
        let data = try await requestRaw("/signup", method: "POST", jsonObject: body)
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Sign up failed.")
        }
        return user
    }
}
