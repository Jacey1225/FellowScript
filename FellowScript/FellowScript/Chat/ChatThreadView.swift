// SOURCE: components/MessagingSidebar.jsx (ChatView), components/SessionCreator.jsx,
//         components/SessionWidget.jsx, hooks/useSessions.js
// KEY STATE: messages, text, showMembers, showSessionCreator, sessions
// INTERACTIONS: send message, toggle member list, + new study session,
//               session banner "View Details", keyboard avoidance
// DEPENDENCY: Theme.swift, Models.swift
//
// VISUAL: warm-dark-bloom restyle matching chat.html/schedule.html (the
// migrated ChatSchedule prototype). Custom in-body header (mirrors
// ChatRootView.swift's own header convention) replaces the native
// NavigationStack toolbar so the back button, identity, and "Schedule" pill
// can share the same visual language as the rest of this screen. Message
// bubbles are grouped Slack-style via MessageGroupRow (Chat/MessageGroupRow.swift).
// Presentation-only — same ChatThreadViewModel, same websocket lifecycle,
// same member/session/report data flows; no new navigation, no new fetches.
// Reference: .claude/pipeline/20260809-chat-schedule-migrate-fellowscript/,
// /Users/jaceysimpson/Vscode/mockups/chat-schedule/chat.html,
// /Users/jaceysimpson/Vscode/mockups/chat-schedule/schedule.html.
//
// NOTE: the mockups' "Active now" presence dot and "X is typing" indicator
// are mock-only (no real presence/typing-status field on FSContact/FSMessage
// exists anywhere in the app) and are intentionally NOT reproduced here —
// same "no fabricated data" precedent already established in ChatRootView.swift's
// ContactRow.
//
// EMBER GLASS (task 20260827-ember-glass-chat-rewrite, design-notes.md):
// §1 elevation — every surface here (Reconnecting pill, SessionBanner,
// SessionCreatorSheet fields) drops its shadow (there wasn't one to begin
// with here) in favor of Theme.topEdgeHighlight, matching PillButton/
// WidgetCard/message bubbles — one elevation language, no mixing. §11/§12 —
// adds the same whole-canvas ambient wash already shared by ChatRootView/
// NotesListView/NoteEditorView (zero new tokens) plus small focal blooms
// behind the header avatar and the SessionBanner calendar badge. §13 — real
// day-boundary detection (ChatThreadRow/DayDividerRow in MessageGroupRow.swift)
// interleaved into the message list.

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

    // ── App-lifecycle wiring (task 20260902-chat-push-notification-failure) ──
    // Previously the socket was only ever closed by onDisappear (the chat
    // *view* leaving the hierarchy), not by the app being backgrounded. A
    // backgrounded-but-still-foreground-view chat (user hits the Home button
    // without navigating away) left active_connections[uid] registered
    // server-side well after the app could no longer surface an incoming
    // frame as a notification, so the server's `ws.send_json` "succeeded"
    // and never fell through to the APNs push branch. The backend heartbeat
    // (step 1) is the real backstop for every disconnection mode including a
    // force-quit or dropped network the client can never self-report, but
    // proactively closing here shrinks the race window for the common
    // graceful-backgrounding case instead of waiting out that timeout.
    //
    // Reuses the same isDisconnecting-guarded disconnect() as onDisappear —
    // an intentional close either way, so the existing `.failure` handling
    // in receiveLoop() correctly treats this as "not a real drop" and never
    // schedules a reconnect on its own.
    func handleAppBackgrounded() {
        guard !isDisconnecting else { return }
        disconnect()
    }

    // Mirrors load()'s initial connectWebSocket call, but only resumes a
    // connection this view model itself closed via handleAppBackgrounded()
    // — if the view never finished its initial load (wsBase still empty) or
    // disconnect() was called for view teardown instead, there's nothing to
    // resume here.
    func handleAppForegrounded() {
        guard isDisconnecting, !wsBase.isEmpty else { return }
        isDisconnecting = false
        reconnectAttempt = 0
        connectWebSocket(wsBase: wsBase, userId: wsUserId)
    }

    private func connectWebSocket(wsBase: String, userId: String) {
        self.wsBase   = wsBase
        self.wsUserId = userId
        guard let url = URL(string: "\(wsBase)/message/ws/\(userId)") else { return }
        wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask?.resume()
        isConnected = true
        // Do NOT reset reconnectAttempt here — this is called both for the
        // initial connect (where reconnectAttempt is already 0) and for
        // every retry scheduleReconnect() makes. Resetting it here made the
        // exponential backoff never actually grow past its first ~1s delay,
        // since scheduleReconnect() calls straight back into this function.
        // reconnectAttempt is reset instead in receiveLoop()'s `.success`
        // case, once a frame actually arrives and the connection is
        // confirmed genuinely live.
        receiveLoop()
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                // A frame arrived, so this connection is confirmed live —
                // this is the "genuinely fresh/successful connection" point,
                // not merely a call to connectWebSocket(). Reset backoff here.
                self.reconnectAttempt = 0
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msgText = json["text"] as? String {
                    let fromUser = (json["from_user"] as? String) ?? ""
                    // Self-echo guard (group-chat duplication fix, task
                    // 20260902-group-chat-message-duplication): a group send
                    // is fanned out to every member in `to_users`, which the
                    // client populates as the full member list *including
                    // the sender* (sendMessage() above / contact.toUsers).
                    // Backend step 1 stops re-delivering that live frame
                    // back to from_user_id at the source, but this check
                    // stays as defense-in-depth on the client, matching this
                    // method's existing standard of not leaning on a single
                    // fragile assumption (see the reconnect/backoff comments
                    // above). Without it, the sender's own message would
                    // render twice: once from the optimistic local echo in
                    // sendMessage() (labeled "You"), and again here as an
                    // ordinary inbound message — with a raw user-id sender
                    // label, since this path has no "is this me" lookup.
                    // This is an explicit, visible skip (logged, not a bare
                    // silent drop) of a known, expected case — distinct from
                    // the unparseable-frame case below, which is a genuine
                    // "couldn't understand this frame" gap.
                    if !fromUser.isEmpty, fromUser == self.wsUserId {
                        print("[ChatThreadViewModel] dropping self-echoed inbound frame from_user=\(fromUser) — already shown via optimistic local append")
                    } else {
                        let incoming = FSMessage(
                            id:        (json["id"] as? String) ?? UUID().uuidString,
                            text:      msgText,
                            mine:      false,
                            sender:    fromUser,
                            timestamp: (json["timestamp"] as? String) ?? ""
                        )
                        Task { @MainActor in self.messages.append(incoming) }
                    }
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
    // Drives handleAppBackgrounded()/handleAppForegrounded() below — only
    // .background is treated as "actually gone," not the transient .inactive
    // state SwiftUI also reports for things like a Control Center swipe, an
    // incoming-call/permission overlay, or the app-switcher gesture. Reacting
    // to .inactive too would disconnect (and then have to reconnect) during
    // ordinary foreground interactions that never left the app, which is the
    // opposite of what this task is trying to fix.
    @Environment(\.scenePhase) private var scenePhase
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

    private var messageGroups: [MessageDisplayGroup] {
        MessageDisplayGroup.grouped(from: vm.messages, me: user)
    }

    // Interleaves labeled day-divider rows between MessageDisplayGroups
    // (design gate §13) — real Calendar.isDate(inSameDayAs:) detection, not
    // a cosmetic restyle of the existing plain sender-group hairline.
    private var threadRows: [ChatThreadRow] {
        messageGroups.withDayDividers()
    }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            // Warm bloom ground (shared visual language with ChatRootView/
            // Notes) — Added item 2: whole-canvas ambient wash, identical
            // values to ChatRootView.swift/NotesListView.swift/NoteEditorView.swift.
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

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
                // Same vm.isConnected-driven logic as before — restyled into
                // a pill using the Ember Glass elevation language (§1) rather
                // than bare floating text+spinner.
                if !vm.isConnected {
                    HStack(spacing: 6) {
                        ProgressView().tint(Theme.gold).scaleEffect(0.75)
                        Text("Reconnecting…")
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.textGoldMuted)
                    }
                    .padding(.horizontal, Theme.spacingSM)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.045))
                    .overlay(Capsule().stroke(Theme.borderGoldFaint, lineWidth: 1))
                    .clipShape(Capsule())
                    .topEdgeHighlight(Capsule())
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

                // ── Message list (Slack-style grouped bubbles + day dividers) ──
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let rows = threadRows
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                switch row {
                                case .group(let group):
                                    MessageGroupRow(group: group)
                                        .id(row.id)
                                case .dayDivider(_, let label):
                                    DayDividerRow(label: label)
                                        .id(row.id)
                                }
                                // Decision 2 (design step 1, fidelity pass):
                                // no rendered line between two consecutive
                                // same-day groups — only a spacing gap. This
                                // reverses the original Ember Glass design
                                // gate's §13 call to keep a plain unlabeled
                                // hairline here, which didn't actually match
                                // render-2-conversation-thread.png (no line
                                // between non-day-boundary groups at all).
                                // Day-divider hairlines (DayDividerRow) are
                                // untouched — that specific line-flanking-a-
                                // label motif still belongs at day boundaries
                                // only.
                                if index < rows.count - 1,
                                   case .group = row,
                                   case .group = rows[index + 1] {
                                    Color.clear.frame(height: Theme.spacingSM)
                                }
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, Theme.spacingSM)
                    }
                    .onChange(of: vm.messages.count) { _ in
                        if let lastGroup = messageGroups.last {
                            withAnimation { proxy.scrollTo(lastGroup.id, anchor: .bottom) }
                        }
                    }
                }
            }
            // Shared keyboard-dismiss convention (task
            // 20260831-interaction-polish-conventions) — covers header/
            // banners/message list. No pull-to-refresh here: this is a live
            // WebSocket thread (new messages arrive over the socket, not via
            // a batch reload), and there's no existing older-message
            // pagination for an overscroll-at-top gesture to trigger —
            // adding one would be new data-fetch/pagination logic, out of
            // this task's bounds. No tap-outside-dismiss either:
            // GroupMembersPanel above renders inline in the VStack flow
            // (pushing the message list down), not as a floating ZStack
            // overlay layered over other content, so it isn't the kind of
            // custom overlay this task's tap-outside-dismiss convention
            // targets.
            //
            // Applied HERE — to this VStack, before `.safeAreaInset` adds
            // the composer below — rather than to the outer ZStack as
            // before (task 20260903-message-composer-keyboard-dismiss).
            // `.safeAreaInset`'s content is laid out as a sibling to the
            // view it's chained onto, not a descendant of it, so a
            // `.simultaneousGesture` attached before `.safeAreaInset` never
            // receives touches that land inside the composer — fixing the
            // reported bug where tapping inside the composer's TextField to
            // reposition the cursor mid-text (rather than tapping outside
            // it) immediately dismissed the keyboard instead of just moving
            // the cursor. Tapping the message list / header / banners still
            // dismisses exactly as before; scroll-to-dismiss on the message
            // list (`.scrollDismissesKeyboard(.interactively)`, part of this
            // same shared modifier) is unaffected by the reordering since it
            // targets the ScrollView, which stays inside this VStack either
            // way. See AgentChatView.swift for the identical fix applied to
            // the same latent pattern there.
            .dismissesKeyboardOnScrollAndTap()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
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
        // App-lifecycle wiring (task 20260902-chat-push-notification-failure)
        // — complements onDisappear above, which only fires when this view
        // itself leaves the hierarchy, not when the whole app is backgrounded
        // while the chat thread is still the visible screen.
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                vm.handleAppBackgrounded()
            } else if phase == .active {
                vm.handleAppForegrounded()
            }
        }
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

    // ── Header: back · avatar/name (tap to toggle members) · "Schedule" pill ──
    // Custom in-body header (mirrors ChatRootView.swift's own header
    // convention) instead of the native NavigationStack toolbar, so this
    // screen can share the exact same visual language (round icon button,
    // serif identity label, amber-gradient pill) as the rest of the restyled
    // Chat surfaces.
    private var header: some View {
        HStack(spacing: 14) {
            RoundIconButton(systemIcon: "chevron.left") { dismiss() }
                .accessibilityLabel("Go back")

            Button(action: {
                if contact.type == .group {
                    withAnimation { showMembers.toggle() }
                }
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.gold.opacity(0.18))
                        Circle().stroke(Theme.borderGoldDim, lineWidth: 1)
                        Text(String(contact.name.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Theme.gold)
                    }
                    .frame(width: 38, height: 38)

                    HStack(spacing: 5) {
                        Text(contact.name)
                            .font(.inter(Theme.fontHeading, weight: .bold))
                            .foregroundColor(Theme.parchment)
                            .lineLimit(1)
                        if contact.type == .group {
                            Image(systemName: "person.3.fill")
                                .font(.caption2)
                                .foregroundColor(Theme.gold.opacity(0.55))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(contact.type == .group ? "Group: \(contact.name). Tap to see members." : contact.name)

            Spacer(minLength: 8)

            PillButton(title: "Schedule", systemIcon: "calendar") {
                showSession = true
            }
            .accessibilityLabel("Schedule new study session")
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingSM)
        .padding(.bottom, Theme.spacingSM)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)
        }
    }

    // ── Composer (mirrors chat.html's flush full-width `.input-bar`) ──────────
    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $text,
                      prompt: Text("Type a message…").foregroundColor(Theme.textSecondary), axis: .vertical)
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.parchment)
                .lineLimit(1...4)
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, Theme.spacingSM)
                .background(Color.white.opacity(0.05))
                .overlay(Capsule().stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(Capsule())
                .submitLabel(.send)
                .onSubmit(sendMessage)
                .accessibilityLabel("Message input field")

            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.ink)
                    .frame(width: 38, height: 38)
                    .background(text.isEmpty ? AnyShapeStyle(Theme.gold.opacity(0.35)) : AnyShapeStyle(Theme.goldGradient))
                    .clipShape(Circle())
            }
            .disabled(text.isEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingSM)
        .padding(.bottom, Theme.spacingMD)
        .background(Theme.bgPage.opacity(0.55))
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

