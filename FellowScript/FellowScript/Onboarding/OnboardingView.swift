import SwiftUI

// MARK: - Main Orchestrator ───────────────────────────────────────────────────

struct OnboardingView: View {
    var onComplete: () -> Void

    private enum Phase: Hashable { case welcome, survey, bridge, tour, cta }

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
            .animation(.easeInOut(duration: 0.32), value: phase)
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
                    .animation(.spring(response: 0.7, dampingFraction: 0.72).delay(0.1), value: appeared)

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
                        .font(.lora(Theme.fontXXS))
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
            .animation(.easeOut(duration: 0.55).delay(0.15), value: appeared)

            Spacer()

            Button(action: onNext) {
                HStack(spacing: 8) {
                    Text("Get Started")
                        .font(.lora(Theme.fontSM)).tracking(2).textCase(.uppercase)
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
            .animation(.easeOut(duration: 0.4).delay(0.45), value: appeared)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Survey ──────────────────────────────────────────────────────────────

private struct OBSurvey: View {
    @Binding var selected: Set<Int>
    let onNext: () -> Void

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
                    .font(.lora(Theme.fontXXS)).tracking(4).textCase(.uppercase)
                    .foregroundColor(Theme.textGoldMuted)
                Text("Which of these\nresonate with you?")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center).lineSpacing(4)
                Text("Select all that apply")
                    .font(.lora(Theme.fontXS))
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
                            withAnimation(.spring(response: 0.25)) {
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
                    .font(.lora(Theme.fontSM)).tracking(2).textCase(.uppercase)
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
                    .font(.lora(Theme.fontBody))
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
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(5)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 32)
            Spacer()
            Button(action: onNext) {
                Text("Begin the Tour →")
                    .font(.lora(Theme.fontSM)).tracking(2).textCase(.uppercase)
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

    private let steps = TourStep.all

    var body: some View {
        let current = steps[step]

        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text(current.section)
                    .font(.lora(Theme.fontXXS)).tracking(4).textCase(.uppercase)
                    .foregroundColor(Theme.textGoldMuted)
                Spacer()
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.lora(Theme.fontXS))
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
                .animation(.easeInOut(duration: 0.26), value: step)

            // Text
            VStack(spacing: 7) {
                Text(current.heading)
                    .font(.playfair(Theme.fontHeading))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(current.body)
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = current.hint {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 10))
                        Text(hint)
                            .font(.lora(Theme.fontXXS)).tracking(1)
                    }
                    .foregroundColor(Theme.gold.opacity(0.65))
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 28).padding(.top, 14)
            .animation(.easeInOut(duration: 0.2), value: step)

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
                        .animation(.spring(response: 0.28), value: step)
                }
            }
            .padding(.bottom, 10)

            // Nav buttons
            HStack(spacing: 12) {
                if step > 0 {
                    Button(action: { withAnimation(.easeInOut(duration: 0.26)) { step -= 1 } }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.parchment.opacity(0.55))
                            .frame(width: 50, height: 50)
                            .background(Theme.cardBg)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                                .stroke(Theme.borderGoldFaint, lineWidth: 1))
                    }
                }
                Button(action: {
                    if step < steps.count - 1 {
                        withAnimation(.easeInOut(duration: 0.26)) { step += 1 }
                    } else {
                        onFinish()
                    }
                }) {
                    HStack(spacing: 6) {
                        Text(step == steps.count - 1 ? "Get Started" : "Next")
                            .font(.lora(Theme.fontSM)).tracking(1).textCase(.uppercase)
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

                // Screen content
                mockScreen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

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

    @ViewBuilder
    private var mockScreen: some View {
        switch step {
        case 0:  MockDashboard()
        case 1:  MockBibleNav()
        case 2:  MockHighlights()
        case 3:  MockGroupDots()
        case 4:  MockCreateNote()
        case 5:  MockGroupNotes()
        case 6:  MockFriendChat()
        case 7:  MockAddFriend()
        case 8:  MockCreateGroup()
        case 9:  MockGroupSession()
        case 10: MockAIAgent()
        case 11: MockAccount()
        case 12: MockNotifications()
        default: MockHeartbeat()
        }
    }
}

// MARK: - Mock Screens ────────────────────────────────────────────────────────

private struct MockDashboard: View {
    var body: some View {
        VStack(spacing: 0) {
            // Warm gradient hero wash — approximates DashboardView's radial-gradient
            // ground behind HeroHeader (HOME step, §2 rebuild).
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color(hex: "#C98420"), Color(hex: "#A0641A"), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("YOUR RHYTHM")
                            .font(.system(size: 5, weight: .semibold)).tracking(1.5)
                            .foregroundColor(Color(hex: "#1E140A").opacity(0.66))
                        Text("Good evening, Joshua")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(Color(hex: "#2A1B0B"))
                        Text("Last read John 1 · 3 notes this week")
                            .font(.system(size: 6, design: .serif))
                            .foregroundColor(Color(hex: "#26190C").opacity(0.78))
                    }
                    Spacer()
                    Circle().fill(Color(hex: "#2A1B0B")).frame(width: 20, height: 20)
                        .overlay(Text("J").font(.system(size: 8, weight: .bold)).foregroundColor(Color(hex: "#F0AE40")))
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            }

            VStack(spacing: 6) {
                // "Revisit a Verse" — gold-filled hero card (RevisitVerseCard).
                VStack(alignment: .leading, spacing: 3) {
                    Text("REVISIT A VERSE")
                        .font(.system(size: 5, weight: .semibold)).tracking(1)
                        .foregroundColor(Color(hex: "#241708").opacity(0.66))
                    Text("Proverbs 27:17")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(Color(hex: "#24170A"))
                    HStack(spacing: 3) {
                        Text("Open in the reader").font(.system(size: 6, weight: .bold))
                        Image(systemName: "arrow.right").font(.system(size: 5.5, weight: .bold))
                    }
                    .foregroundColor(Color(hex: "#24170A").opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(
                    LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // "Group Activity" — recent previews + "Continue reading" pill CTA
                // (GroupActivityWidget).
                VStack(alignment: .leading, spacing: 6) {
                    Text("GROUP ACTIVITY")
                        .font(.system(size: 5, weight: .semibold)).tracking(1)
                        .foregroundColor(Theme.gold)

                    groupActivityRow("Sarah",           "See you at Bible study!", "2m ago")
                    groupActivityRow("Wednesday Study", "Session tomorrow at 7pm", "3h ago")

                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Continue reading").font(.system(size: 7, weight: .heavy))
                            Text("where you left off").font(.system(size: 5.5))
                        }
                        .foregroundColor(Color(hex: "#24170A"))
                        Spacer()
                        Image(systemName: "arrow.right").font(.system(size: 7)).foregroundColor(Color(hex: "#F0AE40"))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(LinearGradient(colors: [Theme.gold, Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
                }
                .padding(9)
                .mockGlassCard(cornerRadius: 10)
            }
            .padding(.horizontal, 12).padding(.top, 6)

            Spacer()
        }
    }

    private func groupActivityRow(_ name: String, _ preview: String, _ time: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "bubble.left.fill").font(.system(size: 7)).foregroundColor(Theme.gold.opacity(0.65))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 6.5, weight: .bold, design: .serif)).foregroundColor(Theme.parchment)
                Text(preview).font(.system(size: 5.5, design: .serif)).foregroundColor(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(time).font(.system(size: 5, design: .serif)).foregroundColor(Theme.textMuted)
        }
    }
}

private struct MockBibleNav: View {
    private func bv(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("\(n)").font(.system(size: 6, design: .serif)).foregroundColor(Theme.gold)
                .frame(width: 12, alignment: .trailing)
            Text(t).font(.system(size: 7, design: .serif)).foregroundColor(Theme.bibleText)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("John  ›  Chapter 1").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Text("ESV").font(.system(size: 7, design: .serif)).foregroundColor(Theme.gold)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.gold.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    bv(1,  "In the beginning was the Word, and the Word was with God, and the Word was God.")
                    bv(2,  "He was with God in the beginning.")
                    bv(3,  "Through him all things were made; without him nothing was made.")
                    bv(14, "The Word became flesh and made his dwelling among us.")
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }

            HStack {
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                Spacer()
                Text("Ch 1 of 21").font(.system(size: 6, design: .serif)).foregroundColor(Theme.textMuted)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 16).padding(.vertical, 6).background(Theme.navBg)
        }
    }
}

