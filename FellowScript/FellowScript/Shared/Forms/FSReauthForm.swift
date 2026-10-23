// FSReauthForm.swift
// Re-auth step (spec SX2): current password always required; the emailed
// authenticator code is requested only when the account has 2FA on. Verifies
// the password with the existing login endpoint; nothing is stored.

import SwiftUI

struct FSReauthForm: View {
    let username: String
    let service: DataServiceProtocol
    var onVerified: () -> Void
    var onCancel: () -> Void

    @State private var password = ""
    @State private var code = ""
    @State private var mfaUserId: String? = nil
    @State private var busy = false
    @State private var errorText: String? = nil

    var body: some View {
        FSFormScaffold(
            title: "Confirm it's you",
            onClose: onCancel,
            content: {
                FSFormCard {
                    Text("Enter your current password to continue.")
                        .font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                    FSField(label: "Current password", required: true, text: $password,
                            state: errorText.map { FSFieldState.error($0) } ?? .normal,
                            accessibilityName: "Current password",
                            secure: true, contentType: .password, capitalization: .never, autocorrect: false,
                            onSubmit: { Task { await verify() } })
                    if mfaUserId != nil {
                        FSCodeField(label: "Verification code", code: $code)
                    }
                }
            },
            bar: {
                FSPinnedActionBar(secondaryTitle: "Cancel", onSecondary: onCancel,
                                  primaryTitle: "Continue",
                                  primaryDimmed: password.isEmpty || (mfaUserId != nil && code.isEmpty),
                                  saving: busy,
                                  onPrimary: { Task { await verify() } })
            }
        )
        .fsPrivacyShield()
    }

    private func verify() async {
        guard !password.isEmpty, !busy else { return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            if let uid = mfaUserId {
                _ = try await service.verifyMfaLogin(userId: uid, code: code.trimmingCharacters(in: .whitespaces))
            } else {
                _ = try await service.signIn(username: username, password: password)
            }
            onVerified()
        } catch AppError.mfaRequired(let uid) {
            mfaUserId = uid
        } catch {
            // Neutral copy: never say which factor was wrong (spec 9.1.4).
            errorText = mfaUserId == nil ? "That password did not match." : "That code did not match."
        }
    }
}
