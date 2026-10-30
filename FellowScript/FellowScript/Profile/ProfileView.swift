// ProfileView.swift (task 20261030-user-profiles)
// Profile sheet (design B1): identity card, bio, one primary action, overflow
// menu with Unfriend / Block / Report. Reuses ReportUserSheet, the existing
// block flow (managed in BlockedUsersView) and the existing DM flow
// (AppState.pendingChatContact).
//
// States: skeleton while loading with no cache (static, no shimmer); cached
// profile shown immediately with a quiet "Updating..." line; failed refresh
// keeps the cached profile; first-load failure shows Try again; 404 shows the
// single "This profile isn't available." screen for unknown/blocked/suspended.

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: ProfileViewModel
    private let allowMessage: Bool

    @State private var showBlockConfirm = false
    @State private var showReport = false

    init(viewerId: String, targetId: String, service: DataServiceProtocol, allowMessage: Bool = true) {
        _vm = StateObject(wrappedValue: ProfileViewModel(viewerId: viewerId, targetId: targetId, service: service))
        self.allowMessage = allowMessage
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, Theme.spacingLG)
                    .padding(.vertical, Theme.spacingMD)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
            }
            .warmBloomBackground()
            .navigationTitle(vm.isSelf ? "My Profile" : "Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.foregroundColor(Theme.gold)
                }
                if let profile = vm.profile, profile.relationship != .selfUser {
                    ToolbarItem(placement: .primaryAction) { overflowMenu(profile) }
                }
            }
            .overlay(alignment: .bottom) { undoBar }
        }
        .task { await vm.load() }
        .onDisappear { Task { await vm.commitUnfriendNow() } }
        .confirmationDialog("Block \(vm.profile?.username ?? "this user")?", isPresented: $showBlockConfirm,
                            titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task { if await vm.block() { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your friendship and hides both of your profiles from each other. We also send a report to our team. You can unblock later in Account, Blocked Users.")
        }
        .sheet(isPresented: $showReport) {
            if let profile = vm.profile {
                ReportUserSheet(contact: FSContact(id: profile.user_id, name: profile.username, type: .friend)) { reason, detail in
                    Task { await vm.report(reason: reason, detail: detail) }
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { vm.actionError != nil },
            set: { if !$0 { vm.actionError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.actionError = nil }
        } message: {
            Text(vm.actionError ?? "")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: Content states

    @ViewBuilder private var content: some View {
        if let profile = vm.profile {
            VStack(spacing: Theme.spacingMD) {
                ProfileHeaderView(vm: vm, profile: profile)
                ProfileActionsView(vm: vm, profile: profile, canMessage: allowMessage) { message(profile) }
                statusLine
            }
        } else {
            switch vm.phase {
            case .loading:     skeleton
            case .unavailable: unavailable
            case .failed:      failed
            case .loaded:      skeleton   // transient: profile is set in the same turn
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let message = vm.statusMessage {
            HStack(spacing: 8) {
                Text(message).font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                if message.hasPrefix("Couldn't refresh") {
                    Button("Retry") { Task { await vm.load() } }
                        .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                        .frame(minHeight: 44)
                }
            }
            .multilineTextAlignment(.center)
        } else if vm.isRefreshing {
            Text("Updating...").font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
        }
    }

    private var skeleton: some View {
        VStack(spacing: Theme.spacingMD) {
            Circle().fill(Color.white.opacity(0.08)).frame(width: 96, height: 96)
            Capsule().fill(Color.white.opacity(0.08)).frame(width: 140, height: 18)
            Capsule().fill(Color.white.opacity(0.06)).frame(width: 220, height: 14)
            Capsule().fill(Color.white.opacity(0.06)).frame(height: 50).padding(.top, Theme.spacingMD)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.spacingLG)
        .widgetCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading profile")
    }

    private var unavailable: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44, weight: .light)).foregroundColor(Theme.gold.opacity(0.4))
                .accessibilityHidden(true)
            Text("This profile isn't available.")
                .font(.inter(Theme.fontBody)).foregroundColor(Theme.textSecondary)
            Button("Back") { dismiss() }
                .font(.inter(Theme.fontBody, weight: .semibold)).foregroundColor(Theme.gold)
                .frame(minWidth: 44, minHeight: 44)
        }
        .frame(maxWidth: .infinity).padding(.top, Theme.spacingXL)
    }

    private var failed: some View {
        VStack(spacing: Theme.spacingMD) {
            Text("Couldn't load this profile.")
                .font(.inter(Theme.fontBody)).foregroundColor(Theme.textSecondary)
            Button("Try again") { Task { await vm.load() } }
                .font(.inter(Theme.fontBody, weight: .semibold)).foregroundColor(Theme.gold)
                .frame(minWidth: 44, minHeight: 44)
        }
        .frame(maxWidth: .infinity).padding(.top, Theme.spacingXL)
    }

    // MARK: Overflow menu and undo bar

    private func overflowMenu(_ profile: FSProfile) -> some View {
        Menu {
            if profile.relationship == .friends && !vm.unfriendPending {
                Button("Unfriend", systemImage: "person.badge.minus", role: .destructive) { vm.beginUnfriend() }
            }
            Button("Block", systemImage: "hand.raised.fill", role: .destructive) { showBlockConfirm = true }
            Button("Report", systemImage: "flag.fill") { showReport = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundColor(Theme.gold)
        .accessibilityLabel("More options for \(profile.username)")
    }

    @ViewBuilder private var undoBar: some View {
        if vm.unfriendPending, let name = vm.profile?.username {
            HStack {
                Text("Removed \(name).").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                Spacer()
                Button("Undo") { vm.undoUnfriend() }
                    .font(.inter(Theme.fontSM, weight: .bold)).foregroundColor(Theme.gold)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, Theme.spacingMD)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSM).fill(Theme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSM).stroke(Theme.borderGoldDim, lineWidth: 1))
            .padding(Theme.spacingMD)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Message

    private func message(_ profile: FSProfile) {
        appState.pendingChatContact = FSContact(id: profile.user_id, name: profile.username, type: .friend,
                                                toUsers: [profile.user_id], photoUrl: profile.profile_photo_url)
        dismiss()
    }
}
