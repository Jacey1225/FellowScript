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
        NavigationStack {
            VStack(spacing: Theme.spacingMD) {
                Text("Enter the 6-digit code we just emailed you to confirm two-factor authentication.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLG)

                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.parchment)
                    .padding(Theme.spacingMD)
                    .background(Theme.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .padding(.horizontal, Theme.spacingLG)

                Spacer()
            }
            .padding(.top, Theme.spacingLG)
            .background(Theme.bgPage)
            .navigationTitle("Confirm 2FA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel).foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Confirm", action: onConfirm)
                            .foregroundColor(Theme.gold)
                            .disabled(code.isEmpty)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct MfaDisableSheet: View {
    @Binding var password: String
    let isLoading: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.spacingMD) {
                Text("Enter your current password to turn off two-factor authentication.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLG)

                SecureField("Current password", text: $password)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .padding(Theme.spacingMD)
                    .background(Theme.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .padding(.horizontal, Theme.spacingLG)

                Spacer()
            }
            .padding(.top, Theme.spacingLG)
            .background(Theme.bgPage)
            .navigationTitle("Turn Off 2FA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel).foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Turn Off", action: onConfirm)
                            .foregroundColor(.red)
                            .disabled(password.isEmpty)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
