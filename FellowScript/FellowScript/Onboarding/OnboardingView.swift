import SwiftUI

// MARK: - Main Orchestrator ───────────────────────────────────────────────────

struct OnboardingView: View {
    var onComplete: () -> Void

    private enum Phase: Hashable { case welcome, survey, bridge, tour, cta }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase         = Phase.welcome
    @State private var selectedPains = Set<Int>()
    @State private var tourStep      = 0
    @State private var showAuth      = false
    @State private var authSignIn    = true

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()
            VStack {
                // Frame must be at least 2×endRadius tall — a RadialGradient
                // fades to `.clear` at endRadius measured from its own center,
                // so a frame that's only as tall as endRadius clips the fade
                // before it finishes (the glow gets a hard cut edge instead of
                // fading away smoothly). The offset repositions the brightest
                // point back up near the top of the screen, same as before.
                RadialGradient(
                    colors: [Theme.gold.opacity(0.22), .clear],
                    center: .center, startRadius: 0, endRadius: 250
                )
                .frame(height: 500).offset(y: -165)
                Spacer()
            }
            .ignoresSafeArea()

            Group {
                switch phase {
                case .welcome:
                    OBWelcome(onNext: go(.survey))
                case .survey:
                    OBSurvey(selected: $selectedPains, onNext: go(.bridge))
                case .bridge:
                    OBBridge(painCount: selectedPains.count, onNext: go(.tour))
                case .tour:
                    OBTour(step: $tourStep, onFinish: go(.cta), onSkip: go(.cta))
                case .cta:
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
            // Single source of truth for this transition's animation — go(_:)
            // deliberately does not also wrap `phase = p` in an explicit
            // withAnimation (which this used to do), to avoid two competing
            // animation transactions on the same value. This alone turned out
            // not to be the cause of the bug described below, but it's a
            // legitimate SwiftUI footgun worth avoiding regardless.
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
                    HStack(spacing: 0) {
                        Text("Fellow")
                            .font(.playfair(Theme.fontDisplayLG))
                            .foregroundColor(Theme.parchment)
                        Text("Script")
                            .font(.custom("Georgia-BoldItalic", size: Theme.fontDisplayLG))
                            .foregroundColor(Theme.gold)
                    }
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

// MARK: - Survey ──────────────────────────────────────────────────────────────

private struct OBSurvey: View {
    @Binding var selected: Set<Int>
    let onNext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pains = [
        "I struggle to read the Bible consistently",
        "I study Scripture alone — no community",
        "I forget what I learn during devotion",
        "I want prayer to become a daily habit",
        "I feel distant from God in busy seasons",
        "I want to go deeper but don't know how",
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Before we begin")
                    .font(.inter(Theme.fontXXS)).tracking(4).textCase(.uppercase)
                    .foregroundColor(Theme.textGoldMuted)
                Text("Which of these\nresonate with you?")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center).lineSpacing(4)
                Text("Select all that apply")
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.top, 64).padding(.bottom, 24).padding(.horizontal, 28)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(pains.indices, id: \.self) { i in
                        OBPainCard(
                            text: pains[i],
                            isSelected: selected.contains(i)
                        ) {
                            withMotionAwareAnimation(.spring(response: 0.25), reduceMotion: reduceMotion) {
                                if selected.contains(i) { selected.remove(i) }
                                else { selected.insert(i) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }

            Button(action: onNext) {
                Text(selected.isEmpty ? "Skip →" : "This is me →")
                    .font(.inter(Theme.fontSM)).tracking(2).textCase(.uppercase)
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Theme.gold)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .padding(.horizontal, 24).padding(.bottom, 52)
        }
    }
}

private struct OBPainCard: View {
    let text: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Theme.gold : Theme.gold.opacity(0.06))
                        .frame(width: 24, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.clear : Theme.borderGold, lineWidth: 1))
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.ink)
                    }
                }
                Text(text)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(isSelected ? Theme.parchment : Theme.parchment.opacity(0.60))
                    .multilineTextAlignment(.leading).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(isSelected ? Theme.gold.opacity(0.09) : Theme.cardBg)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                        .stroke(isSelected ? Theme.borderGold : Theme.borderGoldFaint, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bridge ──────────────────────────────────────────────────────────────

private struct OBBridge: View {
    let painCount: Int
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Theme.spacingMD) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(Theme.gold)
                Text(painCount > 0
                     ? "We built FellowScript\nfor exactly this."
                     : "This is what\nFellowScript was built for.")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center).lineSpacing(4)
                Rectangle().fill(Theme.borderGold).frame(width: 44, height: 1)
                Text("Every feature in this app exists to make prayer and devotion a living, daily practice — not just a Sunday event.")
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(5)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 32)
            Spacer()
            Button(action: onNext) {
                Text("Begin the Tour →")
                    .font(.inter(Theme.fontSM)).tracking(2).textCase(.uppercase)
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Theme.gold)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .padding(.horizontal, 32).padding(.bottom, 52)
        }
    }
}