private struct MockHighlights: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("John  ›  Chapter 1").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7).background(Theme.navBg)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 5) {
                    Text("14").font(.system(size: 6, design: .serif)).foregroundColor(Theme.gold).frame(width: 12, alignment: .trailing)
                    Text("The Word became flesh and made his dwelling among us.")
                        .font(.system(size: 7, design: .serif))
                        .foregroundColor(Theme.bibleText).lineSpacing(2)
                        .background(Theme.hlYellow.opacity(0.35))
                }

                // Highlight picker popup
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach([Theme.hlYellow, Theme.hlRed, Theme.hlGreen, Theme.hlBlue, Theme.hlPurple], id: \.self) { c in
                            Circle().fill(c).frame(width: 18, height: 18)
                                .overlay(c == Theme.hlYellow ? Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundColor(.black) : nil)
                                .padding(4)
                        }
                        Divider().frame(height: 20).padding(.horizontal, 2)
                        Image(systemName: "pencil").font(.system(size: 8)).foregroundColor(Theme.parchment).padding(4)
                        Image(systemName: "trash").font(.system(size: 8)).foregroundColor(Theme.textMuted).padding(4)
                    }
                    .padding(6)
                }
                .background(Theme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderGoldDim, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 8)
                .padding(.leading, 16)
            }
            .padding(.horizontal, 12).padding(.top, 10)
            Spacer()
        }
    }
}

