// SOURCE: components/MessagingSidebar.jsx (ChatView), components/SessionCreator.jsx,
//         components/SessionWidget.jsx, hooks/useSessions.js
// KEY STATE: messages, text, showMembers, showSessionCreator, sessions
// INTERACTIONS: send message, toggle member list, + new study session,
//               session banner "View Details", keyboard avoidance
// DEPENDENCY: Theme.swift, Models.swift

import SwiftUI
import Combine

// ── ViewModel (WebSocket + history) ──────────────────────────────────────────

@MainActor
final class ChatThreadViewModel: ObservableObject {
    @Published var messages: [FSMessage] = []
    @Published var sessions: [FSSession] = []
    // Surfaced in the view as a small "Reconnecting…" banner. Previously a
    // dropped socket (network blip, backgrounding, Cloudflare/nginx idle
    // timeout, or the server evicting a stale connection) gave no visible
    // signal at all — see backend step 8 finding #2.
    @Published var isConnected: Bool = true

    private var wsTask: URLSessionWebSocketTask?
    private var wsBase:   String = ""
    private var wsUserId: String = ""
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    // Set by disconnect() (view going away) so a `.failure` from that
    // intentional cancel doesn't trigger a reconnect loop.
    private var isDisconnecting = false

    /// The session/devotion room id. Must match the web client's `roomKey` so
    /// sessions (and their Chime calls) are shared cross-platform:
    ///   • friend DM → the two user ids sorted and joined with "|"
    ///   • group     → the group id
    static func roomKey(contact: FSContact, userId: String) -> String {
        if contact.type == .friend {
            return [userId, contact.id].sorted().joined(separator: "|")
        }
        return contact.id
    }

    func load(service: DataServiceProtocol, contact: FSContact, userId: String) async {
        let sessionKey = Self.roomKey(contact: contact, userId: userId)

        // ── Cache-first: show the last-seen thread instantly ─────────────────────
        if let cached: [FSMessage] = await DiskCache.shared.load([FSMessage].self, forKey: "messages:\(contact.id)") {
            messages = cached
        }
        if let cached: [FSSession] = await DiskCache.shared.load([FSSession].self, forKey: "sessions:\(sessionKey)") {
            sessions = cached
        }

        if contact.type == .group {
            messages = (try? await service.fetchGroupMessages(userId: userId, groupId: contact.id)) ?? messages
        } else {
            messages = (try? await service.fetchFriendMessages(userId: userId, friendId: contact.id)) ?? messages
        }
        sessions = (try? await service.fetchSessionsForContact(contactId: sessionKey)) ?? sessions

        // ── Persist the fresh thread for the next open ───────────────────────────
        await DiskCache.shared.save(messages, forKey: "messages:\(contact.id)")
        await DiskCache.shared.save(sessions, forKey: "sessions:\(sessionKey)")

        connectWebSocket(wsBase: service.wsBase, userId: userId)
    }

    func sendMessage(text: String, contact: FSContact, userId: String) {
        let iso = ISO8601DateFormatter().string(from: Date())
        var body: [String: Any] = ["from_user": userId, "timestamp": iso, "text": text]
        if contact.type == .group {
            body["group_id"] = contact.id
            body["to_users"] = contact.toUsers
        } else {
            body["to_users"] = [contact.id]
            body["group_id"] = ""
        }
        if let data = try? JSONSerialization.data(withJSONObject: body),
           let str  = String(data: data, encoding: .utf8) {
            wsTask?.send(.string(str)) { _ in }
        }
        messages.append(FSMessage(id: UUID().uuidString, text: text, mine: true, sender: "", timestamp: iso))
    }

