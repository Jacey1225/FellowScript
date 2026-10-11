// WaysToExploreSection.swift -- permanent "Ways to explore" section at the
// bottom of the Home tab (task 20261010-home-ways-to-explore; made
// non-dismissible by 20261011-home-group-activity-announcements). Two large cards:
// "Create a group" (existing AddGroupSheet + ChatViewModel.createGroup) and
// "Explore groups" (existing ExploreEntry/ExploreDestination Safari sheet,
// hidden when explorer_browse is unavailable -- fail closed). The section
// always shows (Create a group is unconditional); there is no dismiss control.

import SwiftUI

// ── Pure logic (unit-testable) ───────────────────────────────────────────────

enum WaysToExplore {

    enum Card: String, Equatable, CaseIterable {
        case createGroup
        case exploreGroups
    }

    /// Legacy "Maybe later"/"Not now" dismissal key. No longer read: a stored
    /// value is ignored so previously dismissed users see the section again.
    static func legacyDismissedKey(userId: String) -> String {
        "home.waysToExplore.dismissed.\(userId)"
    }

    /// Removes the obsolete per-user dismissal flag (housekeeping only; the
    /// section never consults it).
    static func clearLegacyDismissal(userId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyDismissedKey(userId: userId))
    }

    /// Cards to show, in order. Explore appears only with a usable browse URL.
    static func visibleCards(exploreURL: URL?) -> [Card] {
        var cards: [Card] = [.createGroup]
        if exploreURL != nil { cards.append(.exploreGroups) }
        return cards
    }

    /// Section is shown whenever it has any card (always true: Create a group).
    static func showsSection(cards: [Card]) -> Bool {
        !cards.isEmpty
    }
}

// ── Card ─────────────────────────────────────────────────────────────────────

private struct WaysToExploreCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct WaysToExploreCard: View {
    let icon: String
    let title: String
    let detail: String
    let hint: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Theme.spacingMD) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.goldLight)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.gold.opacity(0.16)))
                    .overlay(Circle().stroke(Theme.gold.opacity(0.4), lineWidth: 1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.spacingXS) {
                    Text(title)
                        .font(.interScaled(Theme.fontHeading, weight: .bold, relativeTo: .headline))
                        .foregroundColor(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.spacingXS)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(Theme.spacingMD)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .glassCard(cornerRadius: Theme.radiusXL)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous))
        }
        .buttonStyle(WaysToExploreCardStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

// ── Section ──────────────────────────────────────────────────────────────────

struct WaysToExploreSection: View {
    @ObservedObject var chatVM: ChatViewModel
    @EnvironmentObject private var appState: AppState

    @State private var showAddGroup = false
    @State private var exploreDestination: ExploreDestination?

    private let userId: String

    init(chatVM: ChatViewModel, userId: String? = nil) {
        self.chatVM = chatVM
        self.userId = userId ?? ""
    }

    private var uid: String { appState.currentUser?.user_id ?? userId }

    var body: some View {
        let exploreURL = ExploreEntry.browseURL(from: appState.capabilities)
        let cards = WaysToExplore.visibleCards(exploreURL: exploreURL)
        Group {
            if WaysToExplore.showsSection(cards: cards) {
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    Text("Find your people")
                        .font(.interScaled(Theme.fontDisplayMD, weight: .bold, relativeTo: .title2))
                        .foregroundColor(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("ways-to-explore-heading")

                    ForEach(cards, id: \.self) { card in
                        switch card {
                        case .createGroup:
                            WaysToExploreCard(
                                icon: "bubble.left.and.bubble.right",
                                title: "Start a group",
                                detail: "Bring friends together in a chat of your own",
                                hint: "Opens the new group form",
                                identifier: "ways-to-explore-create-group"
                            ) { showAddGroup = true }
                        case .exploreGroups:
                            WaysToExploreCard(
                                icon: "safari",
                                title: "Browse groups",
                                detail: "See what is popular and close to you",
                                hint: "Opens the community Explore page in a browser view",
                                identifier: "ways-to-explore-explore-groups"
                            ) {
                                if let exploreURL { exploreDestination = ExploreDestination(url: exploreURL) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, Theme.spacingLG)
                .transition(.opacity)
            }
        }
        .task { if !uid.isEmpty { WaysToExplore.clearLegacyDismissal(userId: uid) } }
        .exploreSafariSheet($exploreDestination)
        .sheet(isPresented: $showAddGroup) {
            AddGroupSheet(friends: chatVM.friends) { title, memberIds in
                let id = uid
                Task { await chatVM.createGroup(title: title, memberIds: memberIds, userId: id, service: appState.service, fromHome: true) }
            }
        }
        .alert("Couldn't Create Group", isPresented: Binding(
            get: { chatVM.showsGroupError(onHome: true) },
            set: { if !$0 { chatVM.groupError = nil } }
        )) {
            Button("OK", role: .cancel) { chatVM.groupError = nil }
        } message: {
            Text(chatVM.groupError ?? "")
        }
    }
}
