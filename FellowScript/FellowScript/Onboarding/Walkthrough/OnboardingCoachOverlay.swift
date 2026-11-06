// OnboardingCoachOverlay.swift -- task 20261105-onboarding-redo.
// Spotlight + coach card drawn over the REAL app screens (nothing is mocked).
//
// Usage:
//   anyView.onboardingAnchor(.newDevotionButton)         // mark a spotlight target
//   rootView.onboardingCoach(surfaces: [.root])         // host the card for these surfaces
//
// Sheets and covers sit above the root overlay, so each sheet root adds its own
// `.onboardingCoach(surfaces: [.thatSheet])`. The dim layer never intercepts
// touches: the user taps the real controls. Only the card itself is interactive.
//
// Reduce Motion: the spotlight and card move without animation. VoiceOver reads
// the card as one element ("Part 1 of 3, step 2 of 4: title. body. hint") and
// announces each new cue.

import SwiftUI
import Combine

// MARK: - Anchors

private struct OnboardingAnchorModifier: ViewModifier {
    let id: OnboardingAnchorID

    func body(content: Content) -> some View {
        content
            .id(id.rawValue)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { push(g.frame(in: .global), target: OnboardingEngine.shared.currentCue?.anchor) }
                        .onChange(of: g.frame(in: .global)) { _, f in push(f, target: OnboardingEngine.shared.currentCue?.anchor) }
                        // `$state` emits before the value lands, so use the emitted cue's anchor.
                        .onReceive(OnboardingEngine.shared.$state.map { $0?.currentCue?.anchor }.removeDuplicates()) { target in
                            push(g.frame(in: .global), target: target)
                        }
                        .onDisappear { OnboardingEngine.shared.updateAnchor(id, frame: nil) }
                }
            )
    }

    private func push(_ frame: CGRect, target: OnboardingAnchorID?) {
        OnboardingEngine.shared.updateAnchor(id, frame: target == id ? frame : nil)
    }
}

extension View {
    /// Marks this view as a walkthrough spotlight target (no-op for nil).
    @ViewBuilder
    func onboardingAnchor(_ id: OnboardingAnchorID?) -> some View {
        if let id { modifier(OnboardingAnchorModifier(id: id)) } else { self }
    }

    /// Hosts the coach card for cues whose surface is in `surfaces`.
    func onboardingCoach(surfaces: Set<OnboardingSurface>) -> some View {
        modifier(OnboardingCoachModifier(surfaces: surfaces))
    }

    /// Scrolls a ScrollViewReader to the current cue's anchor (long screens like Account).
    func onboardingScroll(_ proxy: ScrollViewProxy) -> some View {
        modifier(OnboardingScrollModifier(proxy: proxy))
    }
}

private struct OnboardingScrollModifier: ViewModifier {
    let proxy: ScrollViewProxy
    @ObservedObject private var engine = OnboardingEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var container: CGRect = .zero
    @State private var corrections = 0
    @State private var cueStart = Date()

    /// Spotlight target sits in the upper third so the bottom-docked card never covers it.
    private static let targetPoint = UnitPoint(x: 0.5, y: 0.3)

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { container = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in container = f }
            })
            .onChange(of: engine.currentCue?.id) { _, _ in corrections = 0; cueStart = Date(); scroll() }
            .onAppear { corrections = 0; cueStart = Date(); scroll() }
            // Account loads agents, events and requests after it appears, which moves the
            // target after the first scroll. Re-aim when it ends up outside the clear band.
            .onReceive(engine.$anchorFrames.debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)) { frames in
                // Only within 5s of the cue starting, so it never fights the user's own scroll.
                guard let anchor = engine.currentCue?.anchor, let f = frames[anchor],
                      container.height > 0, corrections < 6,
                      Date().timeIntervalSince(cueStart) < 5 else { return }
                let band = (container.minY + container.height * 0.12)...(container.minY + container.height * 0.45)
                if !band.contains(f.midY) { corrections += 1; scroll(delay: 0.05) }
            }
    }

    private func scroll(delay: TimeInterval = 0.35) {
        guard let anchor = engine.currentCue?.anchor else { return }
        // Let the destination mount first.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withMotionAwareAnimation(.easeInOut(duration: 0.35), reduceMotion: reduceMotion) {
                proxy.scrollTo(anchor.rawValue, anchor: Self.targetPoint)
            }
        }
    }
}

