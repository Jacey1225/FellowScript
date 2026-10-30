// ProfileEntryViews.swift (task 20261030-user-profiles)
// Self-contained entry points that own their own sheet state, so host views
// (AccountView, friend-request rows) need only a one-line hook-in.

import SwiftUI

/// A tappable avatar that opens that user's profile (design A1). The avatar is
/// at least 44x44 to tap even when drawn smaller; VoiceOver gets a labelled button.
struct ProfileLinkedAvatar: View {
    @EnvironmentObject var appState: AppState
    let userId: String
    let username: String
    var photoURL: String? = nil
    var diameter: CGFloat = 36
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            AvatarView(initial: String(username.prefix(1)).uppercased(), photoURL: photoURL,
                       diameter: diameter, fillColor: Theme.gold.opacity(0.15), textColor: Theme.gold)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View \(username)'s profile")
        .sheet(isPresented: $show) {
            ProfileView(viewerId: appState.currentUser?.user_id ?? "", targetId: userId,
                        service: appState.service)
        }
    }
}

/// "View my profile" row for the Account screen (opens the same ProfileView; edit lives there).
struct MyProfileRow: View {
    @EnvironmentObject var appState: AppState
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20)).foregroundColor(Theme.gold)
                Text("View my profile")
                    .font(.system(size: Theme.fontBody, weight: .semibold)).foregroundColor(Theme.parchment)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .glassCard(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows how friends see you and lets you edit your bio")
        .sheet(isPresented: $show) {
            ProfileView(viewerId: appState.currentUser?.user_id ?? "",
                        targetId: appState.currentUser?.user_id ?? "", service: appState.service)
        }
    }
}
