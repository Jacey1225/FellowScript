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

/// Reports the owner's Join requests list to the badge store while it is on
/// screen with a successfully loaded list: that is the "seen" event (and keeps
/// the count in step after approve / deny / undo / reload).
struct JoinRequestBadgeSync: ViewModifier {
    let groupId: String
    let loaded: Bool
    let pendingCount: Int
    /// Newest created_at among the listed requests (nil when unknown/empty).
    var newestRequestAt: String? = nil
    @EnvironmentObject var appState: AppState

    private func report() {
        guard loaded else { return }
        appState.badges.joinRequestsViewed(groupId: groupId, pendingCount: pendingCount,
                                           newestRequestAt: newestRequestAt)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: pendingCount) { _, _ in report() }
            .onChange(of: loaded) { _, _ in report() }
            .onChange(of: newestRequestAt) { _, _ in report() }
            .onAppear { report() }
    }
}

/// Reports the Account screen's friend-request list to the badge store. The
/// "seen" event fires only while the screen is on screen AND its list has
/// loaded successfully; the list also keeps the pending ids in step after
/// accept / decline.
struct FriendRequestBadgeSync: ViewModifier {
    let ids: [String]
    let loaded: Bool
    @EnvironmentObject var appState: AppState
    @State private var visible = false

    private func report() {
        guard visible, loaded else { return }
        appState.badges.friendRequestsViewed(ids: ids)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; report() }
            .onDisappear { visible = false }
            .onChange(of: ids) { _, _ in report() }
            .onChange(of: loaded) { _, _ in report() }
    }
}