// MARK: - Tour Navigator ──────────────────────────────────────────────────────

private struct OBTour: View {
    @Binding var step: Int
    let onFinish: () -> Void
    let onSkip:   () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let steps = TourStep.all

    var body: some View {
        let current = steps[step]

        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text(current.section)
                    .font(.inter(Theme.fontXXS)).tracking(4).textCase(.uppercase)
                    .foregroundColor(Theme.textGoldMuted)
                Spacer()
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.horizontal, 24).padding(.top, 56).padding(.bottom, 14)

            // Phone mockup
            OBMockPhone(step: step, activeTab: current.activeTab)
                .padding(.horizontal, 52)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
                .motionAwareAnimation(.easeInOut(duration: 0.26), value: step, reduceMotion: reduceMotion)

            // Text
            VStack(spacing: 7) {
                Text(current.heading)
                    .font(.playfair(Theme.fontHeading))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(current.body)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = current.hint {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 10))
                        Text(hint)
                            .font(.inter(Theme.fontXXS)).tracking(1)
                    }
                    .foregroundColor(Theme.gold.opacity(0.65))
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 28).padding(.top, 14)
            .motionAwareAnimation(.easeInOut(duration: 0.2), value: step, reduceMotion: reduceMotion)

            Spacer(minLength: 8)

            // Progress dots
            HStack(spacing: 5) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == step
                              ? Theme.gold
                              : (steps[i].section == current.section
                                 ? Theme.gold.opacity(0.32)
                                 : Theme.gold.opacity(0.10)))
                        .frame(width: i == step ? 18 : 6, height: 6)
                        .motionAwareAnimation(.spring(response: 0.28), value: step, reduceMotion: reduceMotion)
                }
            }
            .padding(.bottom, 10)

            // Nav buttons
            HStack(spacing: 12) {
                if step > 0 {
                    Button(action: { withMotionAwareAnimation(.easeInOut(duration: 0.26), reduceMotion: reduceMotion) { step -= 1 } }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.parchment.opacity(0.55))
                            .frame(width: 50, height: 50)
                            .background(Theme.cardBg)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                                .stroke(Theme.borderGoldFaint, lineWidth: 1))
                    }
                    .accessibilityLabel("Previous step")
                }
                Button(action: {
                    if step < steps.count - 1 {
                        withMotionAwareAnimation(.easeInOut(duration: 0.26), reduceMotion: reduceMotion) { step += 1 }
                    } else {
                        onFinish()
                    }
                }) {
                    HStack(spacing: 6) {
                        Text(step == steps.count - 1 ? "Get Started" : "Next")
                            .font(.inter(Theme.fontSM)).tracking(1).textCase(.uppercase)
                        if step < steps.count - 1 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Theme.gold)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 42)
        }
    }
}

// MARK: - Mock Phone Frame ────────────────────────────────────────────────────

private struct OBMockPhone: View {
    let step:      Int
    let activeTab: Int

