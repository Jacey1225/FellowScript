// PostTourPromptViews.swift — task 20261008-post-tour-prompts.
//
// Final Squidward design (design-spec.md, approved 2026-10-08). Every
// layout/styling decision lives in `PostTourPromptScaffold` and its small
// helpers; the two prompt views below only supply copy, state and actions.

import SwiftUI
import UIKit

// MARK: - Layout surface (final design)

enum PostTourMotif {
    case notifications
    case subscribe
}

enum PostTourSecondaryStyle {
    case plainText   // "Maybe later"
    case ghostPill   // "Continue with the free plan"
}

/// Decorative ring/tick-ring field shared by both prompts for continuity.
private struct PostTourMotifView: View {
    let kind: PostTourMotif
    let size: CGFloat

    var body: some View {
        let scale = size / 200
        ZStack {
            ForEach(Array([(100.0, 0.30), (78.0, 0.20), (58.0, 0.12)].enumerated()), id: \.offset) { _, ring in
                Circle()
                    .stroke(Theme.gold.opacity(ring.1), lineWidth: 1)
                    .frame(width: ring.0 * 2 * scale, height: ring.0 * 2 * scale)
            }
            ForEach(0..<60, id: \.self) { i in
                Rectangle()
                    .fill(Theme.gold.opacity(0.25))
                    .frame(width: 1, height: 4 * scale)
                    .offset(y: -90 * scale)
                    .rotationEffect(.degrees(Double(i) * 6))
            }
            ForEach(Array([(-30.0, 100.0), (150.0, 78.0), (215.0, 100.0), (80.0, 78.0)].enumerated()), id: \.offset) { _, dot in
                Circle()
                    .fill(Theme.gold)
                    .frame(width: 3.5 * scale, height: 3.5 * scale)
                    .offset(x: cos(dot.0 * .pi / 180) * dot.1 * scale,
                            y: sin(dot.0 * .pi / 180) * dot.1 * scale)
            }
            switch kind {
            case .notifications:
                BookShape()
                    .stroke(Theme.gold.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 64 * scale, height: 44 * scale)
                BubbleShape()
                    .stroke(Theme.gold.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .frame(width: 26 * scale, height: 20 * scale)
                    .offset(x: 52 * scale, y: -66 * scale)
                BubbleShape()
                    .stroke(Theme.parchment.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .frame(width: 26 * scale, height: 20 * scale)
                    .offset(x: 80 * scale, y: -40 * scale)
            case .subscribe:
                Circle()
                    .fill(Theme.gold.opacity(0.14))
                    .overlay(Circle().stroke(Color(hex: "#FFE1AA").opacity(0.22), lineWidth: 1))
                    .frame(width: 96 * scale, height: 96 * scale)
                Image("FellowScriptMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40 * scale, height: 40 * scale)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct BookShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let mid = r.midX
        p.move(to: CGPoint(x: mid, y: r.minY + r.height * 0.12))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: mid - r.width * 0.25, y: r.minY - r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.12))
        p.addQuadCurve(to: CGPoint(x: mid, y: r.maxY), control: CGPoint(x: mid - r.width * 0.25, y: r.maxY - r.height * 0.15))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.12), control: CGPoint(x: mid + r.width * 0.25, y: r.maxY - r.height * 0.15))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: mid, y: r.minY + r.height * 0.12), control: CGPoint(x: mid + r.width * 0.25, y: r.minY - r.height * 0.05))
        p.move(to: CGPoint(x: mid, y: r.minY + r.height * 0.12))
        p.addLine(to: CGPoint(x: mid, y: r.maxY))
        return p
    }
}

private struct BubbleShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.78)
        p.addRoundedRect(in: body, cornerSize: CGSize(width: 6, height: 6))
        p.move(to: CGPoint(x: r.minX + r.width * 0.25, y: body.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.2, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: body.maxY))
        return p
    }
}

private struct PostTourPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                configuration.isPressed
                    ? LinearGradient(colors: [Theme.gold, Theme.goldDim], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : Theme.goldGradient
            )
            .clipShape(Capsule())
            .topEdgeHighlight(Capsule())
            .shadow(color: Theme.gold.opacity(0.25), radius: 16, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct PostTourGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Theme.parchment)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(configuration.isPressed ? Theme.gold.opacity(0.09) : .clear))
            .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.6)
    }
}

