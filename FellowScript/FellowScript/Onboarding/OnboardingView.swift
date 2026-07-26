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
        }
        .animation(.easeInOut(duration: 0.32), value: phase)
        .fullScreenCover(isPresented: $showAuth) {
            AuthView(initialSignIn: authSignIn, onComplete: onComplete)
        }
    }

    private func go(_ p: Phase) -> () -> Void {
        { withAnimation(.easeInOut(duration: 0.32)) { phase = p } }
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

    private let tabs = ["house.fill", "book.fill", "note.text", "message.fill", "person.crop.circle"]

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

                // Tab bar
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { item in
                        Spacer()
                        Image(systemName: item.element)
                            .font(.system(size: 13))
                            .foregroundColor(item.offset == activeTab ? Theme.gold : Theme.textMuted.opacity(0.45))
                        Spacer()
                    }
                }
                .padding(.vertical, 7)
                .background(Theme.navBg)
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
        case 11: MockNotifications()
        default: MockHeartbeat()
        }
    }
}

// MARK: - Mock Screens ────────────────────────────────────────────────────────

private struct MockDashboard: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Good morning").font(.system(size: 7, design: .serif)).foregroundColor(Theme.textMuted)
                    Text("Joshua").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.parchment)
                }
                Spacer()
                Circle().fill(Theme.gold.opacity(0.18)).frame(width: 26, height: 26)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 9)).foregroundColor(Theme.gold))
            }
            .padding(.horizontal, 12).padding(.top, 6)

            mockCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VERSE OF THE DAY").font(.system(size: 5.5, design: .serif)).tracking(1).foregroundColor(Theme.gold)
                    Text("\"As iron sharpens iron, so one person sharpens another.\"")
                        .font(.system(size: 7, design: .serif)).italic()
                        .foregroundColor(Theme.parchment).lineSpacing(2)
                    Text("Proverbs 27:17").font(.system(size: 5.5, design: .serif)).foregroundColor(Theme.textGoldMuted)
                }
            }

            mockCard {
                HStack(spacing: 7) {
                    Circle().fill(Theme.gold.opacity(0.15)).frame(width: 20, height: 20)
                        .overlay(Image(systemName: "sparkles").font(.system(size: 7)).foregroundColor(Theme.gold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Daily Devotional Agent").font(.system(size: 6.5, design: .serif)).foregroundColor(Theme.parchment)
                        Text("Psalm 23 reflection ready…").font(.system(size: 5.5, design: .serif)).foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                }
            }

            mockCard {
                HStack(spacing: 7) {
                    Image(systemName: "calendar").font(.system(size: 9)).foregroundColor(Theme.gold)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Wednesday Night Study").font(.system(size: 6.5, design: .serif)).foregroundColor(Theme.parchment)
                        Text("Tonight · 7:00 PM").font(.system(size: 5.5, design: .serif)).foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                }
            }

            Spacer()
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

            // Toggle
            HStack(spacing: 0) {
                Text("My Notes")
                    .font(.system(size: 7, design: .serif))
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(Theme.gold)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Group Notes")
                    .font(.system(size: 7, design: .serif))
                    .foregroundColor(Theme.parchment.opacity(0.55))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .padding(3)
            .background(Theme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12).padding(.vertical, 6)

            VStack(spacing: 6) {
                groupNoteCard("Sarah",  "Psalm 23 Reflection",   "Psalm 23:1",  "The Lord is my shepherd — what it means to lack nothing in a season of uncertainty…")
                groupNoteCard("Marcus", "Romans 8 Deep Dive",    "Romans 8:28", "All things work together for good. This isn't prosperity theology — it's covenant promise…")
            }
            .padding(.horizontal, 12)
            Spacer()
        }
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
            HStack {
                Text("Messages").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.parchment)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11)).foregroundColor(Theme.gold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.navBg)

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
                .background(Theme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderGoldFaint, lineWidth: 1))

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
            .background(Theme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderGoldDim, lineWidth: 1))
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
                .background(Theme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderGoldDim, lineWidth: 1))
            }
            .padding(12)
            Spacer()
        }
    }
}

// MARK: - Shared Helpers ──────────────────────────────────────────────────────

private func groupNoteCard(_ author: String, _ title: String, _ verse: String, _ preview: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        HStack {
            Circle().fill(Theme.gold.opacity(0.18)).frame(width: 14, height: 14)
                .overlay(Text(String(author.prefix(1))).font(.system(size: 6, weight: .bold)).foregroundColor(Theme.gold))
            Text(author).font(.system(size: 6, design: .serif)).foregroundColor(Theme.textGoldMuted)
            Spacer()
            Text(verse).font(.system(size: 5.5, design: .serif)).foregroundColor(Theme.gold)
        }
        Text(title).font(.system(size: 7.5, weight: .medium, design: .serif)).foregroundColor(Theme.parchment)
        Text(preview).font(.system(size: 6, design: .serif)).foregroundColor(Theme.textMuted).lineSpacing(1.5).lineLimit(2)
    }
    .padding(9)
    .background(Theme.cardBg)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderGoldFaint, lineWidth: 1))
}

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
    .background(Theme.cardBg)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderGoldFaint, lineWidth: 1))
}

private func mockCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .padding(9)
        .background(Theme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderGoldFaint, lineWidth: 0.5))
        .padding(.horizontal, 12)
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
            body: "Your dashboard shows today's verse, your AI agent's latest insight, upcoming study sessions, and recent notes — all before you've had your coffee.",
            hint: "Everything starts here",
            activeTab: 0
        ),
        // BIBLE (steps 1–3)
        .init(
            section: "BIBLE",
            heading: "The full ESV & NIV at your fingertips",
            body: "Tap the Bible tab, choose a book and chapter, then read. Swipe left or right to move between chapters. Switch translations with a single tap.",
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
            body: "Toggle to 'Group Notes' to see what your study partners have written. Every note is linked to the verse that inspired it.",
            hint: "Toggle between My Notes and Group",
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
            body: "In Account → Agents, create an AI agent with a custom theological role. Chat with it anytime from the Chat tab — it knows your study context and goes deep into the Word.",
            hint: "Account → Agents → Chat",
            activeTab: 4
        ),
        // EVENTS (steps 11–12)
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