    func disconnect() {
        isDisconnecting = true
        reconnectTask?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func connectWebSocket(wsBase: String, userId: String) {
        self.wsBase   = wsBase
        self.wsUserId = userId
        guard let url = URL(string: "\(wsBase)/message/ws/\(userId)") else { return }
        wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask?.resume()
        isConnected = true
        reconnectAttempt = 0
        receiveLoop()
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msgText = json["text"] as? String {
                    let incoming = FSMessage(
                        id:        (json["id"] as? String) ?? UUID().uuidString,
                        text:      msgText,
                        mine:      false,
                        sender:    (json["from_user"] as? String) ?? "",
                        timestamp: (json["timestamp"] as? String) ?? ""
                    )
                    Task { @MainActor in self.messages.append(incoming) }
                }
                // Keep listening regardless of whether this particular frame
                // parsed (e.g. a non-text control frame) — previously an
                // unparseable frame silently ended the loop the same way a
                // dropped connection did.
                self.receiveLoop()
            case .failure:
                // The task itself failed (dropped connection, backgrounding,
                // idle-timeout, or the server evicting a stale socket). This
                // used to just return, silently ending message delivery for
                // the rest of the view's lifetime with no visible error state
                // — see backend step 8 finding #2. Reconnect with capped
                // exponential backoff instead of giving up.
                Task { @MainActor in self.scheduleReconnect() }
            }
        }
    }

    private func scheduleReconnect() {
        guard !isDisconnecting else { return }
        isConnected = false
        wsTask = nil
        reconnectAttempt += 1
        let delaySeconds = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0) // 1s, 2s, 4s, …, capped at 30s
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isDisconnecting else { return }
            self.connectWebSocket(wsBase: self.wsBase, userId: self.wsUserId)
        }
    }
}

// ── View ──────────────────────────────────────────────────────────────────────

struct ChatThreadView: View {
    let contact: FSContact
    let user:    FSUser?

    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ChatThreadViewModel()

    @Environment(\.dismiss) private var dismiss
    @State private var text:        String = ""
    @State private var showMembers: Bool   = false
    @State private var showSession: Bool   = false
    @State private var showAddMembers: Bool = false

    // Live member state (seeded from `contact`) so newly added members appear
    // immediately without needing a full reload.
    @State private var memberNames: [String] = []
    @State private var memberIds:   [String] = []
    @State private var friends:     [FSContact] = []   // candidates to add

