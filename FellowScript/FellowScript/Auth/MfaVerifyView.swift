// Completes a login paused by AuthView when signIn() throws .mfaRequired —
// the account has email-based 2FA enabled and a 6-digit code has just been
// emailed. Mirrors frontend/src/pages/VerifyMfa.jsx.

import SwiftUI

struct MfaVerifyView: View {
    let userId: String
    let onComplete: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var errorMsg = ""
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            VStack(spacing: Theme.spacingLG) {
                Spacer()

                VStack(spacing: Theme.spacingSM) {
                    Text("Verify it's you")
                        .font(.playfair(Theme.fontDisplayMD))
                        .foregroundColor(Theme.parchment)
                    Text("We emailed a 6-digit code to finish signing in.")
                        .font(.lora(Theme.fontSM))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }

                if !errorMsg.isEmpty {
                    Text(errorMsg)
                        .font(.lora(Theme.fontXS))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.spacingLG)
                }

                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.parchment)
                    .padding(Theme.spacingMD)
                    .background(Theme.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius)
                            .stroke(Theme.borderGoldDim, lineWidth: 1)
                    )
                    .padding(.horizontal, Theme.spacingLG)
                    .accessibilityLabel("Verification code")

                Button(action: { Task { await verify() } }) {
                    HStack {
                        if isLoading { ProgressView().tint(Theme.ink) }
                        Text("Verify").font(.lora(Theme.fontSM)).bold()
                    }
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingMD)
                    .background(Theme.gold)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .disabled(isLoading || code.isEmpty)
                .padding(.horizontal, Theme.spacingLG)
                .accessibilityLabel("Verify button")

                Button("Back to sign in") { dismiss() }
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)

                Spacer()
            }
        }
    }

    private func verify() async {
        errorMsg = ""
        isLoading = true
        defer { isLoading = false }
        do {
            try await appState.completeMfaLogin(userId: userId, code: code.trimmingCharacters(in: .whitespaces))
            onComplete()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
