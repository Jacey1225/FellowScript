// JoinRequestRowDot.swift -- task 20261016-notification-badges-logic.
// Red dot on an owned group's row avatar while it has pending join requests.
// Sits at the avatar's top-trailing corner so it reads as distinct from the
// unread dot (top-leading). Reuses the .unreadBadge spring transition, which
// already honours Reduce Motion. Accessibility is folded into the row label
// (AppState.rowAccessibilityLabel), so the dot itself is hidden from VoiceOver.

import SwiftUI

struct JoinRequestRowDot: View {
    let contact: FSContact
    var size: CGFloat = 12
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if contact.type == .group, appState.badges.joinRequestCount(forGroup: contact.id) > 0 {
            Circle()
                .fill(Theme.error)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Theme.bgPage, lineWidth: 2))
                .offset(x: 2, y: -2)
                .transition(.unreadBadge(reduceMotion: reduceMotion))
                .accessibilityHidden(true)
        }
    }
}

/// Pushes a proven pending-join-request count into the app-level store when a
/// screen that fetched it changes (approve / deny / undo / reload).
struct JoinRequestBadgeSync: ViewModifier {
    let groupId: String
    let loaded: Bool
    let pendingCount: Int
    @EnvironmentObject var appState: AppState

    func body(content: Content) -> some View {
        content.onChange(of: pendingCount) { _, newValue in
            if loaded { appState.badges.setJoinRequestCount(groupId: groupId, newValue) }
        }
        .onChange(of: loaded) { _, nowLoaded in
            if nowLoaded { appState.badges.setJoinRequestCount(groupId: groupId, pendingCount) }
        }
    }
}

/// Mirrors the Account screen's friend-request list length into the store.
struct FriendRequestBadgeSync: ViewModifier {
    let count: Int
    @EnvironmentObject var appState: AppState

    func body(content: Content) -> some View {
        content.onChange(of: count) { _, newValue in appState.badges.setFriendRequestCount(newValue) }
    }
}