    // Surfaces createGroup/updateGroup rejections (e.g. the content-filter
    // 422 on a disallowed title) instead of the previous silent no-op — see
    // backend step 8 finding #1.
    @State private var membersErrorMsg: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Member list (group only, mirrors ChatView showMembers block) ──
                    if showMembers && contact.type == .group {
                        GroupMembersPanel(
                            memberNames: memberNames,
                            user:        user,
                            onAddTapped: { showAddMembers = true }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // ── Reconnecting banner (dropped-socket lifecycle state) ───
                    if !vm.isConnected {
                        HStack(spacing: 6) {
                            ProgressView().tint(Theme.gold).scaleEffect(0.75)
                            Text("Reconnecting…")
                                .font(.lora(Theme.fontXS))
                                .foregroundColor(Theme.textGoldMuted)
                        }
                        .padding(.horizontal, Theme.spacingSM)
                        .padding(.top, Theme.spacingXS)
                        .accessibilityLabel("Reconnecting to chat")
                    }

                    // ── Session banner (upcoming session card) ─────────────────
                    if let nextSession = vm.sessions.first {
                        SessionBanner(session: nextSession, onDelete: {
                            let uid = appState.currentUser?.user_id ?? ""
                            let key = ChatThreadViewModel.roomKey(contact: contact, userId: uid)
                            Task {
                                vm.sessions = (try? await appState.service.fetchSessionsForContact(contactId: key)) ?? []
                            }
                        })
                        .padding(.horizontal, Theme.spacingSM)
                        .padding(.top, Theme.spacingXS)
                    }

                    // ── Message list ───────────────────────────────────────────
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Theme.spacingSM) {
                                ForEach(vm.messages) { msg in
                                    MessageBubble(message: msg)
                                        .id(msg.id)
                                        .accessibilityLabel("\(msg.mine ? "You" : msg.sender): \(msg.text)")
                                }
                            }
                            .padding(.horizontal, Theme.spacingMD)
                            .padding(.vertical, Theme.spacingSM)
                        }
                        .onChange(of: vm.messages.count) { _ in
                            if let last = vm.messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // ── Input bar (mirrors ChatView input section) ─────────────
                    HStack(spacing: Theme.spacingSM) {
                        TextField("Type a message…", text: $text, axis: .vertical)
                            .font(.lora(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                            .lineLimit(1...4)
                            .padding(.horizontal, Theme.spacingMD)
                            .padding(.vertical, Theme.spacingSM)
                            .background(Theme.inputBg)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
                            .submitLabel(.send)
                            .onSubmit(sendMessage)
                            .accessibilityLabel("Message input field")

                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(text.isEmpty ? Theme.gold.opacity(0.35) : Theme.gold)
                        }
                        .disabled(text.isEmpty)
                        .accessibilityLabel("Send message")
                    }
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.navBg)
                    .overlay(alignment: .top) { Divider().background(Theme.borderGoldFaint) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Go back")
                }
                ToolbarItem(placement: .principal) {
                    Button(action: {
                        if contact.type == .group {
                            withAnimation { showMembers.toggle() }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text(contact.name)
                                .font(.lora(Theme.fontBody, weight: .semibold))
                                .foregroundColor(Theme.parchment)
                            if contact.type == .group {
                                Image(systemName: "person.3.fill")
                                    .font(.caption2)
                                    .foregroundColor(Theme.gold.opacity(0.55))
                            }
                        }
                    }
                    .accessibilityLabel(contact.type == .group ? "Group: \(contact.name). Tap to see members." : contact.name)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSession = true }) {
                        Image(systemName: "calendar.badge.plus")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Schedule new study session")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            let uid = appState.currentUser?.user_id ?? ""
            memberNames = contact.memberNames
            memberIds   = contact.toUsers
            await vm.load(service: appState.service, contact: contact, userId: uid)
            // Load the viewer's friends so the add-members picker can offer those
            // who aren't already in the group.
            if contact.type == .group {
                let (contacts, _) = (try? await appState.service.fetchContacts(userId: uid)) ?? ([], [:])
                friends = contacts.filter { $0.type == .friend }
            }
        }
        .onDisappear { vm.disconnect() }
        .sheet(isPresented: $showAddMembers) {
            AddGroupMembersSheet(
                candidates: friends.filter { !memberIds.contains($0.id) }
            ) { selected in
                addMembers(selected)
            }
        }
        .sheet(isPresented: $showSession) {
            SessionCreatorSheet(groupId: contact.id, onSave: { session in
                let uid = appState.currentUser?.user_id ?? ""
                // Use the shared room key so this session (and its call) is visible
                // to the other party on the web client too.
                let roomKey = ChatThreadViewModel.roomKey(contact: contact, userId: uid)
                Task {
                    _ = try? await appState.service.createSession(
                        userId: uid, devotion: session, contactId: roomKey
                    )
                    vm.sessions = (try? await appState.service.fetchSessionsForContact(contactId: roomKey)) ?? vm.sessions
                }
                showSession = false
            })
        }
        .alert("Couldn't Add Members", isPresented: Binding(
            get: { membersErrorMsg != nil },
            set: { if !$0 { membersErrorMsg = nil } }
        )) {
            Button("OK", role: .cancel) { membersErrorMsg = nil }
        } message: {
            Text(membersErrorMsg ?? "")
        }
    }

    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let uid = appState.currentUser?.user_id ?? ""
        vm.sendMessage(text: trimmed, contact: contact, userId: uid)
        text = ""
    }

    private func addMembers(_ selected: [FSContact]) {
        guard !selected.isEmpty else { return }
        let uid = appState.currentUser?.user_id ?? ""
        // Snapshot before the optimistic mutation so a failed write can be
        // rolled back instead of leaving the client and server member lists
        // silently out of sync (backend step 8 finding #1).
        let previousIds   = memberIds
        let previousNames = memberNames
        // Optimistically reflect the new members in the panel.
        memberIds.append(contentsOf: selected.map { $0.id })
        memberNames.append(contentsOf: selected.map { $0.name })
        let updatedUsers = memberIds
        Task {
            do {
                try await appState.service.updateGroup(
                    userId: uid, groupId: contact.id, title: contact.name, users: updatedUsers
                )
            } catch {
                // updateGroup now uses checkedRequestRaw, so a rejected write
                // (expired session, or the group_router content-filter 422 on
                // the title) throws instead of silently no-opping. Roll back
                // the optimistic mutation and tell the user why.
                memberIds   = previousIds
                memberNames = previousNames
                membersErrorMsg = (error as? LocalizedError)?.errorDescription ?? "Could not add members."
            }
        }
    }
}