private struct MockGroupDots: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("John  ›  Chapter 1").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7).background(Theme.navBg)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 4) {
                    Text("1").font(.system(size: 6, design: .serif)).foregroundColor(Theme.gold).frame(width: 12, alignment: .trailing)
                    Text("In the beginning was the Word…").font(.system(size: 7, design: .serif)).foregroundColor(Theme.bibleText.opacity(0.6)).lineSpacing(2)
                }
                HStack(alignment: .top, spacing: 4) {
                    Text("3").font(.system(size: 6, design: .serif)).foregroundColor(Theme.gold).frame(width: 12, alignment: .trailing)
                    Text("Through him all things were made…").font(.system(size: 7, design: .serif)).foregroundColor(Theme.bibleText).lineSpacing(2)
                        .background(Theme.hlGreen.opacity(0.20))
                    Circle().fill(Theme.gold).frame(width: 6, height: 6)
                }
                HStack(alignment: .top, spacing: 4) {
                    Text("14").font(.system(size: 6, design: .serif)).foregroundColor(Theme.gold).frame(width: 12, alignment: .trailing)
                    Text("The Word became flesh and made his dwelling among us.").font(.system(size: 7, design: .serif)).foregroundColor(Theme.bibleText).lineSpacing(2)
                        .background(Theme.hlGreen.opacity(0.20))
                    Circle().fill(Theme.gold).frame(width: 6, height: 6)
                }

                // Community callout
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.system(size: 8)).foregroundColor(Theme.gold)
                    Text("Sarah & 2 others highlighted this").font(.system(size: 6, design: .serif)).foregroundColor(Theme.parchment.opacity(0.7))
                }
                .padding(8)
                .background(Theme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderGoldDim, lineWidth: 1))
            }
            .padding(.horizontal, 12).padding(.top, 10)
            Spacer()
        }
    }
}

private struct MockCreateNote: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Note").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Text("Save").font(.system(size: 8, design: .serif)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TITLE").font(.system(size: 5.5, design: .serif)).tracking(1).foregroundColor(Theme.textGoldMuted)
                    Text("John 1 — The Logos").font(.system(size: 9, design: .serif)).foregroundColor(Theme.parchment)
                    Rectangle().fill(Theme.borderGold).frame(height: 0.5)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("NOTE").font(.system(size: 5.5, design: .serif)).tracking(1).foregroundColor(Theme.textGoldMuted)
                    Text("John opens with 'In the beginning' mirroring Genesis. The Logos (Word) was both with God and was God — a profound declaration of Christ's divine pre-existence...")
                        .font(.system(size: 7, design: .serif)).foregroundColor(Theme.parchment.opacity(0.75)).lineSpacing(2)
                }

                HStack(spacing: 6) {
                    Image(systemName: "book").font(.system(size: 8)).foregroundColor(Theme.gold)
                    Text("John 1:1 · John 1:14").font(.system(size: 7, design: .serif)).foregroundColor(Theme.textGoldMuted)
                    Spacer()
                    Image(systemName: "plus").font(.system(size: 8)).foregroundColor(Theme.gold)
                }
                .padding(7)
                .background(Theme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderGoldFaint, lineWidth: 1))
            }
            .padding(12)
            Spacer()
        }
    }
}

