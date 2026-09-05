// AccountView+TwoFactor.swift — Two-factor authentication (email code)
// toggle, setup, and disable flows. Split out of AccountView.swift
// (readability #6, 20260904-frontend-arch-sweep) -- same type, same
// behavior, just this section's own file. See AccountView.swift's header
// comment for the full split rationale and the list of sibling section
// files.

import SwiftUI

extension AccountView {

    var twoFactorSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Two-Factor Authentication")

            if !mfaMsg.isEmpty {
                Text(mfaMsg)
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(mfaMsgIsError ? .red : Theme.gold)
            }
            Toggle(isOn: Binding(
                get: { mfaEnabled },
                set: { newValue in Task { await handleMfaToggle(newValue) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Two-Factor Authentication")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Text("Emails a 6-digit code to \(appState.currentUser?.email ?? "your email") every time you sign in.")
                        .font(.inter(Theme.fontXXS))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .disabled(mfaLoading)
            .tint(Theme.gold)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
        .sheet(isPresented: $showMfaSetup) {
            MfaSetupSheet(
                code: $mfaSetupCode,
                isLoading: mfaSetupLoading,
                onConfirm: { Task { await handleMfaConfirm() } },
                onCancel: { showMfaSetup = false; mfaSetupCode = "" }
            )
        }
        .sheet(isPresented: $showMfaDisable) {
            MfaDisableSheet(
                password: $mfaDisablePassword,
                isLoading: mfaDisableLoading,
                onConfirm: { Task { await handleMfaDisableConfirm() } },
                onCancel: { showMfaDisable = false; mfaDisablePassword = "" }
            )
        }
    }

    func handleMfaToggle(_ newValue: Bool) async {
        mfaMsg = ""
        if !newValue {
            showMfaDisable = true
            return
        }
        mfaLoading = true
        defer { mfaLoading = false }
        do {
            try await appState.service.mfaEnable()
            showMfaSetup = true
        } catch {
            mfaMsgIsError = true
            mfaMsg = error.localizedDescription
        }
    }

    func handleMfaConfirm() async {
        mfaSetupLoading = true
        defer { mfaSetupLoading = false }
        do {
            try await appState.service.mfaConfirm(code: mfaSetupCode)
            mfaEnabled = true
            if var user = appState.currentUser { user.mfa_enabled = true; appState.updateUser(user) }
            showMfaSetup = false
            mfaSetupCode = ""
            mfaMsgIsError = false
            mfaMsg = "Two-factor authentication is now on."
        } catch {
            mfaMsgIsError = true
            mfaMsg = error.localizedDescription
        }
    }

    func handleMfaDisableConfirm() async {
        mfaDisableLoading = true
        defer { mfaDisableLoading = false }
        do {
            try await appState.service.mfaDisable(password: mfaDisablePassword)
            mfaEnabled = false
            if var user = appState.currentUser { user.mfa_enabled = false; appState.updateUser(user) }
            showMfaDisable = false
            mfaDisablePassword = ""
            mfaMsgIsError = false
            mfaMsg = "Two-factor authentication is now off."
        } catch {
            mfaMsgIsError = true
            mfaMsg = error.localizedDescription
        }
    }
}
