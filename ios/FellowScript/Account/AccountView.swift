// SOURCE: frontend/src/pages/Account.jsx
// KEY STATE: profileData, agents, requests, editLoading, deleteConfirm, agentModal, hbModal
// INTERACTIONS: edit profile (username/email/password), accept friend requests,
//               create/toggle/delete agents, add heartbeat, sign out, delete account
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift

import SwiftUI

@MainActor
final class AccountViewModel: ObservableObject {
    @Published var profileData:   FSUser?      = nil
    @Published var agents:         [FSAgent]   = []
    @Published var friendRequests: [(id: String, username: String)] = []
    @Published var isLoading       = true
    @Published var editMsg:        (type: AlertType, text: String)? = nil

    enum AlertType { case success, error, warning }

    // Stat counters — mirrors StatBox in Account.jsx
    var friendCount:    Int { profileData?.friends.count    ?? 0 }
    var groupCount:     Int { profileData?.groups.count     ?? 0 }
    var noteCount:      Int { profileData?.notes.count      ?? 0 }
    var highlightCount: Int { profileData?.highlights.count ?? 0 }

    func load(user: FSUser) async {
        isLoading = true
        defer { isLoading = false }
        profileData = user
        agents      = MockDataService.mockAgents
    }

    func toggleAgent(id: String, enabled: Bool) {
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].enabled = enabled
        }
    }

    func deleteAgent(id: String) {
        agents.removeAll { $0.id == id }
    }

    func createAgent(role: String) {
        let a = FSAgent(
            id:      UUID().uuidString,
            user_id: profileData?.user_id ?? "",
            role:    role.isEmpty ? "" : role,
            enabled: true
        )
        agents.append(a)
    }
}

