// SOURCE: frontend/src/pages/SignIn.jsx
// KEY STATE: isSignIn, username, email, password, isLoading, errorMessage
// INTERACTIONS: toggle sign-in / sign-up, submit form, navigate to Dashboard on success
// DEPENDENCY: AppState.swift, Theme.swift

import SwiftUI

struct AuthView: View {
    @EnvironmentObject var appState: AppState

    var initialSignIn: Bool = true
    var onComplete: (() -> Void)? = nil

    @State private var isSignIn    = true
    @State private var username    = ""
    @State private var email       = ""
    @State private var password    = ""
    @State private var errorMsg    = ""
    @State private var isLoading     = false
    @State private var googleLoading = false
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
                            tabButton(title: "Sign In",       selected: isSignIn)  { withAnimation(.easeInOut(duration: 0.2)) { isSignIn = true;  clearForm() } }
                            tabButton(title: "Create Account", selected: !isSignIn) { withAnimation(.easeInOut(duration: 0.2)) { isSignIn = false; clearForm() } }
                        }
                        .padding(.bottom, Theme.spacingMD)

                        // Error banner
                        if !errorMsg.isEmpty {
                            HStack(spacing: Theme.spacingSM) {
                                Image(systemName: "exclamationmark.circle.fill")
                                Text(errorMsg)
                                    .font(.lora(Theme.fontSM))
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
                        }

                        // Submit button
                        Button(action: { Task { await submit() } }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .tint(Theme.ink)
                                } else {
                                    Text(isSignIn ? "Sign In" : "Create Account")
                                        .font(.lora(Theme.fontSM))
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
                                .font(.lora(Theme.fontXS))
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
                                        .font(.lora(Theme.fontSM))
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

                        // Privacy acknowledgment — required by Apple Guideline 5.1.1
                        if !isSignIn {
                            VStack(spacing: 4) {
                                Text("You must be 13 or older to create an account.")
                                    .font(.lora(Theme.fontXXS))
                                    .foregroundColor(Theme.textMuted)
                                    .multilineTextAlignment(.center)
                                HStack(spacing: 8) {
                                    Link("Terms of Service",
                                         destination: URL(string: "https://fellowscript.com/#/terms")!)
                                    Text("·").foregroundColor(Theme.textMuted)
                                    Link("Privacy Policy",
                                         destination: URL(string: "https://fellowscript.com/#/privacy")!)
                                }
                                .font(.lora(Theme.fontXXS))
                                .foregroundColor(Theme.gold)
                            }
                            .padding(.top, Theme.spacingXS)
                            .accessibilityLabel("You must be 13 or older. View our Terms of Service and Privacy Policy.")
                        }
                    }
                    .widgetCard()
                    .padding(.horizontal, Theme.spacingLG)

                    Spacer(minLength: 40)
                }
            }
        }
        .onAppear { isSignIn = initialSignIn }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private var formValid: Bool {
        guard !username.isEmpty && !password.isEmpty else { return false }
        if !isSignIn { return email.contains("@") && password.count >= 6 }
        return true
    }

    private func clearForm() {
        username = ""; email = ""; password = ""; errorMsg = ""
    }

    private func signInWithGoogle() async {
        errorMsg = ""
        googleLoading = true
        focusField = nil
        defer { googleLoading = false }
        guard let credential = await GoogleAuthSession.signIn() else {
            errorMsg = "Google sign-in was cancelled."
            return
        }
        do {
            try await appState.signInWithGoogle(credential: credential)
            onComplete?()
        } catch {
            errorMsg = error.localizedDescription
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
                try await appState.signUp(username: username, email: email, password: password)
            }
            onComplete?()
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    @ViewBuilder
    private func tabButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.lora(Theme.fontSM))
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
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.textPrimary)
                    .autocapitalization(.none)
            } else {
                TextField(placeholder, text: $text)
                    .font(.lora(Theme.fontBody))
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
