// FriendRequestDeclineButton.swift (task 20261030-profile-everywhere)
// Quiet ghost pill that sits next to Accept on an incoming friend-request row.
// Same compact height as the gold Accept pill, with a 44pt tap target.

import SwiftUI

struct FriendRequestDeclineButton: View {
    let username: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Decline")
                .font(.system(size: Theme.fontXS, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .overlay(Capsule().stroke(Theme.parchment.opacity(0.14), lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Decline friend request from \(username)")
    }
}