// ── Root account view ─────────────────────────────────────────────────────────
struct AccountView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = AccountViewModel()

    // Edit profile
    @State private var username     = ""
    @State private var email        = ""
    @State private var password     = ""

    // Agents
    @State private var showNewAgent = false
    @State private var newAgentRole = ""
    @State private var showHbSheet: String? = nil  // agentId

    // Danger zone
    @State private var deleteConfirm  = ""
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                List {
                    // ── Profile header (avatar + name) ────────────────────────
                    profileHeader
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    // ── Stats (mirrors StatBox row) ───────────────────────────
                    statsSection

                    // ── Edit profile ──────────────────────────────────────────
                    editProfileSection

                    // ── Friend requests ───────────────────────────────────────
                    friendRequestsSection

                    // ── Agents ────────────────────────────────────────────────
                    agentsSection

                    // ── Sign Out ──────────────────────────────────────────────
                    Section {
                        Button(action: appState.signOut) {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(Theme.error)
                                .font(.lora(Theme.fontBody))
                        }
                        .accessibilityLabel("Sign out of your account")
                    }
                    .listRowBackground(Theme.cardBg)

                    // ── Danger zone ───────────────────────────────────────────
                    dangerZone
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            if let user = appState.currentUser {
                await vm.load(user: user)
                username = user.username
                email    = user.email
            }
        }
        .sheet(isPresented: $showNewAgent) {
            NewAgentSheet(role: $newAgentRole) {
                vm.createAgent(role: newAgentRole)
                newAgentRole = ""
            }
        }
        .sheet(item: Binding(
            get:  { showHbSheet.map { IdentifiableString(value: $0) } },
            set:  { showHbSheet = $0?.value }
        )) { item in
            HeartbeatSheet(agentId: item.value)
        }
        .alert("Delete Account", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                appState.signOut()
            }
        } message: {
            Text("This permanently deletes your account and all data. Type your username to confirm.")
        }
    }

    // ── Section builders ───────────────────────────────────────────────────────

    private var profileHeader: some View {
        VStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle()
                    .fill(Theme.gold.opacity(0.15))
                    .frame(width: 72, height: 72)
                Text(appState.currentUser?.initials ?? "?")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.gold)
            }
            .overlay(Circle().stroke(Theme.borderGold, lineWidth: 1.5))
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(vm.profileData?.username ?? "")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                Text(vm.profileData?.email ?? "")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingMD)
    }

    private var statsSection: some View {
        Section {
            HStack {
                StatBox(value: vm.friendCount,    label: "Friends")
                StatBox(value: vm.groupCount,     label: "Groups")
                StatBox(value: vm.noteCount,      label: "Notes")
                StatBox(value: vm.highlightCount, label: "Highlights")
            }
        } header: {
            sectionHeader("Overview")
        }
        .listRowBackground(Theme.cardBg)
    }

    private var editProfileSection: some View {
        Section {
            // Edit message
            if let msg = vm.editMsg {
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: msg.type == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    Text(msg.text)
                        .font(.lora(Theme.fontSM))
                }
                .foregroundColor(msg.type == .success ? Theme.success : Theme.error)
                .listRowBackground(
                    (msg.type == .success ? Theme.success : Theme.error).opacity(0.10)
                )
            }

            // Username
            HStack {
                Image(systemName: "person").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                TextField("Username", text: $username)
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .autocapitalization(.none)
                    .accessibilityLabel("Username field")
            }
            .listRowBackground(Theme.cardBg)

            // Email
            HStack {
                Image(systemName: "envelope").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                TextField("Email", text: $email)
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .accessibilityLabel("Email field")
            }
            .listRowBackground(Theme.cardBg)

            // Password
            HStack {
                Image(systemName: "lock").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                SecureField("New Password (leave blank to keep)", text: $password)
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .accessibilityLabel("New password field")
            }
            .listRowBackground(Theme.cardBg)

            Button(action: saveProfile) {
                Text("Save Changes")
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.gold)
            }
            .listRowBackground(Theme.cardBg)
            .accessibilityLabel("Save profile changes")
        } header: {
            sectionHeader("Edit Profile")
        }
    }

    private var friendRequestsSection: some View {
        Section {
            if vm.friendRequests.isEmpty {
                Text("No pending friend requests.")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.cardBg)
            } else {
                ForEach(vm.friendRequests, id: \.id) { req in
                    HStack {
                        ZStack {
                            Circle().fill(Theme.gold.opacity(0.15)).frame(width: 36, height: 36)
                            Text(String(req.username.prefix(1)).uppercased())
                                .font(.playfair(Theme.fontSM)).foregroundColor(Theme.gold)
                        }
                        VStack(alignment: .leading) {
                            Text(req.username).font(.lora(Theme.fontBody)).foregroundColor(Theme.parchment)
                            Text("Wants to be your friend").font(.lora(Theme.fontXS)).foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                        Button("Accept") { vm.friendRequests.removeAll { $0.id == req.id } }
                            .font(.lora(Theme.fontSM)).foregroundColor(Theme.gold)
                            .accessibilityLabel("Accept friend request from \(req.username)")
                    }
                    .listRowBackground(Theme.cardBg)
                }
            }
        } header: {
            sectionHeader("Friend Requests")
        }
    }

    private var agentsSection: some View {
        Section {
            // Description
            Text("Enabled agents participate in your chats and can summarize study sessions.")
                .font(.lora(Theme.fontSM))
                .foregroundColor(Theme.textMuted)
                .listRowBackground(Theme.cardBg)

            if vm.agents.isEmpty {
                Text("No agents yet. Tap + to create one.")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.cardBg)
            } else {
                ForEach($vm.agents) { $agent in
                    HStack(spacing: Theme.spacingMD) {
                        ZStack {
                            Circle().fill(Theme.gold.opacity(0.12)).frame(width: 36, height: 36)
                            Image(systemName: "brain").foregroundColor(Theme.gold)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayLabel)
                                .font(.lora(Theme.fontBody))
                                .foregroundColor(Theme.parchment)
                            Text(agent.role.isEmpty ? "Default spiritual guide role" : String(agent.role.prefix(60)))
                                .font(.lora(Theme.fontXS))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: $agent.enabled)
                            .labelsHidden()
                            .tint(Theme.gold)
                            .scaleEffect(0.85)
                            .accessibilityLabel(agent.enabled ? "Disable agent" : "Enable agent")

                        // Heartbeat
                        Button(action: { showHbSheet = agent.id }) {
                            Image(systemName: "bolt.circle")
                                .foregroundColor(Theme.gold.opacity(0.60))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add heartbeat to agent")

                        // Delete
                        Button(action: { vm.deleteAgent(id: agent.id) }) {
                            Image(systemName: "trash")
                                .foregroundColor(Theme.error.opacity(0.70))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete agent")
                    }
                    .listRowBackground(Theme.cardBg)
                }
            }

            Button(action: { showNewAgent = true }) {
                Label("New Agent", systemImage: "plus")
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.gold)
            }
            .listRowBackground(Theme.cardBg)
            .accessibilityLabel("Create new agent")
        } header: {
            sectionHeader("Agents")
        }
    }

    private var dangerZone: some View {
        Section {
            Text("Permanently deletes your account, all notes, highlights, and removes you from all groups and friend lists. This cannot be undone.")
                .font(.lora(Theme.fontSM))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Theme.dangerBg)

            HStack {
                Image(systemName: "person").foregroundColor(Theme.error.opacity(0.60)).frame(width: 22)
                TextField(appState.currentUser?.username ?? "yourname", text: $deleteConfirm)
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .autocapitalization(.none)
                    .accessibilityLabel("Type your username to confirm deletion")
            }
            .listRowBackground(Theme.dangerBg)

            Button(action: {
                if deleteConfirm == (appState.currentUser?.username ?? "") {
                    showDeleteAlert = true
                }
            }) {
                Label("Delete My Account", systemImage: "trash")
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.error)
            }
            .disabled(deleteConfirm != (appState.currentUser?.username ?? ""))
            .listRowBackground(Theme.dangerBg)
            .accessibilityLabel("Delete account button")
        } header: {
            Text("Danger Zone")
                .font(.lora(Theme.fontXXS)).tracking(4)
                .foregroundColor(Theme.error.opacity(0.65))
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.lora(Theme.fontXXS)).tracking(4)
            .foregroundColor(Theme.textGoldMuted)
    }

    private func saveProfile() {
        guard let user = appState.currentUser else { return }
        let updated = FSUser(
            user_id: user.user_id,
            username: username.isEmpty ? user.username : username,
            email: email.isEmpty ? user.email : email
        )
        appState.updateUser(updated)
        vm.editMsg = (.success, "Profile updated.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            vm.editMsg = nil
        }
    }
}

