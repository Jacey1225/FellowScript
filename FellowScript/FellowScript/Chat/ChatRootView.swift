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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var vm: ChatViewModel

    // Required (no default): a bare `ChatViewModel()` default expression is
    // evaluated as MainActor-isolated under this project's default actor
    // isolation, but this init itself must stay usable from a nonisolated
    // context, so it can't carry that default safely. ContentView.mainTabView
    // is the only call site and always passes StartupCoordinator's shared
    // instance so this screen's `.task` sees already-loaded (or in-flight)
    // data instead of firing a second fetch (see ChatViewModel.hasLoadedOnce).
    init(vm: ChatViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

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
    // Surfaced on a failed report/block instead of the previous silent
    // `try?` no-op (compile-errors #2).
    @State private var reportError: String? = nil
    @State private var blockError:  String? = nil
    // Task 20260916-group-leave-deletes-group: "Delete Group" is a distinct,
    // owner-gated, whole-group-destroying action -- unlike "Leave" (a direct
    // swipe button with no extra friction, since it only ever affects the
    // caller themselves), this gets the same confirmationDialog pattern as
    // Block above, since it's destructive for every other member too.
    @State private var deleteGroupConfirmTarget: FSContact? = nil

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
        // Shared keyboard-dismiss convention (task
        // 20260831-interaction-polish-conventions) — covers this screen's
        // search field.
        .dismissesKeyboardOnScrollAndTap()
        .task {
            await vm.load(service: appState.service, userId: appState.currentUser?.user_id ?? "")
            recomputeUnread()
        }
        // Task 20260913-chat-unread-badges: whenever the friend/group list
        // itself changes (initial load, pull-to-refresh, a new group just
        // created, ...) or a thread elsewhere got marked read
        // (appState.lastReadVersion), recompute the tab-bar aggregate from
        // the current real data -- never incremented/decremented by hand.
        .onChange(of: vm.friends) { _ in recomputeUnread() }
        .onChange(of: vm.groups) { _ in recomputeUnread() }
        .onChange(of: appState.lastReadVersion) { _ in recomputeUnread() }
        .onChange(of: appState.pendingChatContact) { _, target in
            // Opened from the dashboard community widget, or from a tap on a
            // session-created/session-reminder push (AppState.openSession) —
            // jump to that conversation.
            if let t = target {
                selectedSegment = (t.type == .group) ? 1 : 0
                // AppState.openSession only knows the target's raw id/type
                // (a push payload carries no name/member list) — prefer the
                // matching already-loaded contact from vm.friends/vm.groups
                // when one exists, so a group opened this way still has its
                // real `toUsers` for message routing (see
                // ChatThreadViewModel.sendMessage) instead of an empty list.
                let resolved = (t.type == .group ? vm.groups : vm.friends).first { $0.id == t.id }
                activeContact = resolved ?? t
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
                    do {
                        try await appState.service.createGroup(
                            userId: uid,
                            groupId: UUID().uuidString,
                            title: title,
                            users: [uid] + memberIds
                        )
                        await vm.load(service: appState.service, userId: uid)
                    } catch {
                        // createGroup now uses checkedRequestRaw, so a rejected
                        // create (e.g. the group_router content-filter 422 on a
                        // disallowed title) throws instead of silently no-opping,
                        // which previously left the user staring at an unchanged
                        // groups list with no explanation (backend step 8 finding #1).
                        vm.groupError = (error as? LocalizedError)?.errorDescription ?? "Could not create group."
                    }
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
        .alert("Couldn't Create Group", isPresented: Binding(
            get: { vm.groupError != nil },
            set: { if !$0 { vm.groupError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.groupError = nil }
        } message: {
            Text(vm.groupError ?? "")
        }
        .alert("Couldn't Create Agent", isPresented: Binding(
            get: { vm.agentError != nil },
            set: { if !$0 { vm.agentError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.agentError = nil }
        } message: {
            Text(vm.agentError ?? "")
        }
        .alert("Couldn't Send Report", isPresented: Binding(
            get: { reportError != nil },
            set: { if !$0 { reportError = nil } }
        )) {
            Button("OK", role: .cancel) { reportError = nil }
        } message: {
            Text(reportError ?? "")
        }
        .alert("Couldn't Block User", isPresented: Binding(
            get: { blockError != nil },
            set: { if !$0 { blockError = nil } }
        )) {
            Button("OK", role: .cancel) { blockError = nil }
        } message: {
            Text(blockError ?? "")
        }
        .alert("Couldn't Remove Friend", isPresented: Binding(
            get: { vm.friendActionError != nil },
            set: { if !$0 { vm.friendActionError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.friendActionError = nil }
        } message: {
            Text(vm.friendActionError ?? "")
        }
        .alert("Couldn't Leave Group", isPresented: Binding(
            get: { vm.groupActionError != nil },
            set: { if !$0 { vm.groupActionError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.groupActionError = nil }
        } message: {
            Text(vm.groupActionError ?? "")
        }
    }

    // ── Header: title · new (+) ─────────────────────────────────────────────
    // Task 20260921-remove-dead-chat-hamburger: this used to lead with a
    // decorative `line.3.horizontal` circle — the reference's hamburger has
    // no real destination in this app (unlike Notes, which repurposes its
    // hamburger for its existing filter/sort menu) — kept non-interactive
    // rather than a dead tap target. It still read as a dead/non-functional
    // button, so it was removed outright rather than kept as inert decoration.
    // Task 20260921-center-chat-title: the title is now visually centered in
    // the row, not merely leading-aligned. A naive single-Spacer swap (Text
    // then Spacer then button) only centers the title between the two screen
    // edges — the fixed-width 44x44 "+" button on the trailing edge, with
    // nothing balancing it on the leading edge, would still pull the title's
    // optical center to the left. Instead this mirrors the fixed-width
    // trailing button with an identically-sized invisible leading placeholder,
    // then centers the title between two Spacers flanking it symmetrically —
    // the same "equal-width flanking elements + symmetric Spacers" centering
    // technique already used by SessionCreatorSheet.sheetHeader in
    // ChatThreadView.swift. This intentionally departs from HeroHeader's
    // leading-title convention in DashboardComponents.swift — see the intake
    // spec's Scope section for why the two headers are no longer required to
    // stay in sync.
    private var header: some View {
        HStack {
            Circle()
                .fill(Color.clear)
                .frame(width: 44, height: 44)
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
        return Button(action: { withMotionAwareAnimation(.spring(response: 0.28, dampingFraction: 0.85), reduceMotion: reduceMotion) { selectedSegment = index } }) {
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
                        // Task 20260913-chat-unread-badges: folded into this
                        // row's existing label rather than a separate
                        // accessible element for the dot glyph itself.
                        .accessibilityLabel(
                            appState.hasUnread(contact)
                                ? "Chat with \(contact.name), unread messages"
                                : "Chat with \(contact.name)"
                        )
                }
                .listStyle(.plain)
                // Pull-to-refresh (task 20260831-interaction-polish-conventions)
                // — see ChatViewModel.refresh's comment. Friends/groups/agents
                // share the same fetch, so each of this file's three lists
                // wires the identical call.
                .refreshable {
                    await vm.refresh(service: appState.service, userId: appState.currentUser?.user_id ?? "")
                }
                .scrollContentBackground(.hidden)
                // Breathing room + top-edge feather (task
                // 20260831-notes-messages-list-scroll-blur): the search field
                // sits directly above this List with no gap, so rows
                // scrolling up used to hit a hard clip flush against it -- a
                // live scrolled-state screenshot of the equivalent Notes list
                // showed a card visibly colliding with/reading as
                // overlapping the row above, not just "unblurred."
                // `.contentMargins(.top:)` alone only offsets the AT-REST
                // position (scrollOffset 0); it does not create a persistent
                // gap once scrolled, since content still travels all the way
                // to the List's own top-edge frame boundary while scrolling.
                // The real fix needs both halves: the `.padding(.top:)`
                // below (OUTSIDE the List, after the mask) moves the List's
                // own clipping frame a genuine, scroll-independent
                // Theme.spacingLG away from the search field, so even a
                // fully-scrolled row's top edge stays clear of it -- no
                // overlap, ever, regardless of scroll offset.
                // `.contentMargins(.top:)` keeps a smaller matching inset so
                // the first row also isn't flush against the List's own
                // (now further-away) top edge at rest. scrollTopEdgeFeather
                // (Theme.swift) adapts NoteDetailView's ScrollView `.mask`
                // precedent for List so rows fade out smoothly as they
                // approach that inner top edge while scrolling, instead of
                // hard-clipping there. Neither of these is a background
                // overlay/panel -- both operate on the List's own frame/
                // alpha, nothing new is drawn behind or in front of it.
                .contentMargins(.top, Theme.spacingSM, for: .scrollContent)
                .contentMargins(.bottom, 110, for: .scrollContent)
                .scrollTopEdgeFeather()
                .padding(.top, Theme.spacingLG)
            }
        }
        .sheet(item: $reportTarget) { contact in
            ReportUserSheet(contact: contact) { reason, detail in
                Task {
                    do {
                        try await appState.service.reportUser(reportedUserId: contact.id, reason: reason, detail: detail)
                    } catch {
                        // A failed report previously gave the user no
                        // indication their abuse report never reached
                        // moderation (compile-errors #2).
                        reportError = (error as? LocalizedError)?.errorDescription
                            ?? "Could not send report. Please try again."
                    }
                }
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
                let wasActive = activeContact?.id == contact.id
                vm.friends.removeAll { $0.id == contact.id }
                if wasActive { activeContact = nil }
                Task {
                    do {
                        try await appState.service.blockUser(userId: uid, blockedId: contact.id)
                    } catch {
                        // Revert: the confirmation dialog tells the user
                        // they're now protected from this contact -- a
                        // failed block must not leave that claim false with
                        // no signal (compile-errors #2).
                        if !vm.friends.contains(where: { $0.id == contact.id }) {
                            vm.friends.append(contact)
                        }
                        blockError = (error as? LocalizedError)?.errorDescription
                            ?? "Could not block this user. Please try again."
                    }
                }
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
                        // "Delete Group" (task 20260916-group-leave-deletes-
                        // group): a visibly distinct action from "Leave"
                        // above -- separate edge, separate confirmation, and
                        // gated so it only appears where the caller would
                        // actually be authorized (mirrors
                        // GroupsManager.can_delete()'s own rule: a recorded
                        // creator must match the current user, or there's no
                        // recorded creator at all, in which case any current
                        // member -- which the viewer always is here -- is
                        // permitted). The backend re-checks this
                        // independently on DELETE /groups/{userId}/{groupId}
                        // regardless of what this client-side gate shows.
                        .swipeActions(edge: .leading) {
                            if isGroupDeletable(contact) {
                                Button(role: .destructive) {
                                    deleteGroupConfirmTarget = contact
                                } label: {
                                    Label("Delete Group", systemImage: "trash.fill")
                                }
                            }
                        }
                        // Task 20260913-chat-unread-badges: same fold-into-
                        // existing-label treatment as friendsList above.
                        .accessibilityLabel(
                            appState.hasUnread(contact)
                                ? "Open group: \(contact.name), unread messages"
                                : "Open group: \(contact.name)"
                        )
                }
                .listStyle(.plain)
                // See friendsList's identical treatment above (task
                // 20260831-interaction-polish-conventions).
                .refreshable {
                    await vm.refresh(service: appState.service, userId: appState.currentUser?.user_id ?? "")
                }
                .scrollContentBackground(.hidden)
                // See friendsList's identical treatment above (task
                // 20260831-notes-messages-list-scroll-blur) -- same header,
                // same seam, same fix.
                .contentMargins(.top, Theme.spacingSM, for: .scrollContent)
                .contentMargins(.bottom, 110, for: .scrollContent)
                .scrollTopEdgeFeather()
                .padding(.top, Theme.spacingLG)
            }
        }
        .confirmationDialog(
            "Delete \(deleteGroupConfirmTarget?.name ?? "this group")?",
            isPresented: Binding(get: { deleteGroupConfirmTarget != nil }, set: { if !$0 { deleteGroupConfirmTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                guard let contact = deleteGroupConfirmTarget else { return }
                vm.deleteGroup(id: contact.id, userId: appState.currentUser?.user_id ?? "")
                if activeContact?.id == contact.id { activeContact = nil }
                deleteGroupConfirmTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteGroupConfirmTarget = nil }
        } message: {
            Text("This permanently deletes the group for everyone in it, including its notes, messages, devotions, and sessions. This can't be undone.")
        }
        .alert("Couldn't Delete Group", isPresented: Binding(
            get: { vm.deleteGroupActionError != nil },
            set: { if !$0 { vm.deleteGroupActionError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.deleteGroupActionError = nil }
        } message: {
            Text(vm.deleteGroupActionError ?? "")
        }
    }

    // True iff the current user is authorized to delete `contact` outright
    // (client-side mirror of GroupsManager.can_delete() -- see
    // FSContact.creatorId's doc comment). Only meaningful for a `.group`
    // contact; always false for a `.friend`.
    private func isGroupDeletable(_ contact: FSContact) -> Bool {
        guard contact.type == .group else { return false }
        guard let creatorId = contact.creatorId else { return true }
        return creatorId == (appState.currentUser?.user_id ?? "")
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
                // See friendsList's identical treatment above (task
                // 20260831-interaction-polish-conventions).
                .refreshable {
                    await vm.refresh(service: appState.service, userId: appState.currentUser?.user_id ?? "")
                }
                .scrollContentBackground(.hidden)
                // See friendsList's identical treatment above (task
                // 20260831-notes-messages-list-scroll-blur) -- same header,
                // same seam, same fix.
                .contentMargins(.top, Theme.spacingSM, for: .scrollContent)
                .contentMargins(.bottom, 110, for: .scrollContent)
                .scrollTopEdgeFeather()
                .padding(.top, Theme.spacingLG)
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

    // Task 20260913-chat-unread-badges: the one place that recomputes the
    // Chat tab's aggregate unread count, since this is the one view that
    // owns both vm.friends and vm.groups together (AppState itself doesn't
    // hold the contacts list, by design -- see AppState.swift).
    private func recomputeUnread() {
        appState.recomputeUnreadConversationCount(contacts: vm.friends + vm.groups)
    }

    @ViewBuilder
    private func emptyState(icon: String, message: String, hint: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.gold.opacity(0.30))
            Text(message)
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.textSecondary)
            Text(hint)
                .font(.inter(Theme.fontSM))
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
                .font(.inter(Theme.fontBody))
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
    // Surfaces createGroup rejections (see ChatRootView's showAddGroup sheet)
    // instead of the previous silent `try?` no-op — backend step 8 finding #1.
    @Published var groupError: String? = nil
    // Same pattern for createAgent — NetworkService.createAgent now uses
    // checkedRequestRaw and throws instead of fabricating a fake FSAgent with
    // a client-generated id on failure (backend step 11 finding #2).
    @Published var agentError: String? = nil
    // Surfaced by removeFriend/leaveGroup below on a failed mutating call —
    // both used to be a bare optimistic-remove-then-`try?` no-op with no
    // revert and no signal to the user (compile-errors #2).
    @Published var friendActionError: String? = nil
    @Published var groupActionError:  String? = nil
    // Distinct from groupActionError (leave) so a failed owner-gated delete
    // surfaces its own message rather than one worded for "leaving" (task
    // 20260916-group-leave-deletes-group).
    @Published var deleteGroupActionError: String? = nil

    // Guards against a duplicate fetch when this instance is shared between
    // StartupCoordinator (which calls load() once up front to gate the
    // startup loading screen) and this screen's own `.task` (which also
    // calls load() the first time ChatRootView is lazily mounted).
    private var hasLoadedOnce = false

    func load(service: DataServiceProtocol, userId: String) async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await fetchAndCache(service: service, userId: userId, showLoadingSpinner: true)
    }

    /// Pull-to-refresh entry point (task 20260831-interaction-polish-conventions)
    /// — see NotesViewModel.refresh's identical rationale: re-runs `load()`'s
    /// fetch+cache-write flow bypassing the StartupCoordinator dedup guard,
    /// without flipping `isLoading` (which ChatRootView's body uses to swap
    /// its whole content for a loading state) so an already-populated
    /// friends/groups/agents list isn't replaced mid-refresh.
    func refresh(service: DataServiceProtocol, userId: String) async {
        await fetchAndCache(service: service, userId: userId, showLoadingSpinner: false)
    }

    private func fetchAndCache(service: DataServiceProtocol, userId: String, showLoadingSpinner: Bool) async {
        self.service = service
        if showLoadingSpinner { isLoading = true }
        defer { if showLoadingSpinner { isLoading = false } }

        // ── Cache-first: show last-known contacts/agents instantly ───────────────
        if let cached: [FSContact] = await DiskCache.shared.load([FSContact].self, forKey: "friends:\(userId)") {
            friends = cached
            if showLoadingSpinner { isLoading = false }
        }
        if let cached: [FSContact] = await DiskCache.shared.load([FSContact].self, forKey: "groupContacts:\(userId)") {
            groups = cached
        }
        if let cached: [FSAgent] = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(userId)") {
            agents = cached
        }

        async let contactsTask = try? service.fetchContacts(userId: userId)
        async let agentsTask   = try? service.fetchAgents(userId: userId)

        // Bug fix (cache-clobber sweep, task
        // 20260905-pull-to-refresh-cache-clobber): `try?` collapsed a failed
        // fetchContacts/fetchAgents to `([], [:])`/`[]`, which then got
        // written unconditionally over the cache-loaded friends/groups/
        // agents above -- a transient failure wiped all three lists to
        // empty instead of just leaving stale-but-real data on screen.
        // Mirrors DashboardViewModel.load()/NotesViewModel.fetchAndCache:
        // only splice a fetch's result in on its own proven (non-nil)
        // success; each of the two independent fetches keeps whatever was
        // already there if it alone fails.
        if let (contacts, _) = await contactsTask {
            // Sort each list so the conversation with the most recent message is first.
            friends = contacts.filter { $0.type == .friend }.sorted { $0.lastMessageAt > $1.lastMessageAt }
            groups  = contacts.filter { $0.type == .group  }.sorted { $0.lastMessageAt > $1.lastMessageAt }
        }
        if let fetchedAgents = await agentsTask {
            agents = fetchedAgents
        }

        // ── Write fresh data back to the cache ───────────────────────────────────
        // agents:<uid> multi-writer audit (task 20260910-refresh-clobber-
        // live-rootcause, cache_ownership_rule): AccountViewModel.load() also
        // writes this exact key. Confirmed identical in scope/shape to that
        // write -- both source the full per-user agent list from the same
        // `service.fetchAgents(userId:)` call with no filtering difference
        // (unlike DashboardView's now-fixed personal-only notes write, which
        // read from a DIFFERENT, narrower endpoint than NotesViewModel's own
        // "notes:<uid>" writer). Either writer landing last still writes the
        // same authoritative shape, so this key is left shared rather than
        // split -- see AccountViewModel.swift's matching comment.
        await DiskCache.shared.save(friends, forKey: "friends:\(userId)")
        await DiskCache.shared.save(groups,  forKey: "groupContacts:\(userId)")
        await DiskCache.shared.save(agents,  forKey: "agents:\(userId)")
    }

    func createAgent(role: String, userId: String) async {
        do {
            let agent = try await service.createAgent(userId: userId, role: role)
            agents.append(agent)
        } catch {
            agentError = (error as? LocalizedError)?.errorDescription ?? "Could not create agent."
        }
    }

    func removeFriend(id: String, userId: String) {
        let previous = friends
        friends.removeAll { $0.id == id }
        Task {
            do {
                try await service.removeFriend(userId: userId, friendId: id)
            } catch {
                friends = previous
                friendActionError = (error as? LocalizedError)?.errorDescription ?? "Could not remove friend."
            }
        }
    }

    func leaveGroup(id: String, userId: String) {
        let previous = groups
        groups.removeAll { $0.id == id }
        Task {
            do {
                try await service.leaveGroup(userId: userId, groupId: id)
            } catch {
                groups = previous
                groupActionError = (error as? LocalizedError)?.errorDescription ?? "Could not leave group."
            }
        }
    }

    // Task 20260916-group-leave-deletes-group: the deliberate, owner-gated
    // whole-group deletion, distinct from leaveGroup above. Same optimistic-
    // remove-then-revert-on-failure shape as leaveGroup/removeFriend -- a
    // server-side 403 (caller not authorized, e.g. the client-side
    // affordance gate in ChatRootView was stale) reverts the removal and
    // surfaces deleteGroupActionError rather than silently no-opping.
    func deleteGroup(id: String, userId: String) {
        let previous = groups
        groups.removeAll { $0.id == id }
        Task {
            do {
                try await service.deleteGroup(userId: userId, groupId: id)
            } catch {
                groups = previous
                deleteGroupActionError = (error as? LocalizedError)?.errorDescription ?? "Could not delete group."
            }
        }
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
// Task 20260913-chat-unread-badges: the unread dot below replaces this
// comment's prior "intentionally omitted, no unread-tracking system exists
// yet" note -- that deferral is resolved now via AppState.hasUnread(_:), a
// real per-conversation last-read marker compared against FSContact's own
// existing lastMessageAt, not fabricated data. Online-status stays omitted
// (a separate, still-deferred feature -- see file header). The relative
// timestamp still derives purely from lastMessageAt via chatRelativeTime(_:).
struct ContactRow: View {
    let contact: FSContact
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 13) {
            // Task 20260905-profile-photo-avatar-gaps: `contact.photoUrl` is
            // already populated for a friend contact (nil for a group,
            // correctly falling back to initials there) -- it was simply
            // unused by this row before this fix.
            // fillColor: .clear -- AvatarView only takes a flat Color, so the
            // original gradient backdrop lives in `.background` below instead
            // and shows through underneath the initial/photo exactly as before.
            AvatarView(
                initial: String(contact.name.prefix(1)).uppercased(),
                photoURL: contact.photoUrl,
                diameter: 48,
                fillColor: .clear,
                textColor: Theme.goldLight
            )
            .background(
                Circle().fill(LinearGradient(colors: [Color(hex: "#EDAB3C").opacity(0.32), Color(hex: "#B8761D").opacity(0.2)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 1))
            // Task 20260913-chat-unread-badges: design-notes.md's row
            // treatment -- a plain dot (no number; FSContact carries no
            // per-conversation message count to show honestly), anchored to
            // the avatar's own top-left corner since that's the stable
            // visual anchor shared by both the friends and groups rows (this
            // same ContactRow reused for both, per contact.type). Only
            // inserted when unread -- not merely hidden/opacity 0 -- so a
            // read row shows no badge at all.
            .overlay(alignment: .topLeading) {
                if appState.hasUnread(contact) {
                    Circle()
                        .fill(Theme.error)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.bgPage, lineWidth: 2))
                        .offset(x: -2, y: -2)
                        .transition(.unreadBadge(reduceMotion: reduceMotion))
                }
            }
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
// Visual redesign (task 20260902-submenu-visual-redesign): moved off native
// Form/Section onto the shared warm-bloom-ground background + widgetCard()
// layout used across the app's primary screens (this sheet's own before-shot
// was flagged as the literal "huge wasted space below one field" complaint
// this task fixes — hence the added .medium detent below). Logic/callback
// wiring and the existing accessibility label are unchanged.
struct AddFriendSheet: View {
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    Text("SEARCH BY USERNAME")
                        .font(.inter(Theme.fontXXS)).tracking(4)
                        .foregroundColor(Theme.textGoldMuted)
                    TextField("Username", text: $username)
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                        .autocapitalization(.none)
                        .accessibilityLabel("Enter username to add as friend")
                }
                .widgetCard()
                .padding(Theme.spacingLG)
            }
            .warmBloomBackground()
            // Shared keyboard-dismiss convention (task
            // 20260831-interaction-polish-conventions).
            .dismissesKeyboardOnScrollAndTap()
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            // Follow-up polish (task 20260902-submenu-followup-polish):
            // plain system-styled toolbar Buttons picked up iOS's automatic
            // Liquid Glass capsule chrome instead of this app's own button
            // language. Cancel gets the established ghost-chip dismiss
            // recipe (NoteEditorView.cancelChip / NotesListView.ghostPill),
            // Send Request reuses PillButton's amber-gradient recipe
            // directly. A `.principal` title item centers "Add Friend"
            // independent of these two items' widths -- the default inline
            // title only centers within the leading/trailing gap, which the
            // old asymmetric Cancel/Send-Request widths visibly threw off.
            // `.sharedBackgroundVisibility(.hidden)` on both custom items
            // avoids the doubled Liquid Glass + own-stroke outline
            // NotesListView's ghostPill/gradientPill toolbar items already
            // had to work around.
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) { sheetGhostCancelLabel }
                        .buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .principal) {
                    Text("Add Friend")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    PillButton(title: "Send Request") {
                        onSend(username)
                        dismiss()
                    }
                    .disabled(username.isEmpty)
                }
                .suppressAutomaticGlassChrome()
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

// ── Add group sheet (mirrors GroupModal in MessagingSidebar.jsx) ───────────────
// Visual redesign (task 20260902-submenu-visual-redesign): same Form-to-
// widgetCard() migration as AddFriendSheet above, with member rows moved from
// a List into a plain VStack + Divider so the whole sheet sits on the shared
// warm-bloom-ground background instead of native grouped-list chrome. Member
// count is variable, so this gets [.medium, .large] rather than a fixed
// detent, so a long member list isn't clipped.
struct AddGroupSheet: View {
    let friends:  [FSContact]
    let onCreate: (String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var groupName   = ""
    @State private var selectedIds = Set<String>()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacingLG) {
                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("GROUP NAME")
                            .font(.inter(Theme.fontXXS)).tracking(4)
                            .foregroundColor(Theme.textGoldMuted)
                        TextField("Study Group", text: $groupName)
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                            .accessibilityLabel("Group name field")
                    }
                    .widgetCard()

                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("MEMBERS")
                            .font(.inter(Theme.fontXXS)).tracking(4)
                            .foregroundColor(Theme.textGoldMuted)
                        VStack(spacing: 0) {
                            ForEach(Array(friends.enumerated()), id: \.element.id) { index, f in
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
                                .padding(.vertical, Theme.spacingSM)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedIds.contains(f.id) { selectedIds.remove(f.id) }
                                    else                           { selectedIds.insert(f.id) }
                                }
                                .accessibilityLabel("\(f.name). \(selectedIds.contains(f.id) ? "Selected" : "Not selected")")
                                .accessibilityAddTraits(selectedIds.contains(f.id) ? .isSelected : [])

                                if index < friends.count - 1 {
                                    Divider().opacity(0.15)
                                }
                            }
                        }
                    }
                    .widgetCard()
                }
                .padding(Theme.spacingLG)
            }
            .warmBloomBackground()
            // Shared keyboard-dismiss convention (task
            // 20260831-interaction-polish-conventions).
            .dismissesKeyboardOnScrollAndTap()
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            // Follow-up polish (task 20260902-submenu-followup-polish): same
            // ghost-chip-Cancel / PillButton-Create / centered-`.principal`-
            // title treatment as AddFriendSheet above -- see its toolbar
            // comment for the full rationale.
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) { sheetGhostCancelLabel }
                        .buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .principal) {
                    Text("New Group")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    PillButton(title: "Create") {
                        onCreate(groupName, Array(selectedIds))
                        dismiss()
                    }
                    .disabled(groupName.isEmpty)
                }
                .suppressAutomaticGlassChrome()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

// ── Shared ghost-chip Cancel label for this file's sheets (task
// 20260902-submenu-followup-polish) -- matches the app's established
// ghost-chip dismiss recipe (NoteEditorView.cancelChip's icon-chip variant,
// NotesListView.ghostPill's text-chip variant): a faint parchment-tinted
// capsule fill + stroke, muted text, rather than a second gold-filled pill,
// so Cancel doesn't visually compete with each sheet's one true primary gold
// action. `.fixedSize()` matches NotesListView.ghostPill's own fix for the
// same problem -- the leading toolbar slot proposes a very narrow width on
// iOS 26 that otherwise wraps/truncates the label.
fileprivate var sheetGhostCancelLabel: some View {
    Text("Cancel")
        .font(.inter(Theme.fontSM))
        .foregroundColor(Theme.textSecondary)
        .fixedSize()
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(Theme.parchment.opacity(0.06)))
        .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
}
