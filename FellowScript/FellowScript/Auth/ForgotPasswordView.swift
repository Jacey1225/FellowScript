// Requests a password-reset email. Completion happens on the web (the emailed
// link opens fellowscript.com/#/reset-password in Safari — no deep-linking
// back into the app is configured), so this screen only covers the request
// step. Mirrors frontend/src/pages/ForgotPassword.jsx.

import SwiftUI

struct ForgotPasswordView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var isLoading = false
    @State private var sent = false
    @State private var errorMsg = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                VStack(spacing: Theme.spacingLG) {
                    Spacer(minLength: 40)

                    VStack(spacing: Theme.spacingSM) {
                        Text("Forgot password")
                            .font(.playfair(Theme.fontDisplayMD))
                            .foregroundColor(Theme.parchment)
                        Text("Enter your account email and we'll send a reset link.")
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, Theme.spacingLG)

                    if sent {
                        VStack(spacing: Theme.spacingSM) {
                            Image(systemName: "envelope.badge.fill")
                                .font(.system(size: 32))
                                .foregroundColor(Theme.gold)
                            Text("Check your email")
                                .font(.lora(Theme.fontBody)).bold()
                                .foregroundColor(Theme.parchment)
                            Text("If an account with that email exists, a password reset link has been sent. It expires in 30 minutes.")
                                .font(.lora(Theme.fontSM))
                                .foregroundColor(Theme.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, Theme.spacingLG)
                    } else {
                        if !errorMsg.isEmpty {
                            Text(errorMsg)
                                .font(.lora(Theme.fontXS))
                                .foregroundColor(.red)
                                .padding(.horizontal, Theme.spacingLG)
                        }

                        FSTextField(placeholder: "Email", icon: "envelope", text: $email, isSecure: false)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .autocapitalization(.none)
                            .padding(.horizontal, Theme.spacingLG)
                            .accessibilityLabel("Email field")

                        Button(action: { Task { await sendReset() } }) {
                            HStack {
                                if isLoading { ProgressView().tint(Theme.ink) }
                                Text("Send reset link").font(.lora(Theme.fontSM)).bold()
                            }
                            .foregroundColor(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingMD)
                            .background(Theme.gold)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        }
                        .disabled(isLoading || !email.contains("@"))
                        .padding(.horizontal, Theme.spacingLG)
                        .accessibilityLabel("Send reset link button")
                    }

                    Spacer()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
            }
        }
        .preferredColorScheme(.dark)
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
