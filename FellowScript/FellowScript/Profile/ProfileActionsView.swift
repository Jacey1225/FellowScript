// ProfileActionsView.swift (task 20261030-user-profiles)
// One state-driven primary action under the identity card (design C1).
// Destructive actions (Unfriend / Block / Report) live in ProfileView's
// overflow menu, not here. There is no "Decline" because the API has no
// decline endpoint yet.

import SwiftUI

struct ProfileActionsView: View {
    @ObservedObject var vm: ProfileViewModel
    let profile: FSProfile
    let canMessage: Bool
    let onMessage: () -> Void

    private var state: FSProfileRelationship {
        vm.unfriendPending && profile.relationship == .friends ? .none : profile.relationship
    }

    var body: some View {
        switch state {
        case .none:
            primary("Add friend", a11y: "Add \(profile.username) as a friend", busy: vm.busy) {
                Task { await vm.addFriend() }
            }
        case .requestSent:
            primary("Request sent", a11y: "Friend request sent to \(profile.username)", dimmed: true) {}
                .disabled(true)
        case .requestReceived:
            primary("Accept", a11y: "Accept friend request from \(profile.username)", busy: vm.busy) {
                Task { await vm.acceptRequest() }
            }
        case .friends:
            if canMessage {
                primary("Message", a11y: "Message \(profile.username)", action: onMessage)
            }
        case .selfUser:
            EmptyView()
        }
    }

    private func primary(_ title: String, a11y: String, busy: Bool = false, dimmed: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: { if !busy { action() } }) {
            ZStack {
                // Same width in both states so the busy spinner never shifts layout.
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(Theme.ink) }
            }
            .font(.inter(Theme.fontBody, weight: .bold))
            .foregroundColor(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(Theme.goldGradient))
            .opacity(dimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
        .accessibilityAddTraits(busy ? .updatesFrequently : [])
    }
}