private struct MockGroupNotes: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            // Notes / Highlights toggle (mirrors NotesListView.notesHighlightsToggle;
            // the retired "My Notes / Group Notes" toggle no longer exists in the real
            // screen — §5 rebuild).
            mockPillToggle {
                mockSegment("Notes", active: true)
                mockSegment("Highlights", active: false)
            }
            .padding(.horizontal, 12).padding(.top, 6)

            // Group-scope chips (mirrors NotesListView.groupChips) — the real filter
            // mechanism this mock's toggle used to (incorrectly) model.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    groupChip("Personal", selected: true)
                    groupChip("Wednesday Study", selected: false)
                    groupChip("Young Adults", selected: false)
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 6).padding(.bottom, 4)

            // Note cards rebuilt per NoteRow's real fields — title + optional PUBLIC
            // badge, optional verse-reference chip, preview, timestamp. No author
            // avatar (NoteRow has none; this isn't a "group notes wall").
            VStack(spacing: 6) {
                noteCard("Psalm 23 Reflection", verse: "Psalm 23:1",
                         preview: "The Lord is my shepherd — what it means to lack nothing in a season of uncertainty…",
                         time: "2h ago", isPublic: true)
                noteCard("Romans 8 Deep Dive", verse: "Romans 8:28",
                         preview: "All things work together for good. This isn't prosperity theology — it's covenant promise…",
                         time: "1d ago", isPublic: false)
            }
            .padding(.horizontal, 12)
            Spacer()
        }
    }

    private func groupChip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 6, weight: .bold))
            .foregroundColor(selected ? Color(hex: "#24170A") : Theme.parchment.opacity(0.7))
            .padding(.horizontal, 8)
            .frame(height: 16)
            .background(
                selected
                    ? LinearGradient(colors: [Theme.gold, Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Theme.parchment.opacity(0.07), Theme.parchment.opacity(0.07)], startPoint: .leading, endPoint: .trailing)
            )
            .overlay(Capsule().stroke(selected ? Color.clear : Theme.parchment.opacity(0.14), lineWidth: 0.5))
            .clipShape(Capsule())
    }

    private func noteCard(_ title: String, verse: String?, preview: String, time: String, isPublic: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 7.5, weight: .heavy)).foregroundColor(Theme.parchment).lineLimit(1)
                Spacer()
                if isPublic {
                    Text("PUBLIC")
                        .font(.system(size: 4.5, weight: .bold)).tracking(0.5)
                        .foregroundColor(Theme.goldLight)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Theme.gold.opacity(0.14))
                        .overlay(Capsule().stroke(Theme.gold.opacity(0.32), lineWidth: 0.5))
                        .clipShape(Capsule())
                }
            }
            if let verse {
                Text(verse)
                    .font(.system(size: 5.5, weight: .bold)).foregroundColor(Theme.goldLight)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Theme.gold.opacity(0.14))
                    .overlay(Capsule().stroke(Theme.gold.opacity(0.32), lineWidth: 0.5))
                    .clipShape(Capsule())
            }
            Text(preview).font(.system(size: 6, design: .serif)).foregroundColor(Theme.parchment.opacity(0.62)).lineLimit(2)
            Text(time).font(.system(size: 5, design: .serif)).foregroundColor(Theme.textMuted)
        }
        .padding(8)
        .mockGlassCard(cornerRadius: 10)
    }
}

private struct MockFriendChat: View {
    private func row(_ initial: String, _ name: String, _ preview: String, _ time: String, unread: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Theme.gold.opacity(0.18)).frame(width: 28, height: 28)
                    .overlay(Text(initial).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.gold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 8, weight: unread ? .semibold : .regular, design: .serif)).foregroundColor(Theme.parchment)
                    Text(preview).font(.system(size: 6.5, design: .serif)).foregroundColor(Theme.textMuted).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(time).font(.system(size: 5.5, design: .serif)).foregroundColor(Theme.textMuted)
                    if unread { Circle().fill(Theme.gold).frame(width: 7, height: 7) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().background(Theme.borderGoldFaint).padding(.leading, 50)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: decorative hamburger-circle (left) + "Chat" title + "+" (right) —
            // mirrors ChatRootView.header. Title renamed from the stale "Messages".
            HStack {
                Circle()
                    .strokeBorder(Theme.parchment.opacity(0.18), lineWidth: 0.5)
                    .background(Circle().fill(Theme.parchment.opacity(0.08)))
                    .frame(width: 16, height: 16)
                    .overlay(Image(systemName: "line.3.horizontal").font(.system(size: 6)).foregroundColor(Theme.goldLight))
                Spacer()
                Text("Chat").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            // Friends / Groups / Agents toggle (mirrors ChatRootView.scopeToggle) —
            // the single most visually identifying element of the real Chat screen,
            // previously absent from this mock entirely.
            mockPillToggle {
                mockSegment("Friends", active: true)
                mockSegment("Groups", active: false)
                mockSegment("Agents", active: false)
            }
            .padding(.horizontal, 12).padding(.top, 6)

            // Search field (mirrors ChatSearchField).
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 7)).foregroundColor(Theme.parchment.opacity(0.4))
                Text("Search conversations").font(.system(size: 6, design: .serif)).foregroundColor(Theme.parchment.opacity(0.4))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 16)
            .background(Capsule().fill(Theme.parchment.opacity(0.06)))
            .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 0.5))
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)

            VStack(spacing: 0) {
                row("S", "Sarah",           "See you at Bible study!",      "2m ago", unread: true)
                row("M", "Marcus",          "Romans 8 is incredible 🙌",    "1h ago", unread: false)
                row("W", "Wednesday Study", "Session tomorrow at 7pm",      "3h ago", unread: false)
            }
            Spacer()
        }
    }
}

