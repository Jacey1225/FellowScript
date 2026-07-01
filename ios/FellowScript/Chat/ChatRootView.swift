// SOURCE: components/MessagingSidebar.jsx (Friends section, Groups section, ChatView),
//         hooks/useMessaging.js, hooks/useAgentChat.js, hooks/useSessions.js,
//         components/SessionCreator.jsx
// KEY STATE: selectedSegment (Friends/Groups/Agents), contacts, groups, agents,
//            activeContact, messages, sessions
// INTERACTIONS: segment switch, tap thread → ChatThreadView, + add friend/group/agent,
//               unread badge on Chat tab
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift

import SwiftUI

// ── Root chat view with three segments ────────────────────────────────────────
struct ChatRootView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ChatViewModel()
    @State private var selectedSegment = 0
    @State private var showAddFriend   = false
    @State private var showAddGroup    = false
    @State private var activeContact:  FSContact? = nil
    @State private var activeAgent:    FSAgent?   = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Segmented control — Friends / Groups / AI Agents
                    Picker("Chat type", selection: $selectedSegment) {
                        Text("Friends").tag(0)
                        Text("Groups").tag(1)
                        Text("Agents").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.navBg)

                    Divider().background(Theme.borderGoldFaint)

                    // Content per segment
                    Group {
                        switch selectedSegment {
                        case 0: friendsList
                        case 1: groupsList
                        default: agentsList
                        }
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: addAction) {
                        Image(systemName: "plus")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel(selectedSegment == 0 ? "Add friend" : selectedSegment == 1 ? "New group" : "New agent")
                }
            }
        }
        .task { await vm.load(userId: appState.currentUser?.user_id ?? "") }
        .sheet(item: $activeContact) { contact in
            ChatThreadView(contact: contact, user: appState.currentUser)
        }
        .sheet(item: $activeAgent) { agent in
            AgentChatView(agent: agent)
        }
        .sheet(isPresented: $showAddFriend) { AddFriendSheet() }
        .sheet(isPresented: $showAddGroup)  { AddGroupSheet(friends: vm.friends) }
    }

    // ── Friends list (mirrors MessagingSidebar friends section) ────────────────
    private var friendsList: some View {
        Group {
            if vm.isLoading {
                loadingView
            } else if vm.friends.isEmpty {
                emptyState(
                    icon:    "person.badge.plus",
                    message: "No friends yet.",
                    hint:    "Tap + to add a friend by username."
                )
            } else {
                List(vm.friends) { contact in
                    ContactRow(contact: contact)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.borderGoldFaint)
                        .onTapGesture { activeContact = contact }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { vm.removeFriend(id: contact.id) } label: {
                                Label("Remove", systemImage: "person.badge.minus")
                            }
                        }
                        .accessibilityLabel("Chat with \(contact.name)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // ── Groups list ────────────────────────────────────────────────────────────
    private var groupsList: some View {
        Group {
            if vm.isLoading {
                loadingView
            } else if vm.groups.isEmpty {
                emptyState(
                    icon:    "person.3",
                    message: "No groups yet.",
                    hint:    "Tap + to create a study group."
                )
            } else {
                List(vm.groups) { contact in
                    ContactRow(contact: contact)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.borderGoldFaint)
                        .onTapGesture { activeContact = contact }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { vm.leaveGroup(id: contact.id) } label: {
                                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                        .accessibilityLabel("Open group: \(contact.name)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // ── AI agents list ─────────────────────────────────────────────────────────
    private var agentsList: some View {
        Group {
            if vm.isLoading {
                loadingView
            } else if vm.agents.isEmpty {
                emptyState(
                    icon:    "brain",
                    message: "No agents yet.",
                    hint:    "Create an agent in Account settings."
                )
            } else {
                List(vm.agents) { agent in
                    AgentRow(agent: agent)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.borderGoldFaint)
                        .onTapGesture { activeAgent = agent }
                        .accessibilityLabel("Chat with agent: \(agent.displayLabel)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var loadingView: some View {
        VStack { Spacer(); ProgressView().tint(Theme.gold); Spacer() }
    }

    private func addAction() {
        switch selectedSegment {
        case 0: showAddFriend = true
        case 1: showAddGroup  = true
        default: break
        }
    }

    @ViewBuilder
    private func emptyState(icon: String, message: String, hint: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.gold.opacity(0.30))
            Text(message)
                .font(.lora(Theme.fontBody))
                .foregroundColor(Theme.textSecondary)
            Text(hint)
                .font(.lora(Theme.fontSM))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .accessibilityLabel("\(message) \(hint)")
    }
}

// ── ViewModel ─────────────────────────────────────────────────────────────────
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var friends:   [FSContact] = []
    @Published var groups:    [FSContact] = []
    @Published var agents:    [FSAgent]   = []
    @Published var isLoading  = true

    func load(userId: String) async {
        isLoading = true
        defer { isLoading = false }
        let (contacts, _) = (try? await MockDataService.shared.fetchContacts(userId: userId)) ?? ([], [:])
        friends = contacts.filter { $0.type == .friend }
        groups  = contacts.filter { $0.type == .group }
        agents  = MockDataService.mockAgents
    }

    func removeFriend(id: String) { friends.removeAll { $0.id == id } }
    func leaveGroup(id: String)   { groups.removeAll  { $0.id == id } }
}

// ── Contact row (mirrors ContactItem in MessagingSidebar.jsx) ─────────────────
struct ContactRow: View {
    let contact: FSContact

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Theme.gold.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(String(contact.name.prefix(1)).uppercased())
                    .font(.playfair(Theme.fontBody))
                    .foregroundColor(Theme.gold)
            }
            .overlay(Circle().stroke(Theme.borderGold, lineWidth: 1))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(contact.name)
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment.opacity(0.80))
                    if contact.type == .group {
                        Image(systemName: "person.3.fill")
                            .font(.caption2)
                            .foregroundColor(Theme.gold.opacity(0.55))
                    }
                }
                if !contact.preview.isEmpty {
                    Text(contact.preview)
                        .font(.lora(Theme.fontSM))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.spacingSM)
    }
}

// ── Agent row ─────────────────────────────────────────────────────────────────
struct AgentRow: View {
    let agent: FSAgent

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle()
                    .fill(Theme.gold.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "brain")
                    .foregroundColor(Theme.gold)
            }
            .overlay(Circle().stroke(Theme.borderGold, lineWidth: 1))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayLabel)
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment.opacity(0.80))
                Text(agent.enabled ? "Active" : "Disabled")
                    .font(.lora(Theme.fontXS))
                    .foregroundColor(agent.enabled ? Theme.success.opacity(0.80) : Theme.textMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.spacingSM)
    }
}

