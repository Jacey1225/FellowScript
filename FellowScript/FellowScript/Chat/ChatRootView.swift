// SOURCE: components/MessagingSidebar.jsx (Friends section, Groups section, ChatView),
//         hooks/useMessaging.js, hooks/useAgentChat.js, hooks/useSessions.js,
//         components/SessionCreator.jsx
// KEY STATE: selectedSegment (Friends/Groups/Agents), contacts, groups, agents,
//            activeContact, messages, sessions
// INTERACTIONS: segment switch, tap thread → ChatThreadView, + add friend/group/agent,
//               unread badge on Chat tab
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift
//
// VISUAL: warm-dark-bloom / glass-card redesign matching the Dashboard and Notes
// screens (glassCard() from DashboardComponents.swift, custom header + pill
// toggle pattern from NotesListView.swift). Reference:
// .claude/pipeline/_shared/ChatRedesign.swift. Presentation-only — same
// ChatViewModel, same three segments, same sheets, same swipe actions; no new
// navigation and no new data fetching.

import SwiftUI
import Combine

// ── Root chat view with three segments ────────────────────────────────────────
struct ChatRootView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ChatViewModel()
    @State private var selectedSegment = 0
    @State private var searchQuery     = ""
    @State private var showAddFriend   = false
    @State private var showAddGroup    = false
    @State private var showNewAgent    = false
    @State private var newAgentRole    = ""
    @State private var activeContact:  FSContact? = nil
    @State private var activeAgent:    FSAgent?   = nil
    // Guideline 1.2 report/block
    @State private var reportTarget:      FSContact? = nil
    @State private var blockConfirmTarget: FSContact? = nil

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bgPage.ignoresSafeArea()

            // Warm bloom ground (shared visual language with Dashboard/Notes).
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                scopeToggle
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                ChatSearchField(text: $searchQuery)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                if vm.isLoading {
                    loadingView
                } else {
                    Group {
                        switch selectedSegment {
                        case 0: friendsList
                        case 1: groupsList
                        default: agentsList
                        }
                    }
                }
            }
        }
        .task {
            await vm.load(service: appState.service, userId: appState.currentUser?.user_id ?? "")
        }
        .onChange(of: appState.pendingChatContact) { _, target in
            // Opened from the dashboard community widget — jump to that conversation.
            if let t = target {
                selectedSegment = (t.type == .group) ? 1 : 0
                activeContact = t
                appState.pendingChatContact = nil
            }
        }
        .sheet(item: $activeContact) { contact in
            ChatThreadView(contact: contact, user: appState.currentUser)
        }
        .sheet(item: $activeAgent) { agent in
            AgentChatView(agent: agent)
        }
        .sheet(isPresented: $showAddFriend) {
            AddFriendSheet { username in
                let uid = appState.currentUser?.user_id ?? ""
                Task {
                    try? await appState.service.sendFriendRequest(userId: uid, username: username)
                }
            }
        }
        .sheet(isPresented: $showAddGroup) {
            AddGroupSheet(friends: vm.friends) { title, memberIds in
                let uid = appState.currentUser?.user_id ?? ""
                Task {
                    try? await appState.service.createGroup(
                        userId: uid,
                        groupId: UUID().uuidString,
                        title: title,
                        users: [uid] + memberIds
                    )
                    await vm.load(service: appState.service, userId: uid)
                }
            }
        }
        .sheet(isPresented: $showNewAgent) {
            NewAgentSheet(role: $newAgentRole) {
                let role = newAgentRole
                newAgentRole = ""
                let uid = appState.currentUser?.user_id ?? ""
                Task { await vm.createAgent(role: role, userId: uid) }
            }
        }
    }

    // ── Header: decorative icon · title · new (+) ──────────────────────────────
    // The reference's hamburger has no real destination in this app (unlike
    // Notes, which repurposes its hamburger for its existing filter/sort menu),
    // so it's kept as a non-interactive decorative element rather than a dead
    // tap target — same convention as HeroHeader's avatar circle in
    // DashboardComponents.swift ("decorative — not a control, so no dead button").
    private var header: some View {
        HStack {
            Circle()
                .strokeBorder(Theme.parchment.opacity(0.18), lineWidth: 1)
                .background(Circle().fill(Theme.parchment.opacity(0.08)))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "line.3.horizontal").foregroundColor(Theme.goldLight))
                .accessibilityHidden(true)
            Spacer()
            Text("Chat")
                .font(.system(size: 27, weight: .heavy))
                .foregroundColor(Theme.parchment)
            Spacer()
            Button(action: addAction) {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundColor(Color(hex: "#24170A")))
                    .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 6)
            }
            .accessibilityLabel(selectedSegment == 0 ? "Add friend" : selectedSegment == 1 ? "New group" : "New agent")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // ── Friends / Groups / Agents pill toggle (replaces the native segmented Picker) ──
    private var scopeToggle: some View {
        HStack(spacing: 4) {
            segmentButton(0, "Friends")
            segmentButton(1, "Groups")
            segmentButton(2, "Agents")
        }
        .padding(5)
        .background(
            Capsule().fill(Theme.parchment.opacity(0.07))
                .overlay(Capsule().stroke(Theme.parchment.opacity(0.13), lineWidth: 1))
        )
    }

    private func segmentButton(_ index: Int, _ label: String) -> some View {
        let isActive = selectedSegment == index
        return Button(action: { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { selectedSegment = index } }) {
            Text(label)
                .font(.system(size: 14.5, weight: .heavy))
                .foregroundColor(isActive ? Color(hex: "#24170A") : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    isActive
                        ? LinearGradient(colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // ── Friends list (mirrors MessagingSidebar friends section) ────────────────
    // `searchQuery` filters the already-loaded array client-side — no new
    // network calls or fields (see intake spec Open Questions: Search field).
    private var filteredFriends: [FSContact] {
        guard !searchQuery.isEmpty else { return vm.friends }
        return vm.friends.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
                || $0.preview.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var friendsList: some View {
        Group {
            if vm.friends.isEmpty {
                emptyState(
                    icon:    "person.badge.plus",
                    message: "No friends yet.",
                    hint:    "Tap + to add a friend by username."
                )
            } else if filteredFriends.isEmpty {
                noMatchesState
            } else {
                List(filteredFriends) { contact in
                    ContactRow(contact: contact)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .onTapGesture { activeContact = contact }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                vm.removeFriend(id: contact.id, userId: appState.currentUser?.user_id ?? "")
                            } label: {
                                Label("Remove", systemImage: "person.badge.minus")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { blockConfirmTarget = contact } label: {
                                Label("Block", systemImage: "hand.raised.fill")
                            }
                            .tint(.red)
                            Button { reportTarget = contact } label: {
                                Label("Report", systemImage: "flag.fill")
                            }
                            .tint(.orange)
                        }
                        .accessibilityLabel("Chat with \(contact.name)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8, for: .scrollContent)
                .contentMargins(.bottom, 110, for: .scrollContent)
            }
        }
        .sheet(item: $reportTarget) { contact in
            ReportUserSheet(contact: contact) { reason, detail in
                Task { try? await appState.service.reportUser(reportedUserId: contact.id, reason: reason, detail: detail) }
                reportTarget = nil
            }
        }
        .confirmationDialog(
            "Block \(blockConfirmTarget?.name ?? "this user")?",
            isPresented: Binding(get: { blockConfirmTarget != nil }, set: { if !$0 { blockConfirmTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                guard let contact = blockConfirmTarget else { return }
                let uid = appState.currentUser?.user_id ?? ""
                vm.friends.removeAll { $0.id == contact.id }
                if activeContact?.id == contact.id { activeContact = nil }
                Task { try? await appState.service.blockUser(userId: uid, blockedId: contact.id) }
                blockConfirmTarget = nil
            }
            Button("Cancel", role: .cancel) { blockConfirmTarget = nil }
        } message: {
            Text("They won't be able to contact you or add you as a friend, and their existing content will be removed from your view. We'll be notified so we can review the situation.")
        }
    }

    // ── Groups list ────────────────────────────────────────────────────────────
    private var filteredGroups: [FSContact] {
        guard !searchQuery.isEmpty else { return vm.groups }
        return vm.groups.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
                || $0.preview.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var groupsList: some View {
        Group {
            if vm.groups.isEmpty {
                emptyState(
                    icon:    "person.3",
                    message: "No groups yet.",
                    hint:    "Tap + to create a study group."
                )
            } else if filteredGroups.isEmpty {
                noMatchesState
            } else {
                List(filteredGroups) { contact in
                    ContactRow(contact: contact)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .onTapGesture { activeContact = contact }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                vm.leaveGroup(id: contact.id, userId: appState.currentUser?.user_id ?? "")
                            } label: {
                                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                        .accessibilityLabel("Open group: \(contact.name)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8, for: .scrollContent)
                .contentMargins(.bottom, 110, for: .scrollContent)
            }
        }
    }

    // ── AI agents list ─────────────────────────────────────────────────────────
    private var filteredAgents: [FSAgent] {
        guard !searchQuery.isEmpty else { return vm.agents }
        return vm.agents.filter { $0.displayLabel.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var agentsList: some View {
        Group {
            if vm.agents.isEmpty {
                emptyState(
                    icon:    "brain",
                    message: "No agents yet.",
                    hint:    "Create an agent in Account settings."
                )
            } else if filteredAgents.isEmpty {
                noMatchesState
            } else {
                List(filteredAgents) { agent in
                    AgentRow(agent: agent)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .onTapGesture { activeAgent = agent }
                        .accessibilityLabel("Chat with agent: \(agent.displayLabel)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8, for: .scrollContent)
                .contentMargins(.bottom, 110, for: .scrollContent)
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
        default: showNewAgent = true
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

    private var noMatchesState: some View {
        VStack(spacing: Theme.spacingMD) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Theme.gold.opacity(0.30))
            Text("No matches for \u{201C}\(searchQuery)\u{201D}")
                .font(.lora(Theme.fontBody))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .accessibilityLabel("No matches for \(searchQuery)")
    }
}

// ── ViewModel ─────────────────────────────────────────────────────────────────
@MainActor
final class ChatViewModel: ObservableObject {
    var service: DataServiceProtocol = MockDataService.shared

    @Published var friends:   [FSContact] = []
    @Published var groups:    [FSContact] = []
    @Published var agents:    [FSAgent]   = []
    @Published var isLoading  = true

    func load(service: DataServiceProtocol, userId: String) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }

        // ── Cache-first: show last-known contacts/agents instantly ───────────────
        if let cached: [FSContact] = await DiskCache.shared.load([FSContact].self, forKey: "friends:\(userId)") {
            friends = cached
            isLoading = false
        }
        if let cached: [FSContact] = await DiskCache.shared.load([FSContact].self, forKey: "groupContacts:\(userId)") {
            groups = cached
        }
        if let cached: [FSAgent] = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(userId)") {
            agents = cached
        }

        async let contactsTask = try? service.fetchContacts(userId: userId)
        async let agentsTask   = try? service.fetchAgents(userId: userId)
        let (contacts, _) = (await contactsTask) ?? ([], [:])
        // Sort each list so the conversation with the most recent message is first.
        friends = contacts.filter { $0.type == .friend }.sorted { $0.lastMessageAt > $1.lastMessageAt }
        groups  = contacts.filter { $0.type == .group  }.sorted { $0.lastMessageAt > $1.lastMessageAt }
        agents  = (await agentsTask) ?? []

        // ── Write fresh data back to the cache ───────────────────────────────────
        await DiskCache.shared.save(friends, forKey: "friends:\(userId)")
        await DiskCache.shared.save(groups,  forKey: "groupContacts:\(userId)")
        await DiskCache.shared.save(agents,  forKey: "agents:\(userId)")
    }

    func createAgent(role: String, userId: String) async {
        if let agent = try? await service.createAgent(userId: userId, role: role) {
            agents.append(agent)
        }
    }

    func removeFriend(id: String, userId: String) {
        friends.removeAll { $0.id == id }
        Task { try? await service.removeFriend(userId: userId, friendId: id) }
    }

    func leaveGroup(id: String, userId: String) {
        groups.removeAll { $0.id == id }
        Task { try? await service.leaveGroup(userId: userId, groupId: id) }
    }
}

// ── Relative-time helper (pure; derives only from the existing
//    FSContact.lastMessageAt ISO string — no new field, no fabricated data) ────
private func chatRelativeTime(_ iso: String) -> String {
    guard !iso.isEmpty else { return "" }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return "" }

    let diff = Date().timeIntervalSince(date)
    if diff < 60      { return "now" }
    if diff < 3_600   { return "\(Int(diff / 60))m" }
    if diff < 86_400  { return "\(Int(diff / 3_600))h" }
    if diff < 604_800 { return "\(Int(diff / 86_400))d" }
    return "\(Int(diff / 604_800))w"
}

// ── Search field ────────────────────────────────────────────────────────────
// Wired to filter the already-loaded friends/groups/agents arrays client-side
// (see ChatRootView.filteredFriends/filteredGroups/filteredAgents) — no new
// network calls or data surface (see intake spec Open Questions: Search field).
struct ChatSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.parchment.opacity(0.4))
            TextField("", text: $text, prompt: Text("Search conversations")
                .foregroundColor(Theme.parchment.opacity(0.4)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.parchment)
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Search conversations")
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.parchment.opacity(0.35))
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Capsule().fill(Theme.parchment.opacity(0.06)))
        .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
    }
}

// ── Contact row (mirrors ChatThreadRow in ChatRedesign.swift) ─────────────────
// Online-status dot and unread-count badge are intentionally omitted: FSContact
// carries no isOnline/unreadCount field and no presence/unread-tracking system
// exists yet in this codebase (see intake spec Open Questions) — rendering them
// would fabricate data rather than restyle real data. The relative timestamp
// derives purely from the existing lastMessageAt field via chatRelativeTime(_:).
struct ContactRow: View {
    let contact: FSContact

    var body: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: "#EDAB3C").opacity(0.32), Color(hex: "#B8761D").opacity(0.2)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 48, height: 48)
                .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 1))
                .overlay(
                    Text(String(contact.name.prefix(1)).uppercased())
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(Theme.goldLight)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(contact.name)
                        .font(.system(size: 15.5, weight: .heavy))
                        .foregroundColor(Theme.parchment)
                        .lineLimit(1)
                    if contact.type == .group {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.gold.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    let timeLabel = chatRelativeTime(contact.lastMessageAt)
                    if !timeLabel.isEmpty {
                        Text(timeLabel)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.textMuted)
                    }
                }

                if !contact.preview.isEmpty {
                    Text(contact.preview)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.parchment.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .glassCard(cornerRadius: 20)
    }
}

// ── Agent row ─────────────────────────────────────────────────────────────────
struct AgentRow: View {
    let agent: FSAgent

    var body: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: "#EDAB3C").opacity(0.28), Color(hex: "#B8761D").opacity(0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 48, height: 48)
                .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 1))
                .overlay(Image(systemName: "brain").foregroundColor(Theme.goldLight))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.displayLabel)
                    .font(.system(size: 15.5, weight: .heavy))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                Text(agent.enabled ? "Active" : "Disabled")
                    .font(.system(size: 12))
                    .foregroundColor(agent.enabled ? Theme.success.opacity(0.85) : Theme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .glassCard(cornerRadius: 20)
    }
}

// ── Add friend sheet ──────────────────────────────────────────────────────────
struct AddFriendSheet: View {
    let onSend: (String) -> Void
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
                    Button("Send Request") {
                        onSend(username)
                        dismiss()
                    }
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
    let friends:  [FSContact]
    let onCreate: (String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var groupName   = ""
    @State private var selectedIds = Set<String>()

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
                    Button("Create") {
                        onCreate(groupName, Array(selectedIds))
                        dismiss()
                    }
                    .foregroundColor(Theme.gold)
                    .disabled(groupName.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
