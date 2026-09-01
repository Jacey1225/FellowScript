// Shown when AppState.needsProfileCompletion is set — an Apple sign-in created
// this account without a real name/email. Apple only ever supplies those on the
// very first authorization for a given Apple ID + app, so if that grant was
// missed there is no way to ask Apple for it again; the user sets them here
// instead.

import SwiftUI

struct CompleteProfileView: View {
    @EnvironmentObject var appState: AppState
    @State private var username = ""
    @State private var email    = ""
    @State private var errorMsg: String?
    @State private var saving   = false

    private var formValid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@")
    }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            VStack(spacing: Theme.spacingLG) {
                Spacer()

                Text("Finish setting up your account")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center)

                Text("Apple didn't share a name or email for this sign-in, so we couldn't set them up for you. Please choose a username and email to continue — this only needs to happen once.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLG)

                VStack(spacing: Theme.spacingMD) {
                    FSTextField(placeholder: "Username", icon: "person", text: $username, isSecure: false)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .accessibilityLabel("Username field")

                    FSTextField(placeholder: "Email", icon: "envelope", text: $email, isSecure: false)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .accessibilityLabel("Email field")
                }
                .padding(.horizontal, Theme.spacingLG)
                .padding(.top, Theme.spacingSM)

                if let errorMsg {
                    Text(errorMsg)
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.spacingLG)
                }

                Spacer()

                Button(action: submit) {
                    HStack {
                        if saving { ProgressView().tint(Theme.ink) }
                        Text("Continue").font(.inter(Theme.fontSM)).bold()
                    }
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingMD)
                    .background(formValid ? Theme.gold : Theme.gold.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .disabled(!formValid || saving)
                .padding(.horizontal, Theme.spacingLG)
                .padding(.bottom, Theme.spacingXL)
                .accessibilityLabel("Continue with this username and email")
            }
        }
        // Shared keyboard-dismiss convention (task
        // 20260831-interaction-polish-conventions) — covers the
        // username/email fields above.
        .dismissesKeyboardOnScrollAndTap()
    }

    private func submit() {
        errorMsg = nil
        Task {
            saving = true
            defer { saving = false }
            do {
                try await appState.completeProfile(
                    username: username.trimmingCharacters(in: .whitespaces),
                    email: email.trimmingCharacters(in: .whitespaces)
                )
            } catch {
                errorMsg = error.localizedDescription
            }
        }
    }
}