private struct MockAddFriend: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                Spacer()
                Text("Add Friend").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Color.clear.frame(width: 20)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            VStack(spacing: 10) {
                // Search field
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundColor(Theme.textMuted)
                    Text("Search by username…").font(.system(size: 8, design: .serif)).foregroundColor(Theme.textMuted)
                    Spacer()
                }
                .padding(9)
                .background(Theme.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderGoldFaint, lineWidth: 1))

                // Result
                HStack(spacing: 8) {
                    Circle().fill(Theme.gold.opacity(0.18)).frame(width: 28, height: 28)
                        .overlay(Text("E").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.gold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("eli_shepherd").font(.system(size: 8, design: .serif)).foregroundColor(Theme.parchment)
                        Text("1 mutual friend").font(.system(size: 6, design: .serif)).foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                    Text("Add")
                        .font(.system(size: 7, design: .serif)).foregroundColor(Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.gold)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(10)
                .mockGlassCard(cornerRadius: 10)

                Text("Friend request sent once they accept you'll be connected.")
                    .font(.system(size: 6, design: .serif)).foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center).lineSpacing(2)
            }
            .padding(12)
            Spacer()
        }
    }
}

private struct MockCreateGroup: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                Spacer()
                Text("New Group").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Text("Create").font(.system(size: 7.5, design: .serif)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            VStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GROUP NAME").font(.system(size: 5.5, design: .serif)).tracking(1).foregroundColor(Theme.textGoldMuted)
                    Text("Wednesday Night Study")
                        .font(.system(size: 8, design: .serif)).foregroundColor(Theme.parchment)
                    Rectangle().fill(Theme.borderGold).frame(height: 0.5)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("MEMBERS").font(.system(size: 5.5, design: .serif)).tracking(1).foregroundColor(Theme.textGoldMuted)
                    ForEach(["Sarah", "Marcus", "Eli"], id: \.self) { name in
                        HStack(spacing: 8) {
                            Circle().fill(Theme.gold.opacity(0.18)).frame(width: 20, height: 20)
                                .overlay(Text(String(name.prefix(1))).font(.system(size: 8, weight: .bold)).foregroundColor(Theme.gold))
                            Text(name).font(.system(size: 7.5, design: .serif)).foregroundColor(Theme.parchment)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(Theme.gold)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus").font(.system(size: 8)).foregroundColor(Theme.gold)
                    Text("Add more friends").font(.system(size: 7, design: .serif)).foregroundColor(Theme.textGoldMuted)
                }
            }
            .padding(12)
            Spacer()
        }
    }
}

private struct MockGroupSession: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                Text("Wednesday Study").font(.system(size: 8.5, weight: .semibold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Image(systemName: "video").font(.system(size: 10)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 7).background(Theme.navBg)

            // Session card
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.success).frame(width: 6, height: 6)
                            Text("LIVE NOW").font(.system(size: 5.5, design: .serif)).tracking(1).foregroundColor(Theme.success)
                        }
                        Text("John 1 Deep Dive").font(.system(size: 9, weight: .semibold, design: .serif)).foregroundColor(Theme.parchment)
                        Text("Tonight · 7:00 PM").font(.system(size: 6, design: .serif)).foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                }

                HStack(spacing: 4) {
                    Image(systemName: "book").font(.system(size: 7)).foregroundColor(Theme.gold)
                    Text("John 1:1–18 · John 1:14").font(.system(size: 6.5, design: .serif)).foregroundColor(Theme.textGoldMuted)
                }

                Text("What does it mean that the Word became flesh?")
                    .font(.system(size: 6.5, design: .serif)).italic()
                    .foregroundColor(Theme.parchment.opacity(0.65)).lineSpacing(2)

                HStack(spacing: 6) {
                    ForEach(["S", "M", "E"], id: \.self) { i in
                        Circle().fill(Theme.gold.opacity(0.18)).frame(width: 16, height: 16)
                            .overlay(Text(i).font(.system(size: 6, weight: .bold)).foregroundColor(Theme.gold))
                    }
                    Text("+2 joined").font(.system(size: 6, design: .serif)).foregroundColor(Theme.textMuted)
                    Spacer()
                    Text("Join")
                        .font(.system(size: 7, weight: .semibold, design: .serif)).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Color(hex: "#2E7D32"))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(10)
            .mockGlassCard(cornerRadius: 12)
            .padding(.horizontal, 10).padding(.top, 8)

            Spacer()
        }
    }
}