// ── Stat box (mirrors StatBox in Account.jsx) ─────────────────────────────────
struct StatBox: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.playfair(Theme.fontDisplayLG))
                .foregroundColor(Theme.gold)
            Text(label)
                .font(.lora(Theme.fontXXS)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingSM)
        .accessibilityLabel("\(value) \(label)")
    }
}

// ── New agent sheet ───────────────────────────────────────────────────────────
struct NewAgentSheet: View {
    @Binding var role: String
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Optionally give this agent a custom role. Leave blank to use the default spiritual guide role.")
                        .font(.lora(Theme.fontSM))
                        .foregroundColor(Theme.textSecondary)
                    TextEditor(text: $role)
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 80)
                        .accessibilityLabel("Agent role description")
                } header: {
                    Text("Custom Role (optional)")
                        .font(.lora(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") { onCreate(); dismiss() }.foregroundColor(Theme.gold)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

// ── Heartbeat sheet (mirrors heartbeat modal in Account.jsx) ──────────────────
struct HeartbeatSheet: View {
    let agentId: String
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDays = Set<String>()
    @State private var prompt       = ""
    @State private var scheduleTime = Date()

    private let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Schedule a recurring prompt — the agent will check in on these days with the message you define.")
                        .font(.lora(Theme.fontSM))
                        .foregroundColor(Theme.textSecondary)
                }

                Section("Days") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 8) {
                        ForEach(days, id: \.self) { day in
                            let selected = selectedDays.contains(day)
                            Button(action: {
                                if selected { selectedDays.remove(day) } else { selectedDays.insert(day) }
                            }) {
                                Text(String(day.prefix(3)))
                                    .font(.lora(Theme.fontXS))
                                    .foregroundColor(selected ? Theme.ink : Theme.parchment.opacity(0.70))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(selected ? Theme.gold : Theme.gold.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .accessibilityLabel(day)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                .listRowBackground(Theme.cardBg)

                Section("Schedule Time") {
                    DatePicker("Time", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                        .font(.lora(Theme.fontBody))
                        .accessibilityLabel("Heartbeat time")
                }
                .listRowBackground(Theme.cardBg)

                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60)
                        .accessibilityLabel("Heartbeat prompt text")
                }
                .listRowBackground(Theme.cardBg)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .navigationTitle("Add Heartbeat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Schedule") { dismiss() }
                        .foregroundColor(Theme.gold)
                        .disabled(prompt.isEmpty || selectedDays.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ── Helper to make String Identifiable for sheet(item:) ──────────────────────
struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}
