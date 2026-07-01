// SOURCE: frontend/src/pages/Dashboard.jsx (FEATURES array, hero copy, mission copy)
// KEY STATE: currentPage
// INTERACTIONS: swipe/tap between pages, "Sign In" and "Create Account" on last page
// DEPENDENCY: Theme.swift

import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var currentPage = 0
    @State private var showAuth    = false
    @State private var authSignIn  = true

    private let pages: [OnboardingPage] = OnboardingPage.all

    var body: some View {
        ZStack {
            // Brand gradient background (gold → near-black)
            LinearGradient(
                colors: [Theme.gold.opacity(0.85), Color(hex: "#0D0D0D")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, page in
                        OnboardingPageView(page: page)
                            .tag(idx)
                    }
                    // Final page — CTAs
                    OnboardingCTAPage(
                        onSignIn: {
                            authSignIn = true
                            showAuth   = true
                        },
                        onCreateAccount: {
                            authSignIn = false
                            showAuth   = true
                        }
                    )
                    .tag(pages.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Manual progress dots
                HStack(spacing: 8) {
                    ForEach(0..<(pages.count + 1), id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Theme.parchment : Theme.parchment.opacity(0.30))
                            .frame(width: i == currentPage ? 8 : 6, height: i == currentPage ? 8 : 6)
                            .animation(.spring(response: 0.3), value: currentPage)
                    }
                }
                .padding(.bottom, 48)
            }
        }
        .fullScreenCover(isPresented: $showAuth) {
            AuthView(initialSignIn: authSignIn, onComplete: onComplete)
        }
    }
}

// ── Individual feature page ───────────────────────────────────────────────────
struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: Theme.spacingLG) {
            Spacer()

            // Icon / symbol
            Image(systemName: page.sfSymbol)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(Theme.parchment)
                .accessibilityHidden(true)

            VStack(spacing: Theme.spacingSM) {
                // Label chip (e.g. "SCRIPTURE")
                Text(page.label)
                    .font(.lora(Theme.fontXXS))
                    .tracking(5)
                    .textCase(.uppercase)
                    .foregroundColor(Theme.parchment.opacity(0.60))

                Text(page.heading)
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingXL)

                Text(page.body)
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment.opacity(0.70))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .padding(.horizontal, Theme.spacingXL)
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Theme.spacingMD)
    }
}

// ── Final CTA page ────────────────────────────────────────────────────────────
struct OnboardingCTAPage: View {
    var onSignIn:        () -> Void
    var onCreateAccount: () -> Void

    var body: some View {
        VStack(spacing: Theme.spacingLG) {
            Spacer()

            VStack(spacing: Theme.spacingSM) {
                // "FellowScript" brand logotype
                HStack(spacing: 0) {
                    Text("Fellow")
                        .font(.playfair(Theme.fontDisplayLG))
                        .foregroundColor(Theme.parchment)
                    Text("Script")
                        .font(.custom("Georgia-BoldItalic", size: Theme.fontDisplayLG))
                        .foregroundColor(Theme.gold)
                }
                .accessibilityLabel("FellowScript")

                Text("A Digital Scripture Community")
                    .font(.lora(Theme.fontXS))
                    .tracking(3)
                    .textCase(.uppercase)
                    .foregroundColor(Theme.parchment.opacity(0.50))
                    .multilineTextAlignment(.center)

                Rectangle()
                    .fill(Theme.borderGold)
                    .frame(width: 48, height: 1)
                    .padding(.top, Theme.spacingXS)

                Text("The forefront of spiritual growth through powerful connection.")
                    .font(.playfair(Theme.fontHeading, weight: .regular))
                    .foregroundColor(Theme.parchment.opacity(0.80))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, Theme.spacingXL)
                    .padding(.top, Theme.spacingSM)
            }

            Spacer()

            VStack(spacing: Theme.spacingSM) {
                // Primary CTA
                Button(action: onCreateAccount) {
                    Text("Create Account")
                        .font(.lora(Theme.fontSM))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundColor(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingMD)
                        .background(Theme.parchment)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .accessibilityLabel("Create Account")

                // Secondary CTA
                Button(action: onSignIn) {
                    Text("Sign In")
                        .font(.lora(Theme.fontSM))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundColor(Theme.parchment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingMD)
                        .background(Theme.parchment.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius)
                                .stroke(Theme.parchment.opacity(0.40), lineWidth: 1)
                        )
                }
                .accessibilityLabel("Sign In")
            }
            .padding(.horizontal, Theme.spacingXL)
            .padding(.bottom, 80)
        }
        .padding(.horizontal, Theme.spacingMD)
    }
}

// ── Data ──────────────────────────────────────────────────────────────────────
struct OnboardingPage {
    let label:    String
    let heading:  String
    let body:     String
    let sfSymbol: String

    // Mirrors FEATURES array in Dashboard.jsx exactly
    static let all: [OnboardingPage] = [
        OnboardingPage(
            label:    "Scripture",
            heading:  "A Living, Breathing Bible",
            body:     "Navigate the full ESV & NIV by book and chapter. Every passage a breath away — Genesis to Revelation, always at your fingertips.",
            sfSymbol: "book.open.fill"
        ),
        OnboardingPage(
            label:    "Highlights",
            heading:  "Mark What Moves You",
            body:     "Five colors, infinite meaning. See where your brothers and sisters have marked the same verses and discover what God is saying to your circle.",
            sfSymbol: "highlighter"
        ),
        OnboardingPage(
            label:    "Community",
            heading:  "Study Together, In Real Time",
            body:     "Message your group, share notes, and join live voice sessions built around Scripture. The Word comes alive when witnessed through shared eyes.",
            sfSymbol: "person.3.fill"
        ),
        OnboardingPage(
            label:    "Sessions",
            heading:  "Capture Every Revelation",
            body:     "Schedule devotion sessions with your group, attach verses, and arrive prepared. No revelation lost, no moment of clarity left unshared.",
            sfSymbol: "calendar.badge.plus"
        ),
    ]
}
