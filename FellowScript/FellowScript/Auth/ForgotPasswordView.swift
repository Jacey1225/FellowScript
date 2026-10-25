// Requests a password-reset email. Completion happens on the web (the emailed
// link opens fellowscript.com/#/reset-password in Safari — no deep-linking
// back into the app is configured), so this screen only covers the request
// step. Mirrors frontend/src/pages/ForgotPassword.jsx.
// Restyled onto the FSForm kit (task 20261023-forms-restyle): type C, S.

import SwiftUI

struct ForgotPasswordView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var isLoading = false
    @State private var sent = false
    @State private var errorMsg = ""

    private var emailValid: Bool { email.contains("@") }

    var body: some View {
        FSAuthScaffold(
            title: sent ? "Check your email" : "Forgot password",
            subtitle: sent ? nil : "Enter your account email and we'll send a reset link.",
            errorMessage: errorMsg,
            primaryTitle: sent ? nil : "Send reset link",
            primaryDimmed: !emailValid,
            saving: isLoading,
            onPrimary: { if emailValid && !isLoading { Task { await sendReset() } } },
            onClose: { dismiss() }
        ) {
            if sent {
                VStack(spacing: Theme.spacingSM) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.gold)
                    Text("If an account with that email exists, a password reset link has been sent. It expires in 30 minutes.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                FSField(label: "Email", text: $email, placeholder: "you@example.com",
                        leadingSymbol: "envelope",
                        contentType: .emailAddress, keyboard: .emailAddress,
                        capitalization: .never, autocorrect: false,
                        onSubmit: { if emailValid && !isLoading { Task { await sendReset() } } })
            }
        }
        // Shared keyboard-dismiss convention (task 20260831-interaction-polish-conventions).
        .dismissesKeyboardOnScrollAndTap()
    }

    private func sendReset() async {
        errorMsg = ""
        isLoading = true
        defer { isLoading = false }
        do {
            try await appState.service.requestPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
            sent = true
        } catch {
            // The endpoint itself never reveals account existence; only a real
            // network failure should surface here.
            errorMsg = "Could not reach the server."
        }
    }
}