private struct PostTourTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct PostTourPromptScaffold<Extra: View>: View {
    let motif: PostTourMotif
    let eyebrow: String
    let headlineLead: String
    let headlineKey: String
    let headlineTail: String
    let message: String
    let primaryTitle: String
    var primaryFallbackTitle: String? = nil
    /// Web-checkout variant: the title wraps (no one-line limit) and carries an
    /// external-link glyph.
    var primaryWraps: Bool = false
    let primaryBusy: Bool
    let secondaryTitle: String
    let secondaryStyle: PostTourSecondaryStyle
    let primaryIdentifier: String
    let secondaryIdentifier: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    /// Rendered inside the pinned action block, below the two buttons
    /// (error slot, terms line, link row).
    @ViewBuilder var extra: () -> Extra

    @AccessibilityFocusState private var headlineFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var motifSize: CGFloat { UIScreen.main.bounds.height < 700 ? 150 : 200 }

    private var headline: AttributedString {
        var lead = AttributedString(headlineLead)
        lead.font = Font.system(size: 34, weight: .heavy)
        lead.foregroundColor = Theme.parchment
        var key = AttributedString(headlineKey)
        key.font = Font.verseRef(34)
        key.foregroundColor = Theme.gold
        var tail = AttributedString(headlineTail)
        tail.font = Font.system(size: 34, weight: .heavy)
        tail.foregroundColor = Theme.parchment
        return lead + key + tail
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.warmBloomBackground()

            ScrollView {
                VStack(spacing: 0) {
                    PostTourMotifView(kind: motif, size: motifSize)
                        .padding(.top, Theme.spacingLG)
                    Text(eyebrow.uppercased())
                        .font(Font.system(size: 11, weight: .medium))
                        .tracking(4)
                        .foregroundColor(Theme.gold)
                        .padding(.top, 28)
                    Text(headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .padding(.top, Theme.spacingSM)
                        .accessibilityLabel(headlineLead + headlineKey + headlineTail)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headlineFocused)
                    Text(message)
                        .font(Font.system(size: Theme.fontBody))
                        .foregroundColor(Theme.parchment.opacity(0.88))
                        .lineSpacing(5)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
                .padding(.horizontal, Theme.spacingXL)
                .padding(.bottom, Theme.spacingMD)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 18)
            }
        }
        .background {
            // Bloom lives in a background so its oversized frame never
            // contributes to layout width (a 500pt child in the ZStack made
            // the whole screen 500pt wide and pushed content off both edges).
            Color.clear
                .overlay(alignment: .top) {
                    RadialGradient(colors: [Theme.gold.opacity(0.22), .clear],
                                   center: .center, startRadius: 0, endRadius: 250)
                        .frame(width: 500, height: 500)
                        .offset(y: -110)
                }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onPrimary()
                }) {
                    Group {
                        if primaryBusy {
                            ProgressView().tint(Theme.ink)
                        } else if primaryWraps {
                            HStack(spacing: 8) {
                                Text(primaryTitle)
                                    .minimumScaleFactor(0.8)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                Image(systemName: "arrow.up.right.square").accessibilityHidden(true)
                            }
                            .padding(.vertical, 8)
                        } else if let fallback = primaryFallbackTitle {
                            ViewThatFits(in: .horizontal) {
                                Text(primaryTitle).lineLimit(1)
                                Text(fallback).lineLimit(1)
                            }
                        } else {
                            Text(primaryTitle).lineLimit(1)
                        }
                    }
                    .font(Font.system(size: Theme.fontBody, weight: .semibold))
                    .padding(.horizontal, Theme.spacingMD)
                }
                .buttonStyle(PostTourPrimaryButtonStyle())
                .disabled(primaryBusy)
                .accessibilityIdentifier(primaryIdentifier)

                Spacer().frame(height: secondaryStyle == .ghostPill ? 10 : Theme.spacingSM)

                switch secondaryStyle {
                case .plainText:
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(Font.system(size: Theme.fontBody, weight: .medium))
                            .foregroundColor(Theme.parchment.opacity(0.78))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(PostTourTextButtonStyle())
                    .disabled(primaryBusy)
                    .accessibilityIdentifier(secondaryIdentifier)
                case .ghostPill:
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(Font.system(size: Theme.fontBody, weight: .semibold))
                    }
                    .buttonStyle(PostTourGhostButtonStyle())
                    .disabled(primaryBusy)
                    .accessibilityIdentifier(secondaryIdentifier)
                }

                extra()
            }
            .padding(.horizontal, Theme.spacingLG)
            .padding(.top, Theme.spacingSM)
            .padding(.bottom, Theme.spacingMD)
            .background(Theme.bgPage.opacity(0.001))
        }
        .onAppear {
            headlineFocused = true
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.55).delay(0.15)) {
                appeared = true
            }
        }
    }
}

