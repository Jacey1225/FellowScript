// DeleteAccountSheet.swift
// Tier-3 typed-confirm delete (spec SX3) followed by the SX2 re-auth step.
// The destructive primary stays dimmed until the typed username matches; the
// final delete runs only after the password (and 2FA code, if on) verifies.

import SwiftUI

struct DeleteAccountSheet: View {
    let username: String
    let userId: String
    let onFailure: (String) -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var reauth = false
    @State private var deleting = false

    private var matches: Bool { fsTypedConfirmMatches(typed, required: username) }

    var body: some View {
        Group {
            if reauth {
                FSReauthForm(username: username, service: appState.service,
                             onVerified: { Task { await performDelete() } },
                             onCancel: { reauth = false })
            } else {
                FSFormScaffold(
                    title: "Delete account",
                    dirty: !typed.isEmpty,
                    onClose: { dismiss() },
                    content: {
                        FSFormCard(title: "This permanently removes") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(["Your account and profile", "All notes and highlights",
                                         "Your group memberships and friend list"], id: \.self) { line in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "minus").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.error)
                                            .padding(.top, 4)
                                        Text(line).font(.system(size: 14)).foregroundColor(Theme.textPrimary)
                                    }
                                }
                            }
                            Text("This cannot be undone.").font(.fsHelper).foregroundColor(Theme.textSecondary)
                        }
                        FSFormCard {
                            FSField(label: "Type your username to confirm", text: $typed,
                                    placeholder: username,
                                    accessibilityName: "Type your username to confirm deletion",
                                    capitalization: .never, autocorrect: false)
                        }
                    },
                    bar: {
                        FSPinnedActionBar(secondaryTitle: "Cancel", onSecondary: { dismiss() },
                                          primaryTitle: "Delete my account", primaryDimmed: !matches,
                                          primaryDestructive: true, saving: deleting,
                                          onPrimary: { if matches { reauth = true } })
                    }
                )
                .fsPrivacyShield()
            }
        }
        .dismissesKeyboardOnScrollAndTap()
        .preferredColorScheme(.dark)
    }

    private func performDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await appState.service.deleteUser(userId: userId)
            await MainActor.run { dismiss(); appState.signOut() }
        } catch {
            await MainActor.run {
                dismiss()
                onFailure((error as? LocalizedError)?.errorDescription ?? "Could not delete your account. Please try again.")
            }
        }
    }
}