private struct MockAIAgent: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New Testament Scholar").font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundColor(Theme.parchment)
                    HStack(spacing: 3) {
                        Circle().fill(Theme.success).frame(width: 5, height: 5)
                        Text("AI Agent").font(.system(size: 6, design: .serif)).foregroundColor(Theme.textMuted)
                    }
                }
                Spacer()
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 7).background(Theme.navBg)

            VStack(spacing: 7) {
                // Agent bubble
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Theme.gold.opacity(0.15)).frame(width: 18, height: 18)
                        .overlay(Text("✦").font(.system(size: 7)).foregroundColor(Theme.gold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEW TESTAMENT SCHOLAR").font(.system(size: 5, design: .serif)).tracking(1).foregroundColor(Theme.gold)
                        Text("In John 1, the Logos draws on both Jewish Wisdom tradition and Greek philosophy. John declares this eternal Word became flesh — entering the creation he authored.")
                            .font(.system(size: 6.5, design: .serif)).foregroundColor(Theme.parchment.opacity(0.8)).lineSpacing(2)
                    }
                    .padding(8).background(Color(hex: "#1A1A1A")).clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }

                // User bubble
                HStack(alignment: .top, spacing: 6) {
                    Spacer()
                    Text("Why does John start with 'In the beginning'?")
                        .font(.system(size: 6.5, design: .serif)).foregroundColor(Theme.parchment.opacity(0.75)).lineSpacing(2)
                        .padding(8).background(Theme.gold.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Agent reply
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Theme.gold.opacity(0.15)).frame(width: 18, height: 18)
                        .overlay(Text("✦").font(.system(size: 7)).foregroundColor(Theme.gold))
                    Text("It mirrors Genesis 1:1 deliberately. Jesus is positioned as existing before creation itself — the Word through whom all things were made.")
                        .font(.system(size: 6.5, design: .serif)).foregroundColor(Theme.parchment.opacity(0.8)).lineSpacing(2)
                        .padding(8).background(Color(hex: "#1A1A1A")).clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
            }
            .padding(10)
            Spacer()
        }
    }
}

// New ACCOUNT mock (§8) — Account was one of the 5 owner reference photos and had
// no corresponding tour step at all; the pre-existing EVENTS steps only reference
// "Account → Notifications" / "Account → Events" in body copy without ever showing
// the screen itself. Compressed for mock-phone legibility: profile block + the
// single most distinctive section (the 4-stat OVERVIEW row) + a one-line plan
// nudge, deliberately not the full Subscription/Plan-Usage cards.
private struct MockAccount: View {
    var body: some View {
        VStack(spacing: 0) {
            // Plain left-aligned title, no hamburger/plus — the real AccountView uses
            // a native large nav title with no header buttons.
            HStack {
                Text("Account").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            VStack(spacing: 10) {
                // Profile block (mirrors profileHeader).
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: "#EDAB3C").opacity(0.32), Color(hex: "#B8761D").opacity(0.2)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 30, height: 30)
                        Text("J").font(.system(size: 11, design: .serif)).foregroundColor(Theme.goldLight)
                    }
                    .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 0.75))
                    VStack(spacing: 1) {
                        Text("Joshua").font(.system(size: 9, weight: .semibold, design: .serif)).foregroundColor(Theme.parchment)
                        Text("joshua@example.com").font(.system(size: 6, design: .serif)).foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.top, 8)

                // Overview stats (mirrors statsSection/StatBox) — the clearest visual
                // signature of the real screen.
                VStack(alignment: .leading, spacing: 6) {
                    Text("OVERVIEW").font(.system(size: 5, weight: .semibold)).tracking(1).foregroundColor(Theme.textGoldMuted)
                    HStack {
                        accountStat("12", "Friends")
                        accountStat("3",  "Groups")
                        accountStat("48", "Notes")
                        accountStat("21", "Verses")
                    }
                }
                .padding(9)
                .mockGlassCard(cornerRadius: 10)

                // Compact plan nudge — a deliberate simplification of the real
                // Subscription + Plan Usage cards, which would be illegible/overflow
                // at mock-phone scale.
                HStack {
                    Text("Free plan · Upgrade for unlimited")
                        .font(.system(size: 6, weight: .semibold, design: .serif))
                        .foregroundColor(Theme.goldLight)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 6)).foregroundColor(Theme.gold.opacity(0.7))
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Theme.gold.opacity(0.10))
                .overlay(Capsule().stroke(Theme.gold.opacity(0.28), lineWidth: 0.75))
                .clipShape(Capsule())
            }
            .padding(.horizontal, 12).padding(.top, 6)

            Spacer()
        }
    }

    private func accountStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 10, weight: .bold, design: .serif)).foregroundColor(Theme.gold)
            Text(label).font(.system(size: 4.5, design: .serif)).tracking(0.5).textCase(.uppercase).foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MockNotifications: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            VStack(spacing: 8) {
                notifCard("bell.fill", "Morning Prayer",    "Daily · 7:00 AM", "Begin today by asking God what He wants to show you in His Word.")
                notifCard("moon.fill", "Evening Reflection","Daily · 9:00 PM", "What did God teach you today? Write it down.")
            }
            .padding(12)
            Spacer()
        }
    }
}

