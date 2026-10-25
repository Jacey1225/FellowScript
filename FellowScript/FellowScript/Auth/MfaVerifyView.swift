// Completes a login paused by AuthView when signIn() throws .mfaRequired —
// the account has email-based 2FA enabled and a 6-digit code has just been
// emailed. Mirrors frontend/src/pages/VerifyMfa.jsx.
// Restyled onto the FSForm kit (task 20261023-forms-restyle): type C, S, TC2.

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
        FSAuthScaffold(
            title: "Verify it's you",
            subtitle: "We emailed a 6-digit code to finish signing in.",
            errorMessage: errorMsg,
            primaryTitle: "Verify",
            primaryDimmed: code.isEmpty,
            saving: isLoading,
            onPrimary: { if !code.isEmpty && !isLoading { Task { await verify() } } }
        ) {
            VStack(spacing: Theme.spacingMD) {
                FSCodeField(label: "Verification code", code: $code)
                Button("Back to sign in") { dismiss() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .frame(minHeight: 44)
            }
        }
        // Shared keyboard-dismiss convention (task 20260831-interaction-polish-conventions).
        .dismissesKeyboardOnScrollAndTap()
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
