// SOURCE: frontend/src/pages/SignIn.jsx
// KEY STATE: isSignIn, username, email, password, isLoading, errorMessage
// INTERACTIONS: toggle sign-in / sign-up, submit form, navigate to Dashboard on success
// DEPENDENCY: AppState.swift, Theme.swift

import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var initialSignIn: Bool = true
    var onComplete: (() -> Void)? = nil

    @State private var isSignIn    = true
    @State private var username    = ""
    @State private var email       = ""
    @State private var password    = ""
    @State private var errorMsg    = ""
    @State private var isLoading     = false
    @State private var googleLoading = false
    @State private var appleLoading  = false
    // Guideline 1.2 EULA gate — required for all three account-creation
    // paths (password, Google, Apple), not just the plain sign-up button.
    @State private var termsAccepted = false
    @State private var pendingMfaUserId: String? = nil
    @State private var showForgotPassword = false
    @FocusState private var focusField: Field?

    private enum Field { case username, email, password }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.spacingXL) {
                    Spacer(minLength: 60)

                    // Brand logotype — mirrors SignIn.jsx title
                    VStack(spacing: Theme.spacingSM) {
                        HStack(spacing: 0) {
                            Text("Fellow")
                                .font(.playfair(Theme.fontDisplayLG))
                                .foregroundColor(Theme.parchment)
                            Text("Script")
                                .font(.custom("Georgia-BoldItalic", size: Theme.fontDisplayLG))
                                .foregroundColor(Theme.gold)
                        }
                        .accessibilityLabel("FellowScript")

                        Rectangle()
                            .fill(Theme.borderGold)
                            .frame(width: 40, height: 1)
                    }

                    // Card
                    VStack(spacing: 0) {

                        // Tab toggle — matches Tabs in SignIn.jsx
                        HStack(spacing: 0) {
                            tabButton(title: "Sign In",       selected: isSignIn)  { withMotionAwareAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion) { isSignIn = true;  clearForm() } }
                            tabButton(title: "Create Account", selected: !isSignIn) { withMotionAwareAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion) { isSignIn = false; clearForm() } }
                        }
                        .padding(.bottom, Theme.spacingMD)

                        // Error banner
                        if !errorMsg.isEmpty {
                            HStack(spacing: Theme.spacingSM) {
                                Image(systemName: "exclamationmark.circle.fill")
                                Text(errorMsg)
                                    .font(.inter(Theme.fontSM))
                            }
                            .foregroundColor(Theme.error)
                            .padding(Theme.spacingSM)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.error.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
                            .transition(.opacity)
                            .padding(.bottom, Theme.spacingSM)
                        }

                        // Form fields
                        VStack(spacing: Theme.spacingMD) {
                            // Username — always shown
                            FSTextField(placeholder: "Username",
                                        icon: "person",
                                        text: $username,
                                        isSecure: false)
                                .focused($focusField, equals: .username)
                                .submitLabel(isSignIn ? .next : .next)
                                .onSubmit { focusField = isSignIn ? .password : .email }
                                .accessibilityLabel("Username field")

                            // Email — sign-up only (matches field order in SignIn.jsx)
                            if !isSignIn {
                                FSTextField(placeholder: "Email",
                                            icon: "envelope",
                                            text: $email,
                                            isSecure: false)
                                    .focused($focusField, equals: .email)
                                    .keyboardType(.emailAddress)
                                    .textContentType(.emailAddress)
                                    .autocapitalization(.none)
                                    .submitLabel(.next)
                                    .onSubmit { focusField = .password }
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                    .accessibilityLabel("Email field")
                            }

                            // Password
                            FSTextField(placeholder: "Password",
                                        icon: "lock",
                                        text: $password,
                                        isSecure: true)
                                .focused($focusField, equals: .password)
                                .textContentType(isSignIn ? .password : .newPassword)
                                .submitLabel(.done)
                                .onSubmit { Task { await submit() } }
                                .accessibilityLabel("Password field")

                            if isSignIn {
                                HStack {
                                    Spacer()
                                    Button(action: { showForgotPassword = true }) {
                                        Text("Forgot password?")
                                            .font(.inter(Theme.fontXS))
                                            .foregroundColor(Theme.gold)
                                    }
                                    .accessibilityLabel("Forgot password")
                                }
                            }
                        }

                        // Submit button
                        Button(action: { Task { await submit() } }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .tint(Theme.ink)
                                } else {
                                    Text(isSignIn ? "Sign In" : "Create Account")
                                        .font(.inter(Theme.fontSM))
                                        .tracking(2)
                                        .textCase(.uppercase)
                                }
                            }
                            .foregroundColor(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingMD)
                            .background(isLoading ? Theme.gold.opacity(0.7) : Theme.gold)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        }
                        .disabled(isLoading || !formValid)
                        .padding(.top, Theme.spacingMD)
                        .accessibilityLabel(isSignIn ? "Sign In button" : "Create Account button")

                        // Google Sign-In
                        HStack {
                            Rectangle().fill(Theme.borderGoldDim).frame(height: 1)
                            Text("or")
                                .font(.inter(Theme.fontXS))
                                .foregroundColor(Theme.textMuted)
                            Rectangle().fill(Theme.borderGoldDim).frame(height: 1)
                        }
                        .padding(.vertical, Theme.spacingSM)

                        Button(action: { Task { await signInWithGoogle() } }) {
                            HStack(spacing: Theme.spacingSM) {
                                if googleLoading {
                                    ProgressView().tint(Theme.parchment)
                                } else {
                                    Image(systemName: "globe")
                                        .foregroundColor(Theme.parchment)
                                    Text("Continue with Google")
                                        .font(.inter(Theme.fontSM))
                                        .foregroundColor(Theme.parchment)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingMD)
                            .background(Color(white: 0.15))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radius)
                                    .stroke(Theme.borderGoldDim, lineWidth: 1)
                            )
                        }
                        .disabled(googleLoading || isLoading)
                        .accessibilityLabel("Continue with Google")

                        // Sign in with Apple — required by Guideline 4.8 whenever a
                        // third-party social login (Google) is offered.
                        //
                        // Root cause (task 20260903-apple-signin-no-response): SwiftUI's
                        // SignInWithAppleButton (the ASAuthorizationAppleIDButton-backed
                        // UIViewRepresentable) never invoked its own request-building
                        // closure on tap in this view — confirmed live via 4 separate
                        // real XCUITest tap reproductions (full view, with/without the
                        // shared dismissesKeyboardOnScrollAndTap() modifier ruled out as
                        // the cause, with .disabled forced false, and a bare
                        // SignInWithAppleButton with zero surrounding modifiers in an
                        // isolated top-level ZStack) — every other Button in this exact
                        // view (Google, tab toggle, submit) fired reliably across the
                        // same taps. That isolates the bug to the native control's own
                        // UIKit touch-to-target-action forwarding, not this app's
                        // layout/gestures/state. Manually driving ASAuthorizationController
                        // from a plain SwiftUI Button (still Apple's own native auth
                        // APIs underneath — see AppleAuthSession.swift, same
                        // withCheckedContinuation + presentation-anchor pattern already
                        // established by GoogleAuthSession's ASWebAuthenticationSession
                        // bridge) sidesteps the broken control while keeping every
                        // downstream piece (handleAppleCompletion, AppState,
                        // NetworkService, backend) unchanged.
                        //
                        // Re-evaluated for ios-guidelines #4 (20260904-frontend-arch-
                        // sweep, "hand-built Apple sign-in button bypasses native HIG
                        // conformance"): not reverted to SignInWithAppleButton --
                        // that would resurrect the exact broken-tap regression this
                        // task fixed. Current styling (white background, black text,
                        // Apple logo + "Continue with Apple", 50pt height) matches a
                        // currently-approved HIG variant per that sweep's own review;
                        // re-diff against Apple's Sign in with Apple button HIG page
                        // if this button is touched again.
                        Button(action: { Task { await performAppleSignIn() } }) {
                            HStack(spacing: Theme.spacingSM) {
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 18, weight: .medium))
                                Text("Continue with Apple")
                                    .font(.inter(Theme.fontSM))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        }
                        .padding(.top, Theme.spacingSM)
                        .disabled(appleLoading || googleLoading || isLoading)
                        .overlay {
                            if appleLoading {
                                RoundedRectangle(cornerRadius: Theme.radius)
                                    .fill(Color.black.opacity(0.35))
                                    .overlay(ProgressView().tint(.white))
                            }
                        }
                        .accessibilityLabel("Sign in with Apple")

                        // Privacy acknowledgment — required by Apple Guideline 5.1.1
                        if !isSignIn {
                            VStack(spacing: 4) {
                                Text("You must be 13 or older to create an account.")
                                    .font(.inter(Theme.fontXXS))
                                    .foregroundColor(Theme.textMuted)
                                    .multilineTextAlignment(.center)
                                HStack(spacing: 8) {
                                    Link("Terms of Service",
                                         destination: URL(string: "https://fellowscript.com/#/terms")!)
                                    Text("·").foregroundColor(Theme.textMuted)
                                    Link("Privacy Policy",
                                         destination: URL(string: "https://fellowscript.com/#/privacy")!)
                                }
                                .font(.inter(Theme.fontXXS))
                                .foregroundColor(Theme.gold)
                            }
                            .padding(.top, Theme.spacingXS)
                            .accessibilityLabel("You must be 13 or older. View our Terms of Service and Privacy Policy.")

                            // Guideline 1.2 — required EULA acceptance, gates the sign-up
                            // button AND the Google/Apple buttons above.
                            Button(action: { termsAccepted.toggle() }) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: termsAccepted ? "checkmark.square.fill" : "square")
                                        .foregroundColor(termsAccepted ? Theme.gold : Theme.textMuted)
                                    Text("I agree to the zero-tolerance policy for objectionable content and abusive behavior in our Terms of Service.")
                                        .font(.inter(Theme.fontXXS))
                                        .foregroundColor(Theme.textMuted)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.top, Theme.spacingXS)
                            .accessibilityLabel("I agree to the Terms of Service, including its zero-tolerance policy for objectionable content and abusive behavior.")
                            .accessibilityAddTraits(termsAccepted ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .widgetCard()
                    .padding(.horizontal, Theme.spacingLG)

                    Spacer(minLength: 40)
                }
            }
        }
        // Shared keyboard-dismiss convention (task
        // 20260831-interaction-polish-conventions) — covers the
        // username/email/password fields above.
        .dismissesKeyboardOnScrollAndTap()
        .onAppear { isSignIn = initialSignIn }
        .fullScreenCover(isPresented: Binding(
            get: { pendingMfaUserId != nil },
            set: { if !$0 { pendingMfaUserId = nil } }
        )) {
            if let uid = pendingMfaUserId {
                MfaVerifyView(userId: uid, onComplete: {
                    pendingMfaUserId = nil
                    onComplete?()
                })
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordView()
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private var formValid: Bool {
        guard !username.isEmpty && !password.isEmpty else { return false }
        if !isSignIn { return email.contains("@") && password.count >= 6 && termsAccepted }
        return true
    }

    private func clearForm() {
        username = ""; email = ""; password = ""; errorMsg = ""; termsAccepted = false
    }

    private func signInWithGoogle() async {
        errorMsg = ""
        // Guideline 4.8: never gate this tap on the EULA checkbox — Google
        // sign-in must always be available with the same ease as other
        // options. If the account is new and terms weren't accepted yet, the
        // server creates it anyway and signals terms_reaccept_required so
        // AppState/finishAuth can prompt for consent right after, instead of
        // this tap silently failing.
        googleLoading = true
        focusField = nil
        defer { googleLoading = false }
        guard let credential = await GoogleAuthSession.signIn() else {
            errorMsg = "Google sign-in was cancelled."
            return
        }
        do {
            try await appState.signInWithGoogle(credential: credential, termsAccepted: termsAccepted)
            onComplete?()
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    /// Manually drives ASAuthorizationController (via AppleAuthSession) rather
    /// than relying on SignInWithAppleButton's own touch handling — see the
    /// button's comment above for why. Feeds the exact same
    /// Result<ASAuthorization, Error> shape into handleAppleCompletion, so
    /// every downstream success/failure/cancellation branch is unchanged.
    private func performAppleSignIn() async {
        let result = await AppleAuthSession.signIn(requestedScopes: [.fullName, .email])
        handleAppleCompletion(result)
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        errorMsg = ""
        // Guideline 4.8: never gate this on the EULA checkbox. Apple supplies
        // full_name/email exactly once, ever, per Apple ID + app — blocking
        // this call on an unchecked box would burn that one-time grant
        // permanently. The server creates the account regardless and signals
        // terms_reaccept_required to prompt for consent right after.
        switch result {
        case .failure(let error):
            // User cancellation is not an error worth surfacing.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMsg = "Apple sign-in failed. Please try again."

        case .success(let auth):
            guard
                let cred  = auth.credential as? ASAuthorizationAppleIDCredential,
                let data  = cred.identityToken,
                let token = String(data: data, encoding: .utf8)
            else {
                errorMsg = "Apple sign-in did not return a valid token."
                return
            }
            // Name/email are only provided on the first authorization; join name parts.
            var name: String? = nil
            if let nc = cred.fullName {
                let joined = [nc.givenName, nc.familyName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                name = joined.isEmpty ? nil : joined
            }
            let email = cred.email

            Task {
                appleLoading = true
                focusField = nil
                defer { appleLoading = false }
                do {
                    try await appState.signInWithApple(
                        identityToken: token, fullName: name, email: email, termsAccepted: termsAccepted
                    )
                    onComplete?()
                } catch {
                    errorMsg = error.localizedDescription
                }
            }
        }
    }

    private func submit() async {
        errorMsg  = ""
        isLoading = true
        focusField = nil
        defer { isLoading = false }

        do {
            if isSignIn {
                try await appState.signIn(username: username, password: password)
            } else {
                try await appState.signUp(username: username, email: email, password: password, termsAccepted: termsAccepted)
            }
            onComplete?()
        } catch AppError.mfaRequired(let userId) {
            pendingMfaUserId = userId
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    @ViewBuilder
    private func tabButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(selected ? Theme.gold : Theme.textMuted)
                Rectangle()
                    .fill(selected ? Theme.gold : Color.clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// ── Shared text field ─────────────────────────────────────────────────────────
struct FSTextField: View {
    let placeholder: String
    let icon: String
    @Binding var text: String
    let isSecure: Bool

    var body: some View {
        HStack(spacing: Theme.spacingSM) {
            Image(systemName: icon)
                .foregroundColor(Theme.textGoldMuted)
                .frame(width: 18)
                .accessibilityHidden(true)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.textPrimary)
                    .autocapitalization(.none)
            } else {
                TextField(placeholder, text: $text)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.textPrimary)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }
        .padding(Theme.spacingMD)
        .background(Theme.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(Theme.borderGoldDim, lineWidth: 1)
        )
    }
}