private struct MockHeartbeat: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Events").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

            VStack(spacing: 8) {
                // Event card
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle().fill(Theme.gold.opacity(0.14)).frame(width: 24, height: 24)
                            Image(systemName: "heart.fill").font(.system(size: 9)).foregroundColor(Theme.gold)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Daily Devotional").font(.system(size: 8, weight: .semibold, design: .serif)).foregroundColor(Theme.parchment)
                            Text("Daily · 6:00 AM").font(.system(size: 6, design: .serif)).foregroundColor(Theme.gold.opacity(0.65))
                        }
                        Spacer()
                        Image(systemName: "pencil").font(.system(size: 8)).foregroundColor(Theme.textMuted)
                    }

                    Text("\"Reflect on a Psalm and how God's faithfulness applies to my day.\"")
                        .font(.system(size: 6.5, design: .serif)).italic()
                        .foregroundColor(Theme.textMuted).lineSpacing(2)

                    // Last note preview
                    HStack(spacing: 5) {
                        Rectangle().fill(Theme.gold).frame(width: 2)
                        Text("Today's note: The Lord is my shepherd — what it means to lack nothing in…")
                            .font(.system(size: 6, design: .serif))
                            .foregroundColor(Theme.parchment.opacity(0.55)).lineSpacing(2).lineLimit(2)
                    }
                    .padding(6)
                    .background(Theme.gold.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(10)
                .mockGlassCard(cornerRadius: 12)
            }
            .padding(12)
            Spacer()
        }
    }
}

// MARK: - Shared Helpers ──────────────────────────────────────────────────────

private func notifCard(_ icon: String, _ name: String, _ schedule: String, _ prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
            Circle().fill(Theme.gold.opacity(0.14)).frame(width: 22, height: 22)
                .overlay(Image(systemName: icon).font(.system(size: 8)).foregroundColor(Theme.gold))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 8, weight: .semibold, design: .serif)).foregroundColor(Theme.parchment)
                Text(schedule).font(.system(size: 6, design: .serif)).foregroundColor(Theme.gold.opacity(0.65))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(Theme.textMuted)
        }
        Text(prompt).font(.system(size: 6, design: .serif)).italic()
            .foregroundColor(Theme.textMuted).lineSpacing(2).lineLimit(2)
    }
    .padding(9)
    .mockGlassCard(cornerRadius: 10)
}

// Miniaturized approximation of DashboardComponents.glassCard's frosted-material
// treatment ("Replaces the old opaque Theme.cardBg fill") for use inside
// OBMockPhone, where true .ultraThinMaterial backdrop blur won't render
// meaningfully at ~10pt card heights: a translucent/tinted fill + soft gradient
// hairline border instead of the retired flat Theme.cardBg + single-stroke look.
private extension View {
    func mockGlassCard(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.cardBg.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.20), Theme.gold.opacity(0.12)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.75
                    )
            )
    }
}

// Shared gold-gradient-active-capsule segment/toggle pattern — the same
// component pattern as NotesListView.notesHighlightsToggle / ChatRootView.scopeToggle,
// reused at mock scale by MockGroupNotes (Notes/Highlights) and MockFriendChat
// (Friends/Groups/Agents).
private func mockSegment(_ label: String, active: Bool) -> some View {
    Text(label)
        .font(.system(size: 6.5, weight: .bold))
        .foregroundColor(active ? Color(hex: "#24170A") : Theme.parchment.opacity(0.55))
        .frame(maxWidth: .infinity, minHeight: 16)
        .background(
            active
                ? LinearGradient(colors: [Theme.gold, Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(Capsule())
}

private func mockPillToggle<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 2) { content() }
        .padding(2)
        .background(
            Capsule().fill(Theme.parchment.opacity(0.07))
                .overlay(Capsule().stroke(Theme.parchment.opacity(0.13), lineWidth: 0.5))
        )
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
                    .font(.lora(Theme.fontXS)).tracking(3).textCase(.uppercase)
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
                        .font(.lora(Theme.fontSM)).tracking(2).textCase(.uppercase)
                        .foregroundColor(Theme.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.spacingMD)
                        .background(Theme.parchment)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                Button(action: onSignIn) {
                    Text("Sign In")
                        .font(.lora(Theme.fontSM)).tracking(2).textCase(.uppercase)
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
                .font(.lora(Theme.fontXXS)).padding(.top, Theme.spacingXS)
            }
            .padding(.horizontal, Theme.spacingXL).padding(.bottom, 80)
        }
        .padding(.horizontal, Theme.spacingMD)
    }
}

