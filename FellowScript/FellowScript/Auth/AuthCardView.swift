// iPad (regular width) sign-in / create-account card.
// SOURCE: frontend/src/pages/SignIn.jsx (card, tabs, icon fields, or divider,
// Google button, terms line). Presentation only: AuthView owns all state and
// auth logic and passes bindings plus action closures. Colours come from Theme;
// the warm brown canvas is Theme's warmCanvasBackground().

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
    private let fieldFill = Color(hex: "#FFE8BE").opacity(0.08)
    private let fieldBorder = Color(hex: "#FFE1AA").opacity(0.22)
    private var secondaryText: Color { Theme.parchment.opacity(0.65) }
    private var anyBusy: Bool { isLoading || googleLoading || appleLoading }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: Theme.spacingMD) {
                    card
                    legalLine
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, Theme.spacingLG)
                .padding(.vertical, Theme.spacingXL)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .warmCanvasBackground()
        .dismissesKeyboardOnScrollAndTap()
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.spacingSM) {
                WordmarkText()
                Rectangle().fill(Theme.borderGold).frame(width: 40, height: 1)
            }
            .padding(.bottom, Theme.spacingMD)

            tabs
            if !errorMsg.isEmpty { errorBanner }
            fields
            if !isSignIn { signUpExtras }
            primaryButton
            orDivider
            googleButton
            appleButton
        }
        .padding(Theme.spacingLG)
        .background(Color(hex: "#5C442A").opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: "#FFE1AA").opacity(0.16), lineWidth: 1))
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tab("Sign In", selected: isSignIn) { onSwitchTab(true) }
            tab("Create Account", selected: !isSignIn) { onSwitchTab(false) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderGoldDim).frame(height: 1) }
        .padding(.bottom, Theme.spacingMD)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.inter(Theme.fontSM, weight: .semibold))
                    .foregroundColor(selected ? Theme.gold : secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 42)
                Rectangle().fill(selected ? Theme.gold : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var errorBanner: some View {
        HStack(spacing: Theme.spacingSM) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(errorMsg).font(.inter(Theme.fontSM))
        }
        .foregroundColor(Theme.error)
        .padding(Theme.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.error.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
        .padding(.bottom, Theme.spacingSM)
    }

    // MARK: Fields

    private var fields: some View {
        VStack(spacing: 12) {
            FSTextField(placeholder: "Username", icon: "person", text: $username, isSecure: false)
                .focused($focusField, equals: .username)
                .submitLabel(.next)
                .onSubmit { focusField = isSignIn ? .password : .email }
                .accessibilityLabel("Username field")

            if !isSignIn {
                FSTextField(placeholder: "Email", icon: "envelope", text: $email, isSecure: false)
                    .focused($focusField, equals: .email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .submitLabel(.next)
                    .onSubmit { focusField = .password }
                    .accessibilityLabel("Email field")
            }

            FSTextField(placeholder: "Password", icon: "lock", text: $password,
                        isSecure: true, showsRevealToggle: true)
                .focused($focusField, equals: .password)
                .textContentType(isSignIn ? .password : .newPassword)
                .submitLabel(.done)
                .onSubmit { dismissAndRun(onSubmit) }
                .accessibilityLabel("Password field")

            if isSignIn {
                HStack {
                    Spacer()
                    Button(action: onForgotPassword) {
                        Text("Forgot password?")
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.gold)
                            .frame(minHeight: 44)
                    }
                    .accessibilityLabel("Forgot password")
                }
                .padding(.top, -8)
            }
        }
    }

    /// Sign-up only: 13+ line, EULA checkbox (Guideline 1.2), optional invite code.
    private var signUpExtras: some View {
        VStack(spacing: Theme.spacingSM) {
            Button(action: { termsAccepted.toggle() }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                        .foregroundColor(termsAccepted ? Theme.gold : secondaryText)
                    Text("I agree to the zero-tolerance policy for objectionable content and abusive behavior in our Terms of Service.")
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(secondaryText)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("I agree to the Terms of Service, including its zero-tolerance policy for objectionable content and abusive behavior.")
            .accessibilityAddTraits(termsAccepted ? [.isButton, .isSelected] : .isButton)

            Text("You must be 13 or older to create an account.")
                .font(.inter(Theme.fontXS))
                .foregroundColor(secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Optional invite code; a bad code never blocks signup.
            Button(action: { showInviteCode.toggle() }) {
                Text("Have an invite code?")
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold)
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("signupInviteDisclosure")
            if showInviteCode {
                TextField("Invite code", text: $inviteCode)
                    .font(.inter(Theme.fontBody)).foregroundColor(Theme.parchment)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    .padding(Theme.spacingSM)
                    .background(fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(fieldBorder, lineWidth: 1))
                    .accessibilityIdentifier("signupInviteCodeField")
            }
        }
        .padding(.top, Theme.spacingSM)
    }

    // MARK: Buttons

    private var primaryButton: some View {
        Button { dismissAndRun(onSubmit) } label: {
            Group {
                if isLoading { ProgressView().tint(Theme.ink) }
                else { Text(isSignIn ? "Sign In" : "Create Account").font(.inter(Theme.fontBody, weight: .semibold)) }
            }
            .foregroundColor(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.gold)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .opacity(formValid ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || !formValid)
        .padding(.top, Theme.spacingMD)
        .accessibilityLabel(isSignIn ? "Sign In button" : "Create Account button")
    }

    private var orDivider: some View {
        HStack(spacing: Theme.spacingSM) {
            Rectangle().fill(Theme.borderGoldDim).frame(height: 1)
            Text("or").font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
            Rectangle().fill(Theme.borderGoldDim).frame(height: 1)
        }
        .padding(.vertical, Theme.spacingMD)
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
            .font(.inter(Theme.fontSM, weight: .medium))
            .foregroundColor(Color(hex: "#3C3C3C"))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.gold.opacity(0.25), lineWidth: 1))
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
                Text("Continue with Apple").font(.inter(Theme.fontSM, weight: .medium))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, minHeight: 48)
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
        .padding(.top, 10)
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
            .font(.inter(Theme.fontXS))
            .foregroundColor(Theme.parchment.opacity(0.7))
            .tint(Theme.gold)
            .multilineTextAlignment(.center)
    }

    private func dismissAndRun(_ action: () -> Void) {
        focusField = nil
        action()
    }
}