// ── Message bubble (mirrors .msg-bubble sent/received in CSS) ─────────────────
struct MessageBubble: View {
    let message: FSMessage

    var body: some View {
        HStack {
            if message.mine { Spacer(minLength: 60) }

            VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
                if !message.mine && !message.sender.isEmpty {
                    Text(message.sender)
                        .font(.lora(Theme.fontXXS))
                        .foregroundColor(Theme.gold.opacity(0.70))
                }

                Text(message.text)
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(message.mine ? Theme.parchment : Theme.parchment.opacity(0.75))
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(
                        message.mine
                        ? Theme.gold.opacity(0.18)
                        : Color.white.opacity(0.05)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusLG)
                            .stroke(
                                message.mine
                                ? Theme.gold.opacity(0.30)
                                : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )

                Text(message.formattedTime)
                    .font(.lora(Theme.fontXXS))
                    .foregroundColor(Theme.gold.opacity(0.40))
            }

            if !message.mine { Spacer(minLength: 60) }
        }
    }
}

// ── Group members panel (mirrors ChatView showMembers block) ──────────────────
struct GroupMembersPanel: View {
    let memberNames: [String]       // usernames, excluding the current user
    let user:        FSUser?
    var onAddTapped: (() -> Void)?  // present when the viewer may add members

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Members")
                .font(.lora(Theme.fontXXS)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.gold.opacity(0.50))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingSM) {
                    avatarChip(name: user?.username ?? "You", isMe: true)
                    ForEach(Array(memberNames.prefix(20).enumerated()), id: \.offset) { _, name in
                        avatarChip(name: name.isEmpty ? "Member" : name, isMe: false)
                    }
                    if let onAddTapped {
                        addChip(action: onAddTapped)
                    }
                }
            }
        }
        .padding(Theme.spacingMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.islandBg.opacity(0.70))
        .overlay(alignment: .bottom) { Divider().background(Theme.borderGoldFaint) }
    }

    @ViewBuilder
    private func avatarChip(name: String, isMe: Bool) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Theme.gold.opacity(0.12))
                    .frame(width: 26, height: 26)
                Text(String(name.prefix(1)).uppercased())
                    .font(.lora(Theme.fontXXS, weight: .bold))
                    .foregroundColor(Theme.gold)
            }
            Text(isMe ? "\(name) (you)" : name)
                .font(.lora(Theme.fontXS))
                .foregroundColor(isMe ? Theme.gold : Theme.parchment.opacity(0.70))
        }
        .accessibilityLabel(isMe ? "\(name), you" : name)
    }

    // Subtle dashed "+" chip that sits at the end of the member row.
    @ViewBuilder
    private func addChip(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            Theme.gold.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [3])
                        )
                        .frame(width: 26, height: 26)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.gold)
                }
                Text("Add")
                    .font(.lora(Theme.fontXS))
                    .foregroundColor(Theme.gold.opacity(0.75))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add friends to group")
    }
}