// ── Add friend sheet ──────────────────────────────────────────────────────────
struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Search by username") {
                    TextField("Username", text: $username)
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                        .autocapitalization(.none)
                        .accessibilityLabel("Enter username to add as friend")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Send Request") { dismiss() }
                        .foregroundColor(Theme.gold)
                        .disabled(username.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ── Add group sheet (mirrors GroupModal in MessagingSidebar.jsx) ───────────────
struct AddGroupSheet: View {
    let friends: [FSContact]
    @Environment(\.dismiss) private var dismiss
    @State private var groupName    = ""
    @State private var selectedIds  = Set<String>()

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("Study Group", text: $groupName)
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                        .accessibilityLabel("Group name field")
                }
                Section("Members") {
                    ForEach(friends) { f in
                        HStack {
                            Text(f.name)
                                .font(.lora(Theme.fontBody))
                                .foregroundColor(Theme.parchment.opacity(0.70))
                            Spacer()
                            if selectedIds.contains(f.id) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Theme.gold)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedIds.contains(f.id) { selectedIds.remove(f.id) }
                            else                           { selectedIds.insert(f.id) }
                        }
                        .accessibilityLabel("\(f.name). \(selectedIds.contains(f.id) ? "Selected" : "Not selected")")
                        .accessibilityAddTraits(selectedIds.contains(f.id) ? .isSelected : [])
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") { dismiss() }
                        .foregroundColor(Theme.gold)
                        .disabled(groupName.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