// ── Group members panel (mirrors ChatView showMembers block) ──────────────────
struct GroupMembersPanel: View {
    let memberNames: [String]       // usernames, excluding the current user
    let user:        FSUser?
    var onAddTapped: (() -> Void)?  // present when the viewer may add members

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Members")
                .font(.inter(Theme.fontXXS)).tracking(3).textCase(.uppercase)
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
                    .font(.inter(Theme.fontXXS, weight: .bold))
                    .foregroundColor(Theme.gold)
            }
            Text(isMe ? "\(name) (you)" : name)
                .font(.inter(Theme.fontXS))
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
                    .font(.inter(Theme.fontXS))
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
                            .font(.inter(Theme.fontSM))
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
                                        .font(.inter(Theme.fontBody))
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
        // Decision 1 (design step 1, fidelity pass): split into an outer
        // VStack — row 1 keeps the icon/title/time, row 2 is a new
        // full-width Join+Details row below it — instead of one shared
        // HStack. The original single-HStack skeleton starved the button
        // row for width, causing "Join"'s label to text-wrap ("Jo"/"in")
        // at realistic session-title lengths ("Wednesday Night Study"),
        // and didn't match render-3-session-summary.png's two-row layout,
        // which the original Ember Glass design gate never actually
        // decided (it only addressed elevation §1 and the icon bloom §11).
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack(spacing: Theme.spacingMD) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.16))
                    Circle().stroke(Theme.borderGoldDim, lineWidth: 1)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.gold)
                }
                .frame(width: 40, height: 40)
                // Added item 1: focal ambient bloom behind the calendar badge
                // (design gate §11, visible in render-3-session-summary.png as a
                // warm halo around the icon). Background sizing keeps the halo
                // from being clipped to the badge's own 40x40 frame.
                .background(
                    RadialGradient(colors: [Theme.gold.opacity(0.35), .clear],
                                   center: .center, startRadius: 2, endRadius: 40)
                        .frame(width: 100, height: 100)
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.inter(Theme.fontSM, weight: .bold))
                        .foregroundColor(Theme.parchment)
                    Text(session.formattedStart)
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
            }

            // Row 2 (design decision 1): a distinct, full-width Join+Details
            // row below the title/time — not indented under the text — each
            // button given .frame(maxWidth: .infinity) so together they span
            // most of the card's content width, matching render-3. This also
            // structurally resolves the Join-label wrap: with the row no
            // longer sharing space with the title, "Join" has no plausible
            // remaining wrap scenario at realistic title lengths (verified
            // directly — see EmberGlassChatRegressionTests).
            HStack(spacing: Theme.spacingSM) {
                // Join call button — starts/joins the persistent call. Kept
                // green (established call-affordance convention elsewhere in
                // the app) — only the shape/typography is restyled, per the
                // migration's "styling only, not the call screen" scope.
                Button {
                    CallController.shared.start(session: session,
                                                service: appState.service,
                                                userId: appState.currentUser?.user_id ?? "")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 11))
                        Text("Join")
                            .font(.system(size: 12, weight: .bold))
                            .fixedSize()
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.success.opacity(0.82))
                    .clipShape(Capsule())
                }
                .accessibilityLabel("Join call for \(session.title)")

                Button {
                    showDetail = true
                } label: {
                    Text("Details")
                        .fixedSize()
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.gold)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Theme.spacingSM)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
                }
                .accessibilityLabel("View session details: \(session.title)")
            }
        }
        .padding(Theme.spacingMD)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
        .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
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
                                    .font(.inter(Theme.fontBody, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.success.opacity(0.82))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
                        }
                        .accessibilityLabel("Join audio and video call for \(session.title)")

                        VStack(alignment: .leading, spacing: Theme.spacingXS) {
                            SectionEyebrow(title: "Study Session")
                            Text(session.title)
                                .font(.playfair(Theme.fontDisplayMD))
                                .foregroundColor(Theme.parchment)
                            Text(session.formattedStart)
                                .font(.inter(Theme.fontSM))
                                .foregroundColor(Theme.textGoldMuted)
                        }

                        if !session.verses.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                                SectionEyebrow(title: "Verses")
                                ForEach(session.verses, id: \.self) { ref in
                                    Text(ref.replacingOccurrences(of: "-", with: " "))
                                        .font(.verseRef(Theme.fontBody))
                                        .foregroundColor(Theme.gold)
                                }
                            }
                        }

                        if !session.prompts.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                                SectionEyebrow(title: "Discussion Prompts")
                                ForEach(Array(session.prompts.enumerated()), id: \.offset) { i, p in
                                    HStack(alignment: .top, spacing: Theme.spacingSM) {
                                        Text("\(i+1).")
                                            .font(.inter(Theme.fontSM))
                                            .foregroundColor(Theme.gold)
                                        Text(p)
                                            .font(.inter(Theme.fontSM))
                                            .foregroundColor(Theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        if session.recurring {
                            Label("Repeats weekly", systemImage: "repeat")
                                .font(.inter(Theme.fontSM))
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
                                            .font(.inter(Theme.fontBody, weight: .semibold))
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

// ── Session creator sheet (mirrors SessionCreator.jsx fields / schedule.html) ─
// Bottom-sheet presentation restyle: drag handle, Cancel/title/"Schedule"
// pill header row, segmented 15/30/45/60m duration control, chip-style
// option toggles. `duration` is UI-only — FSSession has no duration field —
// time_end is computed from time_start + duration.rawValue minutes when
// building the FSSession to hand to onSave (unchanged create path: the
// caller in ChatThreadView still drives NetworkService.createSession).
struct SessionCreatorSheet: View {
    let groupId: String
    let onSave:  (FSSession) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title:       String = ""
    @State private var startDate:   Date   = Date().addingTimeInterval(3600)
    @State private var duration:    SessionDuration = .thirty
    @State private var prompts:     [String] = []
    @State private var promptInput: String = ""
    @State private var recurring:   Bool = false
    @State private var summarize:   Bool = false

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            VStack(spacing: 0) {
                dragHandle
                sheetHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        sessionTitleSection
                        startTimeSection
                        durationSection
                        discussionPromptsSection
                        sessionOptionsSection
                    }
                    .padding(.top, 4)
                    .padding(.bottom, Theme.spacingLG)
                }
            }
            .padding(.horizontal, Theme.spacingLG)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(Theme.radiusXXL)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.2))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .accessibilityHidden(true)
    }

    private var sheetHeader: some View {
        HStack {
            RoundIconButton(systemIcon: "xmark", diameter: 36) { dismiss() }
                .accessibilityLabel("Cancel")

            Spacer()

            Text("Schedule")
                .font(.inter(Theme.fontDisplayMD, weight: .bold))
                .foregroundColor(Theme.parchment)

            Spacer()

            // Small circular CTA (mirrors the composer's send-button
            // treatment) rather than plain RoundIconButton styling, so this
            // sheet's primary action keeps its solid-gold weight after
            // losing its "Schedule" pill label.
            Button(action: scheduleSession) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background(Theme.goldGradient)
                    .clipShape(Circle())
                    .topEdgeHighlight(Circle())
            }
            .buttonStyle(.plain)
            .disabled(title.isEmpty)
            .opacity(title.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Schedule session")
        }
        .padding(.bottom, 22)
    }

    // MARK: - Sections

    private var sessionTitleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Session Title")
            TextField("", text: $title, prompt: Text("Evening Study").foregroundColor(Theme.textSecondary))
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.parchment)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
                .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
                .accessibilityLabel("Session title")
        }
    }

    private var startTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Start Time")
            HStack(spacing: 10) {
                DateTimeTile(systemIcon: "calendar", label: "Session start date",
                             date: $startDate, displayedComponents: .date)
                DateTimeTile(systemIcon: "clock", label: "Session start time",
                             date: $startDate, displayedComponents: .hourAndMinute)
            }
        }
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Duration")
            SegmentedDurationControl(selection: $duration)
        }
    }

    private var discussionPromptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Discussion Prompts")

            ForEach(Array(prompts.enumerated()), id: \.offset) { i, p in
                HStack {
                    Text(p)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.parchment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { prompts.remove(at: i) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.textMuted)
                    }
                    .accessibilityLabel("Remove prompt: \(p)")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
                .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
            }

            HStack {
                TextField("", text: $promptInput,
                          prompt: Text("Add a discussion question…").foregroundColor(Theme.textSecondary))
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .accessibilityLabel("Discussion prompt input")

                Button(action: addPrompt) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.ink)
                        .frame(width: 32, height: 32)
                        .background(promptInput.isEmpty ? AnyShapeStyle(Theme.gold.opacity(0.35)) : AnyShapeStyle(Theme.goldGradient))
                        .clipShape(Circle())
                }
                .disabled(promptInput.isEmpty)
                .accessibilityLabel("Add prompt")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
            .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
        }
    }

    private var sessionOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Session Options")
            HStack(spacing: 10) {
                ChipToggle(title: "Repeat weekly", isOn: $recurring)
                ChipToggle(title: "Summarize", isOn: $summarize)
            }
        }
    }

    private func addPrompt() {
        let trimmed = promptInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        prompts.append(trimmed)
        promptInput = ""
    }

    private func scheduleSession() {
        let df = ISO8601DateFormatter()
        let session = FSSession(
            id:         UUID().uuidString,
            title:      title,
            time_start: df.string(from: startDate),
            // FSSession has no duration field — time_end is derived
            // client-side from the segmented control's selection, matching
            // the prior Picker-based flow's behavior. See
            // SessionDuration.timeEndISOString(from:) for the (now
            // independently unit-tested) formula.
            time_end:   duration.timeEndISOString(from: startDate),
            verses:     [],
            prompts:    prompts,
            recurring:  recurring,
            summarize:  summarize,
            group_id:   groupId
        )
        onSave(session)
        dismiss()
    }
}
