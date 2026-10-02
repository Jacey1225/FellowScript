// UpgradePrompt.swift — the reusable "Not available on the Free plan" prompt
// (task 20261002-free-plan-limits-ui). One shared presenter (singleton, like
// CallController.shared, so view-models can raise it without environment
// plumbing) and one `.upgradePrompt()` view modifier hosts attach once per
// presentation context (root, and sheets/covers that sit above the root).
// Visual recipe: translucent warm-brown card over ultraThinMaterial with a soft
// gold border, matching the web .fs-signin-card.

import SwiftUI
import Combine

@MainActor
final class UpgradePromptCenter: ObservableObject {
    static let shared = UpgradePromptCenter()

    @Published private(set) var prompt: BlockedInfo? = nil
    /// Bumped on every block so screens showing usage can refresh their meters.
    @Published private(set) var blockCount = 0
    /// Set by Subscribe; AccountView scrolls to the subscription section, then clears it.
    @Published var scrollToSubscription = false

    /// Shows the prompt when `error` is a plan block (latest replaces content,
    /// never stacks). Returns true when it handled the error.
    @discardableResult
    func present(for error: Error) -> Bool {
        guard let info = PlanBlock.info(from: error) else { return false }
        prompt = info
        blockCount += 1
        return true
    }

    func dismiss() { prompt = nil }

    func subscribe() {
        prompt = nil
        scrollToSubscription = true
        NotificationCenter.default.post(name: .fsOpenSubscriptionPlans, object: nil)
    }
}

extension View {
    /// Overlays the upgrade prompt on this view. `onSubscribe` lets a hosting
    /// sheet dismiss itself so the Account tab is actually reachable.
    func upgradePrompt(onSubscribe: (() -> Void)? = nil) -> some View {
        modifier(UpgradePromptModifier(onSubscribe: onSubscribe))
    }
}

struct UpgradePromptModifier: ViewModifier {
    @ObservedObject private var center = UpgradePromptCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSubscribe: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let info = center.prompt {
                    UpgradePromptCard(
                        info: info,
                        onSubscribe: { center.subscribe(); onSubscribe?() },
                        onDismiss: { center.dismiss() }
                    )
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.96)).combined(with: .offset(y: 12)))
                    .zIndex(100)
                }
            }
            // Eased spring in, never linear; opacity-only short fade under Reduce Motion.
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.86),
                       value: center.prompt)
    }
}

struct UpgradePromptCard: View {
    let info: BlockedInfo
    let onSubscribe: () -> Void
    let onDismiss: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: Theme.spacingSM) {
                    ZStack {
                        Circle().fill(Theme.gold.opacity(0.16)).frame(width: 64, height: 64)
                        Circle().stroke(Color(hex: "#FFE1AA").opacity(0.22), lineWidth: 1).frame(width: 64, height: 64)
                        Image(systemName: "crown.fill").font(.system(size: 28)).foregroundColor(Theme.gold)
                    }
                    .accessibilityHidden(true)

                    Text(PlanBlock.title)
                        .font(.playfair(Theme.fontDisplayMD))
                        .foregroundColor(Theme.goldLight)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                        .accessibilityIdentifier("upgradePromptTitle")

                    Text("\(PlanBlock.body(for: info)) \(PlanBlock.cta)")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.textPrimary.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("upgradePromptBody")

                    Button(action: onSubscribe) {
                        Text("Subscribe")
                            .font(.inter(Theme.fontBody, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(LinearGradient(colors: [Theme.gold, Theme.goldLight],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.top, Theme.spacingXS)
                    .accessibilityIdentifier("upgradePromptSubscribe")

                    Button(action: onDismiss) {
                        Text("Not now")
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.textPrimary.opacity(0.78))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("upgradePromptDismiss")
                }
                .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(hex: "#5C442A").opacity(0.34))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(hex: "#FFE1AA").opacity(0.20), lineWidth: 1)
            )
            .topEdgeHighlight(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, Theme.spacingLG)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onDismiss)
        }
        .onAppear { titleFocused = true }
    }
}
