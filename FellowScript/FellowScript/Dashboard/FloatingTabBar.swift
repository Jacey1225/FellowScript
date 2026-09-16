// FloatingTabBar.swift
// Replaces the default TabView chrome with a floating, rounded pill-style bar
// (dark ground, gold accents), matching the FellowScript Dashboard mockup. Same
// 5 destinations / SF Symbols as ContentView's mainTabView — this re-skins the
// chrome only; screen content and routing are unchanged.
//
// SOURCE MAPPING: ContentView.swift (Tab enum + mainTabView), Theme/Theme.swift

import SwiftUI

struct FloatingTabBar: View {
    @Binding var selection: ContentView.Tab
    var inCallBarVisible: Bool = false   // shift up when MinimizedCallBar is showing

    // Task 20260916-call-bar-nav-overlap: the previous flat `60` bump sat well
    // inside MinimizedCallBar's own 56–106pt bottom range (bottomInset...
    // bottomInset+height), so the two overlapped and the call bar (rendered on
    // top, in ContentView's outer overlay) blocked tab-bar taps. Derived from
    // MinimizedCallBar's own constants plus a real visual gap (Theme.spacingMD)
    // so this bar's bottom padding always clears the call bar's actual top
    // edge, and the two can't independently drift apart again.
    static let inCallBottomPadding: CGFloat =
        MinimizedCallBar.bottomInset + MinimizedCallBar.height + Theme.spacingMD

    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Task 20260913-chat-unread-badges: brief scale pulse when the aggregate
    // unread count changes while the badge is already visible (e.g. 2 → 3),
    // signalling "something changed" without a discrete text-swap flash.
    // Compared against `previousUnreadCount` (below) rather than an
    // `.onChange(of:)` two-parameter oldValue -- matches this file's/this
    // codebase's existing single-parameter `.onChange` convention.
    @State private var badgePulse = false
    @State private var previousUnreadCount = 0

    private let items: [(tab: ContentView.Tab, label: String, symbol: String)] = [
        (.home,    "Home",    "house.fill"),
        (.bible,   "Bible",   "book.fill"),
        (.notes,   "Notes",   "note.text"),
        (.chat,    "Chat",    "message.fill"),
        (.account, "Account", "person.crop.circle"),
    ]

    private var unreadLabel: String {
        appState.unreadConversationCount > 9 ? "9+" : "\(appState.unreadConversationCount)"
    }

    // ── Chat tab unread badge (design-notes.md: numeral count of unread
    // conversations, capped at 9+) — rendered in both the selected and
    // unselected icon states below via this one shared view. ─────────────
    private var chatUnreadBadge: some View {
        Text(unreadLabel)
            .font(.system(size: Theme.fontXXS, weight: .heavy))
            .foregroundColor(Theme.parchment)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                Capsule()
                    .fill(Theme.error)
                    .overlay(Capsule().stroke(Theme.navBg, lineWidth: 1.5))
            )
            .offset(x: -4, y: -2)
            .scaleEffect(badgePulse ? 1.15 : 1.0)
            .transition(.unreadBadge(reduceMotion: reduceMotion))
            .accessibilityHidden(true) // folded into the Chat item's own accessibilityLabel below instead
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.tab) { item in
                let isSelected = selection == item.tab
                let isChat = item.tab == .chat
                let showBadge = isChat && appState.unreadConversationCount > 0
                Button {
                    withMotionAwareAnimation(.spring(response: 0.32, dampingFraction: 0.82), reduceMotion: reduceMotion) {
                        selection = item.tab
                    }
                } label: {
                    if isSelected {
                        // Active tab: gold pill with label (the "Home" pill in the mock).
                        HStack(spacing: 7) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .overlay(alignment: .topLeading) {
                                    if showBadge { chatUnreadBadge }
                                }
                            Text(item.label)
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(Color(hex: "#24170A"))
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(Capsule())
                    } else {
                        Image(systemName: item.symbol)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundColor(Theme.tabInactive)
                            .frame(width: 50, height: 46)
                            .overlay(alignment: .topLeading) {
                                if showBadge { chatUnreadBadge }
                            }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isChat && appState.unreadConversationCount > 0
                        ? "\(item.label), \(appState.unreadConversationCount == 1 ? "unread messages" : "\(appState.unreadConversationCount) unread conversations")"
                        : item.label
                )
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        // Task 20260913-chat-unread-badges: brief pulse on any nonzero →
        // nonzero change (e.g. 2 → 3); the 0 ↔ nonzero cases are already
        // handled by chatUnreadBadge's own insertion/removal transition
        // above, driven by `showBadge` appearing/disappearing.
        .onChange(of: appState.unreadConversationCount) { newValue in
            defer { previousUnreadCount = newValue }
            guard previousUnreadCount > 0, newValue > 0, newValue != previousUnreadCount else { return }
            withMotionAwareAnimation(.spring(response: 0.32, dampingFraction: 0.8), reduceMotion: reduceMotion) {
                badgePulse = true
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 160_000_000)
                withMotionAwareAnimation(.spring(response: 0.32, dampingFraction: 0.8), reduceMotion: reduceMotion) {
                    badgePulse = false
                }
            }
        }
        .padding(7)
        .background(
            Capsule()
                .fill(Color(hex: "#120D08").opacity(0.94))
                .overlay(
                    Capsule().stroke(Color(hex: "#D4922A").opacity(0.24), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.8), radius: 18, x: 0, y: 8)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, inCallBarVisible ? Self.inCallBottomPadding : 26)
    }
}