// ── Add-members sheet (friend picker for an existing group) ───────────────────
struct AddGroupMembersSheet: View {
    let candidates: [FSContact]        // friends not already in the group
    let onAdd:      ([FSContact]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds = Set<String>()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                if candidates.isEmpty {
                    VStack(spacing: Theme.spacingMD) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 36, weight: .light))
                            .foregroundColor(Theme.gold.opacity(0.35))
                        Text("All your friends are already in this group.")
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.spacingXL)
                    }
                } else {
                    Form {
                        Section("Add friends") {
                            ForEach(candidates) { f in
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
                }
            }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        onAdd(candidates.filter { selectedIds.contains($0.id) })
                        dismiss()
                    }
                    .foregroundColor(Theme.gold)
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ── Session banner (mirrors SessionWidget.jsx) ────────────────────────────────
struct SessionBanner: View {
    let session: FSSession
    var onDelete: (() -> Void)? = nil
    @EnvironmentObject var appState: AppState
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 24))
                .foregroundColor(Theme.gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.lora(Theme.fontSM, weight: .semibold))
                    .foregroundColor(Theme.parchment)
                Text(session.formattedStart)
                    .font(.lora(Theme.fontXS))
                    .foregroundColor(Theme.textGoldMuted)
            }
            Spacer()
            HStack(spacing: 8) {
                // Join call button — starts/joins the persistent call.
                Button {
                    CallController.shared.start(session: session,
                                                service: appState.service,
                                                userId: appState.currentUser?.user_id ?? "")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 11))
                        Text("Join")
                            .font(.lora(Theme.fontXS))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.80))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityLabel("Join call for \(session.title)")

                Button("Details") { showDetail = true }
                    .font(.lora(Theme.fontXS))
                    .foregroundColor(Theme.gold)
                    .padding(.horizontal, Theme.spacingSM)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderGold, lineWidth: 1))
                    .accessibilityLabel("View session details: \(session.title)")
            }
        }
        .padding(Theme.spacingMD)
        .background(Theme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
        .sheet(isPresented: $showDetail) {
            SessionDetailSheet(session: session, onDelete: onDelete)
                .environmentObject(appState)
        }
    }
}

// ── Session detail sheet ──────────────────────────────────────────────────────
struct SessionDetailSheet: View {
    let session: FSSession
    var onDelete: (() -> Void)? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    // Only the user who created the session may delete it.
    private var isHost: Bool {
        !session.creator_id.isEmpty && session.creator_id == appState.currentUser?.user_id
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacingLG) {
                        // Join call CTA — start the persistent call, then close
                        // this sheet so the call takes over full-screen.
                        Button {
                            CallController.shared.start(session: session,
                                                        service: appState.service,
                                                        userId: appState.currentUser?.user_id ?? "")
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 16))
                                Text("Join Audio & Video Call")
                                    .font(.lora(Theme.fontBody, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green.opacity(0.82))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        }
                        .accessibilityLabel("Join audio and video call for \(session.title)")

                        VStack(alignment: .leading, spacing: Theme.spacingXS) {
                            sectionLabel("Study Session")
                            Text(session.title)
                                .font(.playfair(Theme.fontDisplayMD))
                                .foregroundColor(Theme.parchment)
                            Text(session.formattedStart)
                                .font(.lora(Theme.fontSM))
                                .foregroundColor(Theme.textGoldMuted)
                        }

                        if !session.verses.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                                sectionLabel("Verses")
                                ForEach(session.verses, id: \.self) { ref in
                                    Text(ref.replacingOccurrences(of: "-", with: " "))
                                        .font(.verseRef(Theme.fontBody))
                                        .foregroundColor(Theme.gold)
                                }
                            }
                        }

                        if !session.prompts.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                                sectionLabel("Discussion Prompts")
                                ForEach(Array(session.prompts.enumerated()), id: \.offset) { i, p in
                                    HStack(alignment: .top, spacing: Theme.spacingSM) {
                                        Text("\(i+1).")
                                            .font(.lora(Theme.fontSM))
                                            .foregroundColor(Theme.gold)
                                        Text(p)
                                            .font(.lora(Theme.fontSM))
                                            .foregroundColor(Theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        if session.recurring {
                            Label("Repeats weekly", systemImage: "repeat")
                                .font(.lora(Theme.fontSM))
                                .foregroundColor(Theme.textGoldMuted)
                        }

                        // Host-only: delete the session they created.
                        if isHost {
                            Button(role: .destructive) { showDeleteConfirm = true } label: {
                                HStack(spacing: 8) {
                                    if isDeleting {
                                        ProgressView().tint(Theme.error)
                                    } else {
                                        Image(systemName: "trash")
                                        Text("Delete Session")
                                            .font(.lora(Theme.fontBody, weight: .semibold))
                                    }
                                }
                                .foregroundColor(Theme.error)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.error.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                                    .stroke(Theme.error.opacity(0.35), lineWidth: 1))
                            }
                            .disabled(isDeleting)
                            .padding(.top, Theme.spacingSM)
                            .accessibilityLabel("Delete session \(session.title)")
                        }
                    }
                    .padding(Theme.spacingLG)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(Theme.gold)
                }
            }
            .alert("Delete Session?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteSession() }
            } message: {
                Text("This permanently deletes \"\(session.title)\" for everyone. This can't be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.lora(Theme.fontXXS)).tracking(2)
            .foregroundColor(Theme.gold.opacity(0.50))
    }

    private func deleteSession() {
        let uid = appState.currentUser?.user_id ?? ""
        isDeleting = true
        Task {
            try? await appState.service.deleteSession(
                userId: uid, sessionId: session.id, devotion: session
            )
            await MainActor.run {
                isDeleting = false
                onDelete?()   // let the thread refresh its session list
                dismiss()
            }
        }
    }
}