// MARK: - Tour Data ────────────────────────────────────────────────────────────

private struct TourStep {
    let section:   String
    let heading:   String
    let body:      String
    let hint:      String?
    let activeTab: Int

    static let all: [TourStep] = [
        // HOME (step 0)
        .init(
            section: "HOME",
            heading: "Your spiritual command center",
            body: "Your dashboard shows a verse to revisit, your circle's recent activity, and a one-tap way to continue right where you left off.",
            hint: "Everything starts here",
            activeTab: 0
        ),
        // BIBLE (steps 1–3)
        .init(
            section: "BIBLE",
            heading: "The whole Bible, always within reach",
            body: "Tap the Bible tab, choose a book and chapter, then read. Swipe left or right to move between chapters.",
            hint: "Swipe left/right to change chapters",
            activeTab: 1
        ),
        .init(
            section: "BIBLE",
            heading: "Mark what moves you",
            body: "Tap and hold any verse to bring up the highlight menu. Choose from five colors — each can carry its own meaning in your study practice.",
            hint: "Tap & hold any verse to highlight",
            activeTab: 1
        ),
        .init(
            section: "BIBLE",
            heading: "See where your circle was moved",
            body: "Gold dots appear next to verses your friends and group members highlighted. Tap the dot to see who marked it — and what color they chose.",
            hint: "Gold dot = community highlight",
            activeTab: 1
        ),
        // NOTES (steps 4–5)
        .init(
            section: "NOTES",
            heading: "Capture every revelation",
            body: "Tap + in the Notes tab to open the editor. Write your reflection, attach verse references, and save. Notes can be private or shared with your group.",
            hint: "Tap + to create a new note",
            activeTab: 2
        ),
        .init(
            section: "NOTES",
            heading: "Your community's journal",
            body: "Switch to Highlights to revisit verses you've marked, or tap a group chip to see what your study partners have written — every note is linked to the verse that inspired it.",
            hint: "Tap a group chip to filter",
            activeTab: 2
        ),
        // COMMUNITY (steps 6–9)
        .init(
            section: "COMMUNITY",
            heading: "Real-time Scripture conversations",
            body: "Open the Chat tab to find your friends and groups. Tap any name to open a thread and start a conversation centered on the Word.",
            hint: "Tap a contact to open a thread",
            activeTab: 3
        ),
        .init(
            section: "COMMUNITY",
            heading: "Build your study circle",
            body: "Tap + in Chat and search by username to send a friend request. Once accepted, you can message and see each other's highlights across the Bible.",
            hint: "Tap + → search by username",
            activeTab: 3
        ),
        .init(
            section: "COMMUNITY",
            heading: "Your small group, always connected",
            body: "Tap 'New Group' to create a group and add friends. Groups have shared chat, shared notes, and can host live devotion sessions.",
            hint: "Tap + → New Group",
            activeTab: 3
        ),
        .init(
            section: "COMMUNITY",
            heading: "Study face to face, from anywhere",
            body: "Inside a group thread, schedule a devotion session with attached Scripture and prompts. When it goes live, tap 'Join' for real-time voice or video.",
            hint: "Tap Sessions inside a group thread",
            activeTab: 3
        ),
        // AI AGENTS (step 10)
        .init(
            section: "AI AGENTS",
            heading: "Your personal theologian",
            body: "Switch to the Agents tab inside Chat and tap + to create an AI agent with a custom theological role. Chat with it anytime from that same tab — it knows your study context and goes deep into the Word.",
            hint: "Chat → Agents → +",
            activeTab: 3
        ),
        // ACCOUNT (step 11, new) — Account was one of the 5 owner reference photos
        // and previously had no corresponding tour step at all; inserted here since
        // the EVENTS steps' copy below already assumes the user is navigating
        // within Account ("In Account → Notifications...", "In Account → Events...").
        .init(
            section: "ACCOUNT",
            heading: "Your account, at a glance",
            body: "See your friends, groups, notes, and verses at a glance, and manage your plan — all from the Account tab.",
            hint: "Tap the Account tab",
            activeTab: 4
        ),
        // EVENTS (steps 12–13, shifted from 11–12 by the new ACCOUNT step above)
        .init(
            section: "EVENTS",
            heading: "Your gentle daily nudge",
            body: "In Account → Notifications, schedule a daily push reminder with a custom prompt. Your AI agent responds when it fires and the note is delivered to you automatically.",
            hint: "Account → Notifications → +",
            activeTab: 4
        ),
        .init(
            section: "EVENTS",
            heading: "Devotion that never misses",
            body: "In Account → Events, set a time and a prompt. Every day at that moment, your AI agent writes a personal devotional note and saves it straight to your journal — automatically.",
            hint: "Account → Events → New Event",
            activeTab: 4
        ),
    ]
}
