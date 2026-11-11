import SwiftUI

// MARK: - Pre-auth orchestrator ───────────────────────────────────────────────
// Task 20261105-onboarding-redo: welcome -> survey -> sign-in. The hands-on
// walkthrough, add-a-friend and recap run AFTER sign-in over the live app
// (see OnboardingEngine / OnboardingCoachOverlay). This cover only owns the
// pre-auth screens; `onComplete` fires once the user is signed in.

struct OnboardingView: View {
    var onComplete: () -> Void

    private enum Phase: Hashable { case welcome, survey, signIn }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @State private var phase      = Phase.welcome
    @State private var showAuth   = false
    @State private var authSignIn = true

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()
            if phase != .survey {
                VStack {
                    // Frame must be at least 2xendRadius tall: a RadialGradient fades to
                    // `.clear` at endRadius from its own center, so a shorter frame clips
                    // the fade into a hard edge.
                    RadialGradient(
                        colors: [Theme.gold.opacity(0.22), .clear],
                        center: .center, startRadius: 0, endRadius: 250
                    )
                    .frame(height: 500).offset(y: -165)
                    Spacer()
                }
                .ignoresSafeArea()
            }

            Group {
                switch phase {
                case .welcome:
                    OBWelcome(onNext: go(.survey))
                case .survey:
                    OnboardingSurveyView { picks in
                        OnboardingEngine.shared.savePicks(picks)
                        // Already signed in (restored session): nothing to ask.
                        if appState.isAuthenticated { onComplete() } else { phase = .signIn }
                    }
                case .signIn:
                    OBCta(
                        onSignIn: { authSignIn = true;  showAuth = true },
                        onCreate: { authSignIn = false; showAuth = true }
                    )
                }
            }
            .id(phase)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal:   .opacity
            ))
            // Single source of truth for this transition's animation.
            .motionAwareAnimation(.easeInOut(duration: 0.32), value: phase, reduceMotion: reduceMotion)
        }
        .fullScreenCover(isPresented: $showAuth) {
            AuthView(initialSignIn: authSignIn, onComplete: onComplete)
        }
    }

    private func go(_ p: Phase) -> () -> Void {
        { phase = p }
    }
}

// MARK: - Welcome ─────────────────────────────────────────────────────────────

private struct OBWelcome: View {
    let onNext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: Theme.spacingMD) {
                Image("FellowScriptMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .scaleEffect(appeared ? 1 : 0.5)
                    .motionAwareAnimation(.spring(response: 0.7, dampingFraction: 0.72).delay(0.1), value: appeared, reduceMotion: reduceMotion)

                VStack(spacing: 6) {
                    WordmarkText()
                    Text("A Digital Scripture Community")
                        .font(.inter(Theme.fontXXS))
                        .tracking(3)
                        .textCase(.uppercase)
                        .foregroundColor(Theme.textMuted)
                }

                Rectangle()
                    .fill(Theme.borderGold)
                    .frame(width: 44, height: 1)

                Text("Prayer & devotion,\nevery single day.")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 32)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)
            .motionAwareAnimation(.easeOut(duration: 0.55).delay(0.15), value: appeared, reduceMotion: reduceMotion)

            Spacer()

            Button(action: onNext) {
                HStack(spacing: 8) {
                    Text("Get Started")
                        .font(.inter(Theme.fontSM)).tracking(2).textCase(.uppercase)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.gold)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 56)
            .opacity(appeared ? 1 : 0)
            .motionAwareAnimation(.easeOut(duration: 0.4).delay(0.45), value: appeared, reduceMotion: reduceMotion)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - CTA ─────────────────────────────────────────────────────────────────

private struct OBCta: View {
    let onSignIn:  () -> Void
    let onCreate:  () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Theme.spacingSM) {
                WordmarkText()
                Text("A Digital Scripture Community")
                    .font(.inter(Theme.fontXS)).tracking(3).textCase(.uppercase)
                    .foregroundColor(Theme.parchment.opacity(0.50))
                    .multilineTextAlignment(.center)
                Rectangle().fill(Theme.borderGold).frame(width: 48, height: 1)
                    .padding(.top, Theme.spacingXS)
                Text("The Word. Your circle. Every single day.")
                    .font(.playfair(Theme.fontHeading, weight: .regular))
                    .foregroundColor(Theme.parchment.opacity(0.80))
                    .multilineTextAlignment(.center).lineSpacing(5)
                    .padding(.horizontal, Theme.spacingXL)
                    .padding(.top, Theme.spacingSM)
            }
            Spacer()
            VStack(spacing: Theme.spacingSM) {
                Button(action: onCreate) {
                    Text("Create Account")
                        .font(.inter(Theme.fontSM)).tracking(2).textCase(.uppercase)
                        .foregroundColor(Theme.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.spacingMD)
                        .background(Theme.parchment)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                Button(action: onSignIn) {
                    Text("Sign In")
                        .font(.inter(Theme.fontSM)).tracking(2).textCase(.uppercase)
                        .foregroundColor(Theme.parchment)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.spacingMD)
                        .background(Theme.parchment.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                            .stroke(Theme.parchment.opacity(0.40), lineWidth: 1))
                }
                HStack(spacing: 4) {
                    Text("By continuing you agree to our")
                        .foregroundColor(Theme.parchment.opacity(0.40))
                    Link("Privacy Policy",
                         destination: URL(string: "https://fellowscript.com/#/privacy")!)
                        .foregroundColor(Theme.parchment.opacity(0.65))
                }
                .font(.inter(Theme.fontXXS)).padding(.top, Theme.spacingXS)
            }
            .padding(.horizontal, Theme.spacingXL).padding(.bottom, 80)
        }
        .padding(.horizontal, Theme.spacingMD)
    }
}

