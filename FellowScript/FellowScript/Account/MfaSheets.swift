// Confirmation sheets for turning email-based 2FA on/off from AccountView.
// Enabling requires confirming an emailed code first (so a mistyped email
// can't lock the account out of future logins); disabling requires the
// current password (so a hijacked/unattended session can't silently remove
// the account's second factor).

import SwiftUI

struct MfaSetupSheet: View {
    @Binding var code: String
    let isLoading: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        FSFormScaffold(
            title: "Confirm 2FA",
            onClose: onCancel,
            content: {
                FSFormCard {
                    Text("Enter the 6-digit code we just emailed you to confirm two-factor authentication.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                    FSCodeField(label: "Verification code", code: $code)
                }
            },
            bar: {
                FSPinnedActionBar(secondaryTitle: "Cancel", onSecondary: onCancel,
                                  primaryTitle: "Confirm", primaryDimmed: code.isEmpty,
                                  saving: isLoading,
                                  onPrimary: { if !code.isEmpty && !isLoading { onConfirm() } })
            }
        )
        // Shared keyboard-dismiss convention (task 20260831-interaction-polish-conventions).
        .dismissesKeyboardOnScrollAndTap()
        .preferredColorScheme(.dark)
    }
}

struct MfaDisableSheet: View {
    @Binding var password: String
    let isLoading: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        FSFormScaffold(
            title: "Turn Off 2FA",
            onClose: onCancel,
            content: {
                FSFormCard {
                    Text("Enter your current password to turn off two-factor authentication.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                    FSField(label: "Current password", required: true, text: $password,
                            secure: true, contentType: .password,
                            capitalization: .never, autocorrect: false,
                            onSubmit: { if !password.isEmpty && !isLoading { onConfirm() } })
                }
            },
            bar: {
                FSPinnedActionBar(secondaryTitle: "Cancel", onSecondary: onCancel,
                                  primaryTitle: "Turn Off", primaryDimmed: password.isEmpty,
                                  primaryDestructive: true, saving: isLoading,
                                  onPrimary: { if !password.isEmpty && !isLoading { onConfirm() } })
            }
        )
        // Shared keyboard-dismiss convention (task 20260831-interaction-polish-conventions).
        .dismissesKeyboardOnScrollAndTap()
        .preferredColorScheme(.dark)
    }
}
