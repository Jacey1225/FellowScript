// Sign-in / create-account screen (iPhone and iPad).
// SOURCE: frontend/src/pages/SignIn.jsx (tabs, icon fields, or divider, Google
// button, terms line). Presentation only: AuthView owns all state and auth
// logic and passes bindings plus action closures.
// Restyled onto the FSForm kit (task 20261023-forms-restyle): type C, S, TC1.
// One layout for both size classes: wordmark, Sign in / Create account
// segmented control, glass field card, social buttons, legal line, and a
// single pinned full-width primary.

import SwiftUI

struct AuthCardView: View {
    @Binding var isSignIn: Bool
    @Binding var username: String
    @Binding var email: String
    @Binding var password: String
    @Binding var termsAccepted: Bool
    @Binding var inviteCode: String
    @Binding var showInviteCode: Bool

    let errorMsg: String
    let isLoading: Bool
    let googleLoading: Bool
    let appleLoading: Bool
    let formValid: Bool

    let onSwitchTab: (Bool) -> Void
    let onSubmit: () -> Void
    let onGoogle: () -> Void
    let onApple: () -> Void
    let onForgotPassword: () -> Void

    @FocusState private var focusField: Field?
    private enum Field { case username, email, password }

    private static let termsURL = URL(string: "https://fellowscript.com/#/terms")!
    private static let privacyURL = URL(string: "https://fellowscript.com/#/privacy")!
    private var anyBusy: Bool { isLoading || googleLoading || appleLoading }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: Theme.spacingMD) {
                        VStack(spacing: Theme.spacingSM) {
                            WordmarkText()
                            Rectangle().fill(Theme.borderGray).frame(width: 40, height: 1)
                        }
                        .padding(.vertical, Theme.spacingLG)

                        FSSegmented(
                            options: [(id: true, title: "Sign In"), (id: false, title: "Create Account")],
                            selection: Binding(get: { isSignIn }, set: { onSwitchTab($0) })
                        )

                        if !errorMsg.isEmpty { FSInlineError(message: errorMsg) }

                        FSFormCard {
                            fields
                            if !isSignIn { signUpExtras }
                        }

                        if isSignIn {
                            Button(action: onForgotPassword) {
                                Text("Forgot password?")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.gold)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .accessibilityLabel("Forgot password")
                        }

                        orDivider
                        googleButton
                        appleButton
                        legalLine
                    }
                    .frame(maxWidth: 420)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.bottom, Theme.spacingLG)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)

                FSPinnedActionBar(
                    primaryTitle: isSignIn ? "Sign In" : "Create Account",
                    primaryDimmed: !formValid,
                    primaryAccessibilityLabel: isSignIn ? "Sign In button" : "Create Account button",
                    saving: isLoading,
                    onPrimary: { if formValid && !isLoading { dismissAndRun(onSubmit) } }
                )
            }
        }
        .preferredColorScheme(.dark)
        .dismissesKeyboardOnScrollAndTap()
    }

    // MARK: Fields

    private var fields: some View {
        VStack(spacing: Theme.spacingMD) {
            FSField(label: "Username", required: true, text: $username, leadingSymbol: "person",
                    accessibilityName: "Username field",
                    contentType: .username, capitalization: .never, autocorrect: false,
                    submitLabel: .next,
                    onSubmit: { focusField = isSignIn ? .password : .email })

            if !isSignIn {
                FSField(label: "Email", required: true, text: $email, leadingSymbol: "envelope",
                        accessibilityName: "Email field",
                        contentType: .emailAddress, keyboard: .emailAddress,
                        capitalization: .never, autocorrect: false,
                        submitLabel: .next,
                        onSubmit: { focusField = .password })
            }

            FSField(label: "Password", required: true, text: $password,
                    helper: isSignIn ? nil : "At least 6 characters.",
                    leadingSymbol: "lock",
                    accessibilityName: "Password field",
                    secure: true,
                    contentType: isSignIn ? .password : .newPassword,
                    capitalization: .never, autocorrect: false,
                    submitLabel: .done,
                    onSubmit: { if formValid { dismissAndRun(onSubmit) } })
        }
    }

    /// Sign-up only: 13+ line, EULA checkbox (Guideline 1.2), optional invite code.
    private var signUpExtras: some View {
        VStack(spacing: Theme.spacingSM) {
            Button(action: { termsAccepted.toggle() }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                        .foregroundColor(termsAccepted ? Theme.gold : Theme.textSecondary)
                    Text("I agree to the zero-tolerance policy for objectionable content and abusive behavior in our Terms of Service.")
                        .font(.fsHelper)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("I agree to the Terms of Service, including its zero-tolerance policy for objectionable content and abusive behavior.")
            .accessibilityAddTraits(termsAccepted ? [.isButton, .isSelected] : .isButton)

            Text("You must be 13 or older to create an account.")
                .font(.fsHelper)
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Optional invite code; a bad code never blocks signup.
            Button(action: { showInviteCode.toggle() }) {
                HStack {
                    Text("Have an invite code?")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.gold)
                    Spacer()
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("signupInviteDisclosure")
            if showInviteCode {
                FSField(label: "Invite code", optional: true, text: $inviteCode,
                        accessibilityId: "signupInviteCodeField",
                        keyboard: .asciiCapable, capitalization: .characters, autocorrect: false)
            }
        }
    }

    // MARK: Social buttons

    private var orDivider: some View {
        HStack(spacing: Theme.spacingSM) {
            Rectangle().fill(Theme.borderGray).frame(height: 1)
            Text("or").font(.fsHelper).foregroundColor(Theme.textSecondary)
            Rectangle().fill(Theme.borderGray).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    private var googleButton: some View {
        Button { dismissAndRun(onGoogle) } label: {
            HStack(spacing: Theme.spacingSM) {
                if googleLoading {
                    ProgressView().tint(Color(hex: "#3C3C3C"))
                    Text("Signing in…")
                } else {
                    Image("GoogleG").resizable().frame(width: 18, height: 18).accessibilityHidden(true)
                    Text("Continue with Google")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Color(hex: "#3C3C3C"))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .disabled(anyBusy)
        .accessibilityLabel("Continue with Google")
    }

    // Hand-built (not SignInWithAppleButton): see the regression note in AuthView.
    private var appleButton: some View {
        Button { dismissAndRun(onApple) } label: {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: "apple.logo").font(.system(size: 18, weight: .medium))
                Text("Continue with Apple").font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay {
                if appleLoading {
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .fill(Color.black.opacity(0.35))
                        .overlay(ProgressView().tint(.white))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(anyBusy)
        .accessibilityLabel("Sign in with Apple")
    }

    // MARK: Legal

    private var legalLine: some View {
        (Text("By creating an account, you agree to our ")
            + Text("[Terms of Service](\(Self.termsURL.absoluteString))")
            + Text(" and ")
            + Text("[Privacy Policy](\(Self.privacyURL.absoluteString))")
            + Text("."))
            .font(.fsHelper)
            .foregroundColor(Theme.textSecondary)
            .tint(Theme.gold)
            .multilineTextAlignment(.center)
    }

    private func dismissAndRun(_ action: () -> Void) {
        focusField = nil
        action()
    }
}
