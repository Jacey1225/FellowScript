// NetworkService+Auth.swift — Auth (sign in/up/Google/Apple/terms/logout),
// two-factor authentication, password reset, User CRUD, and device-token
// registration. Split out of NetworkService.swift (readability #H16,
// 20260904-frontend-arch-sweep) -- same type, same behavior, just this
// domain's own file. See NetworkService.swift's header comment for the full
// split rationale and the list of sibling domain files.

import Foundation

extension NetworkService {

    // ── Auth ──────────────────────────────────────────────────────────────────

    func signIn(username: String, password: String) async throws -> FSUser {
        let data = try await requestRaw("/login", method: "POST",
                                        jsonObject: ["username": username, "plain_pass": password])
        // 2FA-enabled accounts get {"mfa_required": true, "user_id": ...} instead
        // of a full user — check for that shape before attempting FSUser decode,
        // which would otherwise just fail (username/email are required fields).
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["mfa_required"] as? Bool == true, let uid = obj["user_id"] as? String {
            throw AppError.mfaRequired(userId: uid)
        }
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Sign in failed.")
        }
        return user
    }

    func signUp(username: String, email: String, password: String, termsAccepted: Bool) async throws -> FSUser {
        let data = try await requestRaw("/signup", method: "POST",
                                        jsonObject: ["username": username, "email": email, "plain_pass": password,
                                                     "terms_accepted": termsAccepted])
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Sign up failed.")
        }
        return user
    }

    func signInWithGoogle(credential: String, termsAccepted: Bool) async throws -> FSUser {
        let data = try await requestRaw("/auth/google", method: "POST",
                                        jsonObject: ["credential": credential, "terms_accepted": termsAccepted])
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Google sign-in failed.")
        }
        return user
    }

    func signInWithApple(identityToken: String, fullName: String?, email: String?, termsAccepted: Bool) async throws -> FSUser {
        var body: [String: Any] = ["identity_token": identityToken, "terms_accepted": termsAccepted]
        // fullName / email are only sent on the first authorization; omit when nil
        // so the server keeps whatever it captured the first time.
        if let fullName { body["full_name"] = fullName }
        if let email    { body["email"]     = email }
        let data = try await requestRaw("/auth/apple", method: "POST", jsonObject: body)
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Apple sign-in failed.")
        }
        return user
    }

    /// Records acceptance of the current Terms version after a `terms_reaccept_required`
    /// response — see FSUser.terms_reaccept_required.
    func acceptTerms(userId: String) async throws {
        _ = try await request("/user/\(userId)/accept-terms", method: "POST")
    }

    /// Invalidates the server-side session (deletes the row + clears the cookie).
    /// Auth is cookie-based (URLSession's shared HTTPCookieStorage sends it
    /// automatically), so no user id / body is needed — the session token in
    /// the request cookie identifies which session to end.
    func logout() async throws {
        _ = try await request("/logout", method: "POST")
    }

    // ── Two-factor authentication (email code) ──────────────────────────────────

    /// Completes a login paused by signIn()'s `.mfaRequired` — verifies the
    /// emailed 6-digit code and returns the same shape a normal login would.
    func verifyMfaLogin(userId: String, code: String) async throws -> FSUser {
        let data = try await requestRaw("/auth/mfa/verify-login", method: "POST",
                                        jsonObject: ["user_id": userId, "code": code])
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Invalid or expired code.")
        }
        return user
    }

    /// Starts turning 2FA on: emails a confirmation code. Does not enable 2FA
    /// yet — call mfaConfirm(code:) with it to finish.
    func mfaEnable() async throws {
        _ = try await checkedRequestRaw("/auth/mfa/enable", method: "POST", jsonObject: [:])
    }

    func mfaConfirm(code: String) async throws {
        _ = try await checkedRequestRaw("/auth/mfa/confirm", method: "POST", jsonObject: ["code": code])
    }

    /// Requires the current password so a hijacked/unattended session can't
    /// silently remove the account's second factor.
    func mfaDisable(password: String) async throws {
        _ = try await checkedRequestRaw("/auth/mfa/disable", method: "POST", jsonObject: ["plain_pass": password])
    }

    // ── Password reset ───────────────────────────────────────────────────────────

    /// Always succeeds from the caller's perspective regardless of whether the
    /// email has an account — the backend never reveals account existence.
    func requestPasswordReset(email: String) async throws {
        _ = try await requestRaw("/auth/password-reset/request", method: "POST", jsonObject: ["email": email])
    }

    // ── User ──────────────────────────────────────────────────────────────────
    // GET  /user/{userId}
    // PUT  /user/{userId}   body: {username?, email?, plain_pass?, timezone?}
    // DELETE /user/{userId}

    func fetchUser(userId: String) async throws -> FSUser {
        let data = try await get("/user/\(userId)")
        return decode(FSUser.self, from: data) ?? FSUser(user_id: userId, username: "", email: "")
    }

    func updateUser(userId: String, body: [String: String]) async throws -> FSUser {
        // checkedRequestRaw (not requestRaw) so a 4xx/5xx response (e.g. a
        // rejected timezone identifier or an auth failure) is raised as an
        // AppError instead of silently falling through to the decode below.
        let data = try await checkedRequestRaw("/user/\(userId)", method: "PUT", jsonObject: body)
        guard let user = decode(FSUser.self, from: data) else {
            let detail = extractErrorDetail(from: data) ?? "Update failed."
            throw AppError.networkError(detail)
        }
        return user
    }

    func deleteUser(userId: String) async throws {
        _ = try await request("/user/\(userId)", method: "DELETE")
    }

    // ── Notifications ─────────────────────────────────────────────────────────
    // POST   /notification/{userId}/device-token
    //
    // The user-authored notification CRUD/trigger endpoints this file used to
    // call (GET/POST/PUT/DELETE /notification/{userId}[...]) were removed from
    // the backend in 20260826-activity-based-notifications; device-token
    // registration and push delivery are unaffected and kept here (account-
    // level, alongside the rest of this file's identity/profile operations).

    func registerDeviceToken(userId: String, token: String) async throws {
        // checked so a write failure is at least logged by the caller instead of
        // vanishing — this endpoint's DB write can fail like any other and there
        // is no other signal (no UI polls "is my token registered?").
        _ = try await checkedRequestRaw("/notification/\(userId)/device-token", method: "POST",
                                 jsonObject: ["token": token])
    }
}
