// ProfileEntryViews.swift (task 20261030-user-profiles)
// Self-contained entry points that own their own sheet state, so host views
// (AccountView, friend-request rows) need only a one-line hook-in.

import SwiftUI

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
            .fsCard(padding: 16)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows how friends see you and lets you edit your bio")
        .sheet(isPresented: $show) {
            ProfileView(viewerId: appState.currentUser?.user_id ?? "",
                        targetId: appState.currentUser?.user_id ?? "", service: appState.service)
        }
    }
}