// MARK: - Overlay host

private struct OnboardingCoachModifier: ViewModifier {
    let surfaces: Set<OnboardingSurface>
    @ObservedObject private var engine = OnboardingEngine.shared

    func body(content: Content) -> some View {
        content.overlay {
            if engine.state?.phase == .walking, let cue = engine.currentCue, surfaces.contains(cue.surface) {
                OnboardingCoachLayer(cue: cue)
                    .transition(.opacity)
            }
        }
    }
}

private struct OnboardingCoachLayer: View {
    let cue: OnboardingCue
    @ObservedObject private var engine = OnboardingEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Outer reader only supplies the safe-area insets; the inner reader lives inside the
        // full-bleed container so its size and global origin match what is actually drawn.
        // (Reading origin/size from the inset reader offset the spotlight on iPad sheets.)
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                let hole = spotlightRect(origin: origin, size: geo.size)
                ZStack {
                    if let hole {
                        OnboardingSpotlightShape(hole: hole)
                            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Theme.gold, lineWidth: 2)
                                    .frame(width: hole.width, height: hole.height)
                                    .position(x: hole.midX, y: hole.midY)
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .motionAwareAnimation(.easeInOut(duration: 0.3), value: hole, reduceMotion: reduceMotion)
                    }
                    VStack {
                        if cardOnTop(hole: hole, height: geo.size.height) { card; Spacer(minLength: 0) }
                        else { Spacer(minLength: 0); card }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, insets.top + 8)
                    .padding(.bottom, bottomClearance(insets))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
        }
    }

    /// Hole in this overlay's local coordinates, nil when the target is missing or off screen.
    private func spotlightRect(origin: CGPoint, size: CGSize) -> CGRect? {
        guard engine.gate == .open, let anchor = cue.anchor, let g = engine.anchorFrames[anchor] else { return nil }
        let local = g.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -8, dy: -8)
        let screen = CGRect(origin: .zero, size: size)
        return local.intersects(screen) && local.height < size.height * 0.8 ? local : nil
    }

    /// The card goes to whichever side the spotlight is not on, so it never covers the
    /// control the cue tells the user to tap (the spotlight also has to be clear of it).
    private func cardOnTop(hole: CGRect?, height: CGFloat) -> Bool {
        if let hole { return hole.midY > height * 0.5 }
        return false
    }

    /// Keep the card clear of the floating tab bar / pinned action bar.
    private func bottomClearance(_ insets: EdgeInsets) -> CGFloat {
        insets.bottom + (cue.surface == .root || cue.surface == .accountScreen ? 88 : 96)
    }

    private var card: some View {
        OnboardingCoachCard(cue: cue)
            .frame(maxWidth: 420)
    }
}

private struct OnboardingSpotlightShape: Shape {
    var hole: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.origin.x, hole.origin.y), .init(hole.size.width, hole.size.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect.insetBy(dx: -200, dy: -200))
        p.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14), style: .continuous)
        return p
    }
}

// MARK: - Card

struct OnboardingCoachCard: View {
    let cue: OnboardingCue
    @ObservedObject private var engine = OnboardingEngine.shared