// ── Session creator sheet (mirrors SessionCreator.jsx fields) ─────────────────
struct SessionCreatorSheet: View {
    let groupId: String
    let onSave:  (FSSession) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title        = ""
    @State private var startDate    = Date().addingTimeInterval(3600)
    @State private var duration     = 30
    @State private var prompts:     [String] = []
    @State private var promptInput  = ""
    @State private var recurring    = false
    @State private var summarize    = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Session Title") {
                    TextField("Evening Study", text: $title)
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                        .accessibilityLabel("Session title")
                }

                Section("Timing") {
                    DatePicker("Start Time", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                        .font(.lora(Theme.fontBody))
                        .accessibilityLabel("Session start time")
                    Picker("Duration", selection: $duration) {
                        ForEach(stride(from: 5, through: 180, by: 5).map { $0 }, id: \.self) { m in
                            let h = m / 60; let mins = m % 60
                            Text(h > 0 ? (mins > 0 ? "\(h)h \(mins)m" : "\(h)h") : "\(mins)m").tag(m)
                        }
                    }
                    .accessibilityLabel("Session duration")
                }

                Section("Discussion Prompts") {
                    ForEach(Array(prompts.enumerated()), id: \.offset) { i, p in
                        Text(p)
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.textSecondary)
                            .swipeActions { Button(role: .destructive) { prompts.remove(at: i) } label: { Label("Remove", systemImage: "trash") } }
                    }
                    HStack {
                        TextField("Add a discussion question…", text: $promptInput)
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.parchment)
                            .accessibilityLabel("Discussion prompt input")
                        Button(action: addPrompt) {
                            Image(systemName: "plus.circle")
                                .foregroundColor(promptInput.isEmpty ? Theme.textMuted : Theme.gold)
                        }
                        .disabled(promptInput.isEmpty)
                        .accessibilityLabel("Add prompt")
                    }
                }

                Section {
                    Toggle("Repeat weekly", isOn: $recurring)
                        .tint(Theme.gold)
                        .accessibilityLabel("Repeat this session weekly")
                    Toggle("Summarize with agent", isOn: $summarize)
                        .tint(Theme.gold)
                        .accessibilityLabel("Summarize session with AI agent")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .navigationTitle("Schedule a Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Schedule") {
                        let df = ISO8601DateFormatter()
                        let session = FSSession(
                            id:         UUID().uuidString,
                            title:      title,
                            time_start: df.string(from: startDate),
                            time_end:   df.string(from: startDate.addingTimeInterval(Double(duration * 60))),
                            verses:     [],
                            prompts:    prompts,
                            recurring:  recurring,
                            summarize:  summarize,
                            group_id:   groupId
                        )
                        onSave(session)
                        dismiss()
                    }
                    .foregroundColor(Theme.gold)
                    .disabled(title.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func addPrompt() {
        let trimmed = promptInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        prompts.append(trimmed)
        promptInput = ""
    }
}
