// SOURCE: frontend/src/pages/Account.jsx
// KEY STATE: profileData, agents, events, requests, editLoading, deleteConfirm, agentModal
// INTERACTIONS: edit profile (username/email/password), accept friend requests,
//               create/toggle/delete agents, create/delete events, add notifications, sign out, delete account
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift

import SwiftUI
import Combine
import UserNotifications

@MainActor
final class AccountViewModel: ObservableObject {
    var service: DataServiceProtocol = MockDataService.shared

    @Published var profileData:     FSUser?          = nil
    @Published var agents:          [FSAgent]         = []
    @Published var events:          [FSHeartbeat]     = []
    @Published var friendRequests:  [(id: String, username: String)] = []
    @Published var notifications:   [FSNotification]  = []
    @Published var isLoading       = true
    @Published var editMsg:        (type: AlertType, text: String)? = nil

    enum AlertType { case success, error, warning }

    var friendCount: Int { profileData?.friends.count ?? 0 }
    var groupCount:  Int { profileData?.groups.count  ?? 0 }
    @Published var noteCount:      Int = 0
    @Published var highlightCount: Int = 0

    func load(service: DataServiceProtocol, user: FSUser) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }
        profileData = user
        async let fetchedUser          = service.fetchUser(userId: user.user_id)
        async let fetchedAgents        = service.fetchAgents(userId: user.user_id)
        async let fetchedNotifications = service.fetchNotifications(userId: user.user_id)
        async let fetchedNotes         = service.fetchNotes(userId: user.user_id)
        async let fetchedHighlights    = service.fetchHighlights(userId: user.user_id)
        if let freshUser = try? await fetchedUser { profileData = freshUser }
        agents        = (try? await fetchedAgents)        ?? []
        notifications = (try? await fetchedNotifications) ?? []
        noteCount      = (try? await fetchedNotes)?.count      ?? 0
        highlightCount = (try? await fetchedHighlights)?.count ?? 0

        var allEvents: [FSHeartbeat] = []
        await withTaskGroup(of: [FSHeartbeat].self) { group in
            for agent in agents {
                group.addTask {
                    (try? await service.fetchHeartbeats(userId: user.user_id, agentId: agent.id)) ?? []
                }
            }
            for await hbs in group { allEvents.append(contentsOf: hbs) }
        }
        events = allEvents
    }

    func createEvent(agentId: String, prompt: String, timestamps: [String?]) async {
        guard let uid = profileData?.user_id else { return }
        let hb = FSHeartbeat(id: UUID().uuidString, agent_id: agentId, user_id: uid,
                             timestamps: timestamps, prompt: prompt)
        try? await service.addHeartbeat(userId: uid, agentId: agentId, heartbeat: hb)
        events.append(hb)
        HeartbeatScheduler.scheduleAll(events: events)
    }

    func removeEvent(_ event: FSHeartbeat) {
        guard let uid = profileData?.user_id else { return }
        events.removeAll { $0.id == event.id }
        HeartbeatScheduler.scheduleAll(events: events)
        Task { try? await service.deleteHeartbeat(userId: uid, agentId: event.agent_id, heartbeatId: event.id) }
    }

    func updateEvent(_ event: FSHeartbeat, agentId: String, prompt: String, timestamps: [String?]) async {
        guard let uid = profileData?.user_id else { return }
        let updated = FSHeartbeat(id: event.id, agent_id: agentId, user_id: uid,
                                  timestamps: timestamps, prompt: prompt)
        try? await service.updateHeartbeat(userId: uid, heartbeatId: event.id, heartbeat: updated)
        if let i = events.firstIndex(where: { $0.id == event.id }) {
            events[i] = updated
        }
        HeartbeatScheduler.scheduleAll(events: events)
    }

    func toggleAgent(id: String, enabled: Bool) {
        guard let uid = profileData?.user_id else { return }
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].enabled = enabled
        }
        Task { try? await service.updateAgent(userId: uid, agentId: id, enabled: enabled) }
    }

    func renameAgent(id: String, name: String) {
        guard let uid = profileData?.user_id else { return }
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].name = name
        }
        Task { try? await service.renameAgent(userId: uid, agentId: id, name: name) }
    }

    func deleteAgent(id: String) {
        guard let uid = profileData?.user_id else { return }
        agents.removeAll { $0.id == id }
        events.removeAll { $0.agent_id == id }
        Task { try? await service.deleteAgent(userId: uid, agentId: id) }
    }

    func createAgent(role: String) async {
        guard let uid = profileData?.user_id else { return }
        if let agent = try? await service.createAgent(userId: uid, role: role) {
            agents.append(agent)
        }
    }

    func acceptRequest(username: String) async {
        guard let uid = profileData?.user_id else { return }
        friendRequests.removeAll { $0.username == username }
        try? await service.acceptFriendRequest(userId: uid, username: username)
    }

    func createNotification(name: String, prompt: String, timestamps: [String?]) async {
        guard let uid = profileData?.user_id else { return }
        if let notif = try? await service.createNotification(userId: uid, name: name, prompt: prompt, timestamps: timestamps) {
            notifications.append(notif)
        }
        await NotificationScheduler.scheduleAll(userId: uid, notifications: notifications, service: service)
    }

    func updateNotification(notif: FSNotification, name: String, prompt: String, timestamps: [String?]) async {
        guard let uid = profileData?.user_id else { return }
        try? await service.updateNotification(userId: uid, notifId: notif.id, name: name, prompt: prompt, timestamps: timestamps)
        if let i = notifications.firstIndex(where: { $0.id == notif.id }) {
            notifications[i].name       = name
            notifications[i].prompt     = prompt
            notifications[i].timestamps = timestamps
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notif.id])
        await NotificationScheduler.scheduleAll(userId: uid, notifications: notifications, service: service)
    }

    func deleteNotification(notifId: String) {
        guard let uid = profileData?.user_id else { return }
        notifications.removeAll { $0.id == notifId }
        let remaining = notifications
        Task {
            try? await service.deleteNotification(userId: uid, notifId: notifId)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notifId])
            await NotificationScheduler.scheduleAll(userId: uid, notifications: remaining, service: service)
        }
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
    @State private var newAgentRole   = ""
    @State private var activeSheet:   AccountSheet? = nil
    @State private var renameAgentId: String? = nil
    @State private var renameText     = ""

    enum AccountSheet: Identifiable {
        case newAgent
        case newEvent
        case editEvent(FSHeartbeat)
        case newNotification
        case editNotification(FSNotification)
        var id: String {
            switch self {
            case .newAgent:                 return "newAgent"
            case .newEvent:                 return "newEvent"
            case .editEvent(let e):         return "event-\(e.id)"
            case .newNotification:          return "newNotification"
            case .editNotification(let n):  return "notif-\(n.id)"
            }
        }
    }

    @State private var showNotificationsList = false

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

                    // ── Events ────────────────────────────────────────────────
                    eventsSection

                    // ── Notifications ─────────────────────────────────────────
                    notificationsSection

                    // ── Legal ────────────────────────────────────────────────
                    legalSection

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
            .navigationDestination(isPresented: $showNotificationsList) {
                NotificationsListView(vm: vm)
            }
        }
        .task {
            if let user = appState.currentUser {
                await vm.load(service: appState.service, user: user)
                username = user.username
                email    = user.email
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newAgent:
                NewAgentSheet(role: $newAgentRole) {
                    let role = newAgentRole
                    newAgentRole = ""
                    Task { await vm.createAgent(role: role) }
                }
            case .newEvent:
                EventSetupSheet(agents: vm.agents) { agentId, prompt, timestamps in
                    Task { await vm.createEvent(agentId: agentId, prompt: prompt, timestamps: timestamps) }
                }
            case .editEvent(let event):
                EventSetupSheet(agents: vm.agents, existing: event) { agentId, prompt, timestamps in
                    Task { await vm.updateEvent(event, agentId: agentId, prompt: prompt, timestamps: timestamps) }
                }
            case .newNotification:
                NotificationSetupSheet { name, prompt, timestamps in
                    Task { await vm.createNotification(name: name, prompt: prompt, timestamps: timestamps) }
                }
            case .editNotification(let notif):
                NotificationSetupSheet(existing: notif) { name, prompt, timestamps in
                    Task { await vm.updateNotification(notif: notif, name: name, prompt: prompt, timestamps: timestamps) }
                }
            }
        }
        .alert("Rename Agent", isPresented: Binding(
            get:  { renameAgentId != nil },
            set:  { if !$0 { renameAgentId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameAgentId {
                    vm.renameAgent(id: id, name: renameText.trimmingCharacters(in: .whitespaces))
                }
                renameAgentId = nil
            }
            Button("Cancel", role: .cancel) { renameAgentId = nil }
        } message: {
            Text("Enter a display name for this agent.")
        }
        .alert("Delete Account", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let uid = appState.currentUser?.user_id ?? ""
                Task { try? await appState.service.deleteUser(userId: uid) }
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
                StatBox(value: vm.highlightCount, label: "Verses")
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
                        Button("Accept") {
                            Task { await vm.acceptRequest(username: req.username) }
                        }
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
                            .onChange(of: agent.enabled) { _, newVal in
                                vm.toggleAgent(id: agent.id, enabled: newVal)
                            }

                        // Rename
                        Button(action: {
                            renameText    = agent.name.isEmpty ? agent.displayLabel : agent.name
                            renameAgentId = agent.id
                        }) {
                            Image(systemName: "pencil")
                                .foregroundColor(Theme.gold.opacity(0.60))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename agent")

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

            Button(action: { activeSheet = .newAgent }) {
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

    private var eventsSection: some View {
        Section {
            Text("Events are AI-powered check-ins. When the scheduled time arrives, your agent responds to the prompt and saves a note.")
                .font(.lora(Theme.fontSM))
                .foregroundColor(Theme.textMuted)
                .listRowBackground(Theme.cardBg)

            if vm.events.isEmpty {
                Text("No events yet. Tap + to schedule one.")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.cardBg)
            } else {
                ForEach(vm.events) { event in
                    EventRow(
                        event:     event,
                        agentName: agentName(for: event.agent_id),
                        onEdit:    { activeSheet = .editEvent(event) },
                        onDelete:  { vm.removeEvent(event) }
                    )
                    .listRowBackground(Theme.cardBg)
                }
            }

            Button(action: {
                guard !vm.agents.isEmpty else { return }
                appState.requestPushNotifications()
                activeSheet = .newEvent
            }) {
                Label("New Event", systemImage: "plus")
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(vm.agents.isEmpty ? Theme.textMuted : Theme.gold)
            }
            .disabled(vm.agents.isEmpty)
            .listRowBackground(Theme.cardBg)
            .accessibilityLabel("Create new event")
        } header: {
            sectionHeader("Events")
        }
    }

    private var notificationsSection: some View {
        Section {
            Text("Set up recurring AI-powered reminders for Scripture, prayer, or study.")
                .font(.lora(Theme.fontSM))
                .foregroundColor(Theme.textMuted)
                .listRowBackground(Theme.cardBg)

            if vm.notifications.isEmpty {
                Text("No notifications yet. Tap + to create one.")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.cardBg)
            } else {
                ForEach(vm.notifications.prefix(3)) { notif in
                    HStack(spacing: Theme.spacingMD) {
                        ZStack {
                            Circle().fill(Theme.gold.opacity(0.12)).frame(width: 30, height: 30)
                            Image(systemName: "bell").foregroundColor(Theme.gold).font(.caption)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notif.name.isEmpty ? "Unnamed" : notif.name)
                                .font(.lora(Theme.fontBody))
                                .foregroundColor(Theme.parchment)
                            Text(notif.recurrenceSummary)
                                .font(.lora(Theme.fontXS))
                                .foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                    }
                    .listRowBackground(Theme.cardBg)
                }
            }

            Button(action: {
                appState.requestPushNotifications()
                activeSheet = .newNotification
            }) {
                Label("New Notification", systemImage: "plus")
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.gold)
            }
            .listRowBackground(Theme.cardBg)
            .accessibilityLabel("Create new notification")
        } header: {
            HStack {
                sectionHeader("Notifications")
                Spacer()
                Button(action: { showNotificationsList = true }) {
                    Text("View All")
                        .font(.lora(Theme.fontXXS)).tracking(2)
                        .foregroundColor(Theme.gold.opacity(0.70))
                }
            }
        }
    }

    private var legalSection: some View {
        Section {
            Link(destination: URL(string: "https://fellowscript.com/#/privacy")!) {
                HStack {
                    Label("Privacy Policy", systemImage: "hand.raised")
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .accessibilityLabel("Open Privacy Policy")

            Link(destination: URL(string: "https://fellowscript.com/#/terms")!) {
                HStack {
                    Label("Terms of Service", systemImage: "doc.text")
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .accessibilityLabel("Open Terms of Service")

            HStack {
                Label("Version", systemImage: "info.circle")
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            }
        } header: {
            sectionHeader("Legal")
        }
        .listRowBackground(Theme.cardBg)
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

    private func agentName(for agentId: String) -> String {
        vm.agents.first(where: { $0.id == agentId })?.displayLabel ?? "Agent"
    }

    private func saveProfile() {
        guard let user = appState.currentUser else { return }
        var body: [String: String] = [:]
        if !username.isEmpty && username != user.username { body["username"] = username }
        if !email.isEmpty    && email    != user.email    { body["email"]    = email    }
        if !password.isEmpty                              { body["plain_pass"] = password }
        Task {
            if let updated = try? await appState.service.updateUser(userId: user.user_id, body: body) {
                appState.updateUser(updated)
                vm.profileData = updated
            }
            vm.editMsg = (.success, "Profile updated.")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            vm.editMsg = nil
        }
        password = ""
    }
}

// ── Stat box ──────────────────────────────────────────────────────────────────
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

// ── Event row (shown in Events section) ───────────────────────────────────────
struct EventRow: View {
    let event:     FSHeartbeat
    let agentName: String
    let onEdit:    () -> Void
    let onDelete:  () -> Void

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.12)).frame(width: 30, height: 30)
                Image(systemName: "bolt.fill").foregroundColor(Theme.gold).font(.caption)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.prompt.isEmpty ? "Untitled Event" : String(event.prompt.prefix(50)))
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(event.scheduleSummary)
                    Text("·")
                    Text(agentName)
                }
                .font(.lora(Theme.fontXS))
                .foregroundColor(Theme.textMuted)
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundColor(Theme.gold.opacity(0.60))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit event")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(Theme.error.opacity(0.65))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete event")
        }
    }
}

// ── Helper to make String Identifiable for sheet(item:) ──────────────────────
struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}