// MARK: - Prompt 1: notifications

struct NotificationsPromptView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var coordinator: PostTourPromptsCoordinator

    var body: some View {
        PostTourPromptScaffold(
            motif: .notifications,
            eyebrow: "Stay close",
            headlineLead: "Keep your ",
            headlineKey: "place",
            headlineTail: ".",
            message: "Get your daily devotion and your study group's replies the moment they arrive, so you never lose your place in Scripture.",
            primaryTitle: "Enable notifications",
            primaryBusy: false,
            secondaryTitle: "Maybe later",
            secondaryStyle: .plainText,
            primaryIdentifier: "postTour.notifications.enable",
            secondaryIdentifier: "postTour.notifications.later",
            onPrimary: {
                // Lift the deferral first so the system dialog is allowed.
                coordinator.finish(.notifications, notificationsEnabled: true)
                appState.requestPushNotifications()
            },
            onSecondary: { coordinator.finish(.notifications) },
            extra: { EmptyView() }
        )
    }
}

// MARK: - Prompt 2: subscribe

struct SubscribePromptView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var coordinator: PostTourPromptsCoordinator
    @ObservedObject private var store = StoreKitManager.shared
    @ObservedObject private var gate = WebCheckoutGate.shared
    @StateObject private var quote = WebCheckoutQuoteModel()
    @Environment(\.openURL) private var openURL
    @State private var message: String?
    @State private var restoring = false

    /// Tier 1 (one member) is the "from" price; the Account tab's group-size
    /// picker remains the path to larger groups.
    private static let startingMemberCount = 1

    private var surface: WebCheckoutPurchaseSurface {
        WebCheckoutPolicy.surface(gate: gate.state, hasActiveApplePlan: false, quoteBlockedByApple: quote.blockedByApple)
    }
    private var isWeb: Bool { surface == .web }

    /// "$5.00" from the server quote (US) or StoreKit's localized price (everywhere
    /// else). nil until known: no hardcoded price is ever shown.
    private var price: String? {
        if isWeb { return quote.totalCents.map { WebCheckoutFormat.price(cents: $0) } }
        return store.displayPrice(for: Self.startingMemberCount)
    }

    private var messageText: String {
        let base = "Go unlimited: endless notes, a devotion written for you every day, and your whole study group"
        return price.map { "\(base), from \($0) a month." } ?? base + "."
    }

    private var primaryTitle: String {
        if isWeb { return "Subscribe on the web" }
        return price.map { "Subscribe for \($0) a month" } ?? "Subscribe"
    }

    var body: some View {
        PostTourPromptScaffold(
            motif: .subscribe,
            eyebrow: "Your plan",
            headlineLead: "Go ",
            headlineKey: "unlimited",
            headlineTail: ".",
            message: messageText,
            primaryTitle: primaryTitle,
            primaryFallbackTitle: isWeb ? nil : "Subscribe",
            primaryWraps: isWeb,
            // The button stays inert until the storefront is known so a US user
            // never sees the StoreKit sheet and a non-US user never sees the link.
            primaryBusy: store.purchasing || surface == .resolving,
            secondaryTitle: "Continue with the free plan",
            secondaryStyle: .ghostPill,
            primaryIdentifier: isWeb ? "webCheckoutSubscribe" : "postTour.subscribe.purchase",
            secondaryIdentifier: "postTour.subscribe.free",
            onPrimary: {
                if isWeb {
                    // Stay on the prompt: the user returns from the browser and picks
                    // "Continue with the free plan" or is already subscribed.
                    openURL(WebCheckoutPolicy.checkoutURL(seats: Self.startingMemberCount))
                } else {
                    Task { await purchase() }
                }
            },
            onSecondary: { coordinator.finish(.subscribe) },
            extra: { details }
        )
        .task { if !store.loaded { await store.loadProducts() } }
        .task {
            quote.configure(service: appState.service)
            await gate.waitUntilResolved()
            if gate.isEnabled { quote.request(seats: Self.startingMemberCount, immediate: true) }
        }
        // An Apple plan is already active on the server: the upsell is pointless.
        .onChange(of: quote.blockedByApple) { _, blocked in
            if blocked { coordinator.finish(.subscribe) }
        }
    }

    // StoreKit variant (App Store 3.1.2): price, period and auto-renew terms next to
    // the CTA, plus Restore Purchases and Privacy/Terms links. The web variant
    // replaces the Apple terms line with the one-line payment footnote.
    private var details: some View {
        VStack(spacing: 0) {
            if let message {
                Text(message)
                    .font(Font.system(size: Theme.fontSM))
                    .foregroundColor(Theme.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityIdentifier("postTour.subscribe.message")
            }
            if isWeb {
                WebCheckoutFootnote().padding(.top, 12)
            } else if let price {
                // Non-breaking spaces keep the last line from holding one word.
                Text("\(price) per month for 1 member; larger groups cost more. Renews monthly until you cancel in Settings\u{00A0}> Apple\u{00A0}ID\u{00A0}>\u{00A0}Subscriptions.")
                    .font(Font.system(size: Theme.fontXS))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            } else {
                Text("Renews monthly until you cancel in Settings\u{00A0}> Apple\u{00A0}ID\u{00A0}>\u{00A0}Subscriptions.")
                    .font(Font.system(size: Theme.fontXS))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            HStack(spacing: Theme.spacingSM) {
                Button(restoring ? "Restoring..." : "Restore Purchases") {
                    Task { await restore() }
                }
                .buttonStyle(.plain)
                .font(Font.system(size: Theme.fontSM, weight: .medium))
                .foregroundColor(Theme.gold)
                .disabled(restoring || store.purchasing)
                Text("\u{00B7}").foregroundColor(Theme.borderGold)
                Link("Privacy Policy", destination: URL(string: "https://fellowscript.com/#/privacy")!)
                Text("\u{00B7}").foregroundColor(Theme.borderGold)
                Link("Terms of Use", destination: URL(string: "https://fellowscript.com/#/terms")!)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .font(Font.system(size: Theme.fontXS))
            .foregroundColor(Theme.textSecondary)
            .frame(minHeight: 44)
        }
    }

    private func purchase() async {
        guard let uid = appState.currentUser?.user_id else { return }
        message = nil
        store.lastError = nil
        let ok = await store.purchase(memberCount: Self.startingMemberCount, userId: uid, service: appState.service)
        if ok {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            coordinator.finish(.subscribe)
        } else if let err = store.lastError {
            // Cancel returns false with no error: stay put, free exit visible.
            message = err
        }
    }

    private func restore() async {
        guard let uid = appState.currentUser?.user_id else { return }
        message = nil
        restoring = true
        defer { restoring = false }
        store.lastError = nil
        let ok = await store.restore(userId: uid, service: appState.service)
        if !ok, let err = store.lastError {
            message = err
        } else if !(await store.activeEntitlementProductIDs()).isEmpty {
            coordinator.finish(.subscribe)
        } else {
            message = "We didn't find an active subscription to restore."
        }
    }
}

// MARK: - Host

struct PostTourPromptHost: View {
    let prompt: PostTourPrompt
    @ObservedObject var coordinator: PostTourPromptsCoordinator

    var body: some View {
        switch prompt {
        case .notifications: NotificationsPromptView(coordinator: coordinator)
        case .subscribe:     SubscribePromptView(coordinator: coordinator)
        }
    }
}
