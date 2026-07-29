// Guideline 1.2: lists users the account has blocked, with an unblock action.
// Pushed from AccountView's "Privacy & Safety" section.

import SwiftUI

struct BlockedUsersView: View {
    let userId: String
    let service: DataServiceProtocol

    @State private var blocked: [FSBlockedUser] = []
    @State private var isLoading = true
    @State private var unblockingId: String? = nil

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView().tint(Theme.gold); Spacer() }
            } else if blocked.isEmpty {
                VStack(spacing: Theme.spacingMD) {
                    Spacer()
                    Image(systemName: "hand.raised")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(Theme.gold.opacity(0.30))
                    Text("You haven't blocked anyone.")
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                }
                .padding()
            } else {
                List(blocked) { user in
                    HStack {
                        Text(user.username.isEmpty ? user.user_id : user.username)
                            .font(.lora(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                        Spacer()
                        if unblockingId == user.user_id {
                            ProgressView().tint(Theme.gold)
                        } else {
                            Button("Unblock") { Task { await unblock(user) } }
                                .font(.lora(Theme.fontSM))
                                .foregroundColor(Theme.gold)
                        }
                    }
                    .listRowBackground(Theme.cardBg)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.bgPage)
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        blocked = (try? await service.fetchBlockedUsers(userId: userId)) ?? []
        isLoading = false
    }

    private func unblock(_ user: FSBlockedUser) async {
        unblockingId = user.user_id
        if (try? await service.unblockUser(userId: userId, blockedId: user.user_id)) != nil {
            blocked.removeAll { $0.user_id == user.user_id }
        }
        unblockingId = nil
    }
}