    private var part: OnboardingPart { engine.currentPart ?? .friend }
    private var cues: [OnboardingCue] { part.cues }
    private var cueNumber: Int { (cues.firstIndex(where: { $0.id == cue.id }) ?? 0) + 1 }
    private var partLine: String {
        guard let s = engine.state else { return part.label }
        return "\(part.label) · Part \(s.partNumber) of \(s.totalParts)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(partLine.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1)
                    .foregroundColor(Theme.gold.opacity(0.85))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if engine.gate == .open {
                    Text("\(cueNumber) of \(cues.count)")
                        .font(.fsHelper).foregroundColor(Theme.textSecondary)
                }
            }
            switch engine.gate {
            case .open:        openContent
            case .checking:    checkingContent
            case .needsSubscription: subscriptionContent
            }
            HStack {
                if engine.gate == .open { dots }
                Spacer()
                Button(action: { engine.skipPart() }) {
                    Text("Skip this step")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Theme.fieldFill))
                        .overlay(Capsule().strokeBorder(Theme.fieldBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip this step")
                .accessibilityHint("Leaves \(part.label) for later and moves on")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous)
                .fill(Theme.bgPage.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).fill(Theme.cardGlassGray))
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).strokeBorder(Theme.borderGray, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .onAppear { announce() }
        .onChange(of: cue.id) { _, _ in announce() }
    }

    @ViewBuilder private var openContent: some View {
        Text(cue.title).font(.fsCardHeading).foregroundColor(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
        Text(cue.body).font(.system(size: 14)).foregroundColor(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if let hint = cue.hint {
            Label(hint, systemImage: "hand.tap")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.gold)
        }
        if let message = engine.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.error)
                .accessibilityLabel("Problem: \(message)")
        }
    }

    @ViewBuilder private var checkingContent: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.gold)
            Text("Checking your plan…").font(.system(size: 14)).foregroundColor(Theme.textSecondary)
        }
    }

    /// Fail-closed free-plan card (composed from the kit; not in the approved mockups).
    @ViewBuilder private var subscriptionContent: some View {
        Text("This one needs a subscription")
            .font(.fsCardHeading).foregroundColor(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
        Text(part == .devotion
             ? "Scheduled devotions are part of a subscription. You can add one later from Account whenever you subscribe."
             : "Your AI study partner is part of a subscription. You can come back to it from Chat whenever you subscribe.")
            .font(.system(size: 14)).foregroundColor(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(cues.indices, id: \.self) { i in
                Capsule()
                    .fill(i + 1 == cueNumber ? Theme.gold : Theme.gold.opacity(i + 1 < cueNumber ? 0.45 : 0.18))
                    .frame(width: i + 1 == cueNumber ? 18 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func announce() {
        let text = engine.gate == .open
            ? "\(partLine), step \(cueNumber) of \(cues.count). \(cue.title). \(cue.hint ?? "")"
            : "\(partLine). This one needs a subscription."
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

// MARK: - Recap

/// "You're set up": one gray card listing every part (done, or open with where to find it).
struct OnboardingRecapView: View {
    @ObservedObject private var engine = OnboardingEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.clear.warmBloomBackground()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("You’re set up")
                                .font(.fsSheetTitle).foregroundColor(Theme.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            Text("Anything you skipped is still waiting for you. Here is where to find it.")
                                .font(.fsBody).foregroundColor(Theme.textSecondary)
                        }
                        VStack(spacing: 0) {
                            let parts = engine.state?.parts ?? []
                            ForEach(Array(parts.enumerated()), id: \.element.id) { idx, part in
                                if idx > 0 { Divider().overlay(Theme.borderGray) }
                                row(part)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).fill(Theme.cardGlassGray))
                        .overlay(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).strokeBorder(Theme.borderGray, lineWidth: 1))
                    }
                    .padding(.horizontal, 16).padding(.top, 64).padding(.bottom, 24)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
                FSPinnedActionBar(primaryTitle: "Continue", onPrimary: { engine.finishRecap() })
                    .frame(maxWidth: 560)
            }
        }
    }

    @ViewBuilder
    private func row(_ part: OnboardingPart) -> some View {
        let done = engine.state?.status(of: part) == .done
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if done {
                    Circle().fill(Theme.gold).frame(width: 24, height: 24)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.ink)
                } else {
                    Circle().strokeBorder(Theme.fieldBorder, lineWidth: 2).frame(width: 24, height: 24)
                }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(done ? part.doneTitle : part.skippedTitle)
                    .font(.fsLabel).foregroundColor(Theme.textPrimary)
                Text(done ? part.whereToFind : "Skipped. Find it any time in \(part.whereToFind).")
                    .font(.fsHelper).foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56, alignment: .top)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(done ? "\(part.doneTitle), done" : "\(part.skippedTitle), skipped. Find it in \(part.whereToFind)")
    }
}