    // Mirrors FloatingTabBar.swift's 5 destinations/labels/symbols.
    private let tabs: [(symbol: String, label: String)] = [
        ("house.fill",         "Home"),
        ("book.fill",          "Bible"),
        ("note.text",          "Notes"),
        ("message.fill",       "Chat"),
        ("person.crop.circle", "Account"),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Theme.bgPage)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.borderGoldDim, lineWidth: 1))

            VStack(spacing: 0) {
                // Status bar
                HStack {
                    Text("9:41")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "wifi").font(.system(size: 8))
                        Image(systemName: "battery.100").font(.system(size: 8))
                    }
                    .foregroundColor(Theme.textMuted)
                }
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)

                // Screen content. GeometryReader pins the Image to the
                // *exact* remaining space in this VStack row rather than
                // relying on `.frame(maxWidth: .infinity, maxHeight: .infinity)`
                // alone — confirmed live that a flexible-max frame around a
                // resizable/aspectRatio(.fill) Image let the image's own
                // aspect ratio win the VStack's layout negotiation (it
                // rendered at ~512pt tall instead of being capped to this
                // row's real ~250pt share of the fixed 330pt frame below),
                // blowing OBMockPhone's whole card out to ~580pt tall.
                GeometryReader { geo in
                    mockScreen
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }

                // Tab bar — floating inset dark capsule, mirroring FloatingTabBar.swift:
                // plain muted icons for inactive tabs, a gold-gradient capsule (icon +
                // label) only on the active tab. Not a static full-bleed strip.
                HStack(spacing: 3) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { item in
                        let isActive = item.offset == activeTab
                        if isActive {
                            HStack(spacing: 3) {
                                Image(systemName: item.element.symbol)
                                    .font(.system(size: 8, weight: .semibold))
                                Text(item.element.label)
                                    .font(.system(size: 6.5, weight: .bold))
                            }
                            .foregroundColor(Color(hex: "#24170A"))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(
                                LinearGradient(colors: [Theme.gold, Color(hex: "#EDAB3C")],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(Capsule())
                        } else {
                            Image(systemName: item.element.symbol)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(Theme.tabInactive)
                                .frame(width: 22, height: 22)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(5)
                .background(
                    Capsule()
                        .fill(Color(hex: "#120D08").opacity(0.94))
                        .overlay(Capsule().stroke(Theme.gold.opacity(0.24), lineWidth: 0.75))
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .frame(height: 330)
        .shadow(color: Theme.gold.opacity(0.10), radius: 20, x: 0, y: 10)
    }

    // Real captured Simulator screenshot per step (task 20260902-onboarding-
    // tour-real-screenshots), replacing the 13 hand-drawn Mock* recreations
    // that used to live here. Each asset is already cropped per
    // design-notes.md's spec (status bar/home-indicator/real tab bar
    // stripped, one fixed inset applied) — this is a pure content-source
    // swap at the same call site (frame sizing/corner radius/border/shadow
    // on OBMockPhone itself are all unchanged).
    @ViewBuilder
    private var mockScreen: some View {
        Image(TourStep.all[step].screenshotAsset)
            .resizable()
            .aspectRatio(contentMode: .fill)
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

// MARK: - Tour Data ────────────────────────────────────────────────────────────

private struct TourStep {
    let section:        String
    let heading:        String
    let body:           String
    let hint:           String?
    let activeTab:      Int
    // Assets.xcassets/OnboardingTour/<name> — a real Simulator screenshot,
    // cropped per design-notes.md's spec. See
    // FellowScript/Onboarding/TOUR_SCREENSHOT_CAPTURE.md for capture
    // provenance and the repeatable checklist for a future refresh.
    let screenshotAsset: String

    // 12 entries (task 20260902-onboarding-tour-real-screenshots). Two of
    // the original 14 steps were cut, not faked, because the feature they
    // described doesn't exist in the live app — see design-notes.md's
    // addendum for the full rationale:
    //   - the old BIBLE "gold dots" cross-user-highlight step (no such
    //     feature exists anywhere in BibleReaderViewModel)
    //   - the old EVENTS "Notifications" step (that surface was removed in
    //     20260826-ios-notification-ui-removal; the remaining EVENTS step
    //     below already covers the same ground truthfully)
    static let all: [TourStep] = [
        // HOME (step 0)
        .init(
            section: "HOME",
            heading: "Your spiritual command center",
            body: "Your dashboard shows a verse to revisit, your circle's recent activity, and a one-tap way to continue right where you left off.",
            hint: "Everything starts here",
            activeTab: 0,
            screenshotAsset: "tour-dashboard"
        ),
        // BIBLE (steps 1–2)
        .init(
            section: "BIBLE",
            heading: "The whole Bible, always within reach",
            body: "Tap the Bible tab, choose a book and chapter, then read. Swipe left or right to move between chapters.",
            hint: "Swipe left/right to change chapters",
            activeTab: 1,
            screenshotAsset: "tour-bible-nav"
        ),
        .init(
            section: "BIBLE",
            heading: "Mark what moves you",
            body: "Tap and hold any verse to bring up the highlight menu. Choose from five colors — each can carry its own meaning in your study practice.",
            hint: "Tap & hold any verse to highlight",
            activeTab: 1,
            screenshotAsset: "tour-highlights"
        ),
        // NOTES (steps 3–4)
        .init(
            section: "NOTES",
            heading: "Capture every revelation",
            body: "Tap + in the Notes tab to open the editor. Write your reflection, attach verse references, and save. Notes can be private or shared with your group.",
            hint: "Tap + to create a new note",
            activeTab: 2,
            screenshotAsset: "tour-create-note"
        ),
        .init(
            section: "NOTES",
            heading: "Your community's journal",
            body: "Switch to Highlights to revisit verses you've marked, or tap a group chip to see what your study partners have written — every note is linked to the verse that inspired it.",
            hint: "Tap a group chip to filter",
            activeTab: 2,
            screenshotAsset: "tour-group-notes"
        ),
        // COMMUNITY (steps 5–8)
        .init(
            section: "COMMUNITY",
            heading: "Real-time Scripture conversations",
            body: "Open the Chat tab to find your friends and groups. Tap any name to open a thread and start a conversation centered on the Word.",
            hint: "Tap a contact to open a thread",
            activeTab: 3,
            screenshotAsset: "tour-friend-chat"
        ),
        .init(
            section: "COMMUNITY",
            heading: "Build your study circle",
            body: "Tap + in Chat and search by username to send a friend request. Once accepted, you can message and see each other's highlights across the Bible.",
            hint: "Tap + → search by username",
            activeTab: 3,
            screenshotAsset: "tour-add-friend"
        ),
        .init(
            section: "COMMUNITY",
            heading: "Your small group, always connected",
            body: "Tap 'New Group' to create a group and add friends. Groups have shared chat, shared notes, and can host live devotion sessions.",
            hint: "Tap + → New Group",
            activeTab: 3,
            screenshotAsset: "tour-create-group"
        ),
        .init(
            section: "COMMUNITY",
            heading: "Study face to face, from anywhere",
            body: "Inside a group thread, schedule a devotion session with attached Scripture and prompts. When it goes live, tap 'Join' for real-time voice or video.",
            hint: "Tap Sessions inside a group thread",
            activeTab: 3,
            screenshotAsset: "tour-group-session"
        ),
        // AI AGENTS (step 9)
        .init(
            section: "AI AGENTS",
            heading: "Your personal theologian",
            body: "Switch to the Agents tab inside Chat and tap + to create an AI agent with a custom theological role. Chat with it anytime from that same tab — it knows your study context and goes deep into the Word.",
            hint: "Chat → Agents → +",
            activeTab: 3,
            screenshotAsset: "tour-ai-agent"
        ),
        // ACCOUNT (step 10)
        .init(
            section: "ACCOUNT",
            heading: "Your account, at a glance",
            body: "See your friends, groups, notes, and verses at a glance, and manage your plan — all from the Account tab.",
            hint: "Tap the Account tab",
            activeTab: 4,
            screenshotAsset: "tour-account"
        ),
        // EVENTS (step 11)
        .init(
            section: "EVENTS",
            heading: "Devotion that never misses",
            body: "In Account → Events, set a time and a prompt. Every day at that moment, your AI agent writes a personal devotional note and saves it straight to your journal — automatically.",
            hint: "Account → Events → New Event",
            activeTab: 4,
            screenshotAsset: "tour-heartbeat"
        ),
    ]
}
