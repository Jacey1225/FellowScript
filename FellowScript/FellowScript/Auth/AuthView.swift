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
    // Optional friend invite code, sent as `invite_code` at email signup only.
    @State private var inviteCode = ""
    @State private var showInviteCode = false
    @State private var pendingMfaUserId: String? = nil
    @State private var showForgotPassword = false
    @FocusState private var focusField: Field?

    private enum Field { case username, email, password }

    var body: some View {
        authCard
    }

    /// Sign-in / create-account screen for every size class. All state and auth
    /// logic stay in this view; AuthCardView is presentation only.
    private var authCard: some View {
        AuthCardView(
            isSignIn: $isSignIn, username: $username, email: $email, password: $password,
            termsAccepted: $termsAccepted, inviteCode: $inviteCode, showInviteCode: $showInviteCode,
            errorMsg: errorMsg, isLoading: isLoading, googleLoading: googleLoading, appleLoading: appleLoading,
            formValid: formValid,
            onSwitchTab: { signIn in
                withMotionAwareAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion) { isSignIn = signIn; clearForm() }
            },
            onSubmit: { Task { await submit() } },
            onGoogle: { Task { await signInWithGoogle() } },
            onApple: { Task { await performAppleSignIn() } },
            onForgotPassword: { showForgotPassword = true }
        )
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
        .sheet(isPresented: $showForgotPassword) { ForgotPasswordView() }
    }

    // Apple button (hand-built in AuthCardView):
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

    // ── Helpers ───────────────────────────────────────────────────────────────

    private var formValid: Bool {
        guard !username.isEmpty && !password.isEmpty else { return false }
        if !isSignIn { return email.contains("@") && password.count >= 6 && termsAccepted }
        return true
    }

    private func clearForm() {
        username = ""; email = ""; password = ""; errorMsg = ""; termsAccepted = false; inviteCode = ""
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
                let trimmedInvite = InviteCodeViewModel.normalize(inviteCode)
                try await appState.signUp(username: username, email: email, password: password, termsAccepted: termsAccepted,
                                          inviteCode: trimmedInvite.isEmpty ? nil : trimmedInvite)
            }
            onComplete?()
        } catch AppError.mfaRequired(let userId) {
            pendingMfaUserId = userId
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
