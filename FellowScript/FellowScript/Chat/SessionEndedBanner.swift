// SessionEndedBanner.swift — task 20261017-chat-ws-reconnect-stuck.
// Minimal in-thread banner shown in place of the endless "Reconnecting…" pill
// once the server has ended the session. Same Ember Glass capsule language as
// the pill; cached messages below stay readable.

import SwiftUI

struct SessionEndedBanner: View {
    let onSignIn: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Theme.spacingXS) {
            Text("Your session ended. Sign in again.")
                .font(.inter(Theme.fontSM))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
            HStack(spacing: Theme.spacingSM) {
                Button("Sign in again", action: onSignIn)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.gold)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(Theme.gold, lineWidth: 1))
                    .accessibilityHint("Signs out and returns to the sign-in screen")
                Button("Retry", action: onRetry)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.045))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderGoldFaint, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .topEdgeHighlight(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, Theme.spacingSM)
        .padding(.top, Theme.spacingXS)
        .accessibilityElement(children: .contain)
    }
}

/// Applies the session-ended wiring as ONE modifier so the host view's body
/// modifier chain stays short (the type-checker gave up on the long chain).
struct SessionEndedWiring: ViewModifier {
    let appEnded: Bool
    let vmEnded: Bool
    let onAppEnded: () -> Void
    let onVmEnded: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: appEnded) { _, ended in if ended { onAppEnded() } }
            .onChange(of: vmEnded) { _, ended in if ended { onVmEnded() } }
    }
}
