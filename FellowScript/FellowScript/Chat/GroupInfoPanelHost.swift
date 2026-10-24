// GroupInfoPanelHost.swift -- task 20261023-group-info-row. Overlay over the chat's
// message area (below the header + chip row, above the composer) that owns the
// per-category data models, the scrim, the open/close motion, the announcement
// detail sheet and the announcement push deep link (which used to live in the
// removed banner widget). Lists fetch on first open, never on row render.

import SwiftUI

struct GroupInfoPanelHost: View {
    let contact: FSContact
    let userId: String
    @Binding var selected: GroupInfoCategory?
    /// Categories whose feature is on; the panel closes if its category drops out.
    let visible: [GroupInfoCategory]
    let pinsVM: ChatThreadViewModel
    let onOpenThread: (FSThreadSummary) -> Void
    let onJumpToPin: (FSPinnedMessage) -> Void
    let onJumpToMessage: (String) -> Void
    /// Unseen counts for the chip badges (computed here, where the list models live).
    @Binding var badges: [GroupInfoCategory: Int]
    /// The Sessions submenu body (owned by the chat view, which has the session state).
    let sessionsContent: () -> AnyView

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var announcements: GroupAnnouncementsViewModel
    @StateObject private var threads: GroupThreadsViewModel
    @StateObject private var media: GroupMediaViewModel
    @State private var viewing: FSGroupAnnouncement?

    init(contact: FSContact, userId: String, selected: Binding<GroupInfoCategory?>,
         visible: [GroupInfoCategory], service: DataServiceProtocol, pinsVM: ChatThreadViewModel,
         onOpenThread: @escaping (FSThreadSummary) -> Void,
         onJumpToPin: @escaping (FSPinnedMessage) -> Void,
         onJumpToMessage: @escaping (String) -> Void,
         badges: Binding<[GroupInfoCategory: Int]>,
         sessionsContent: @escaping () -> AnyView) {
        _badges = badges
        self.sessionsContent = sessionsContent
        self.contact = contact
        self.userId = userId
        _selected = selected
        self.visible = visible
        self.pinsVM = pinsVM
        self.onOpenThread = onOpenThread
        self.onJumpToPin = onJumpToPin
        self.onJumpToMessage = onJumpToMessage
        _announcements = StateObject(wrappedValue: GroupAnnouncementsViewModel(service: service, groupId: contact.id, userId: userId))
        _threads = StateObject(wrappedValue: GroupThreadsViewModel(service: service, groupId: contact.id, userId: userId))
        _media = StateObject(wrappedValue: GroupMediaViewModel(service: service, groupId: contact.id, userId: userId))
    }

    private func close() { selected = nil }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if let category = selected {
                    Color.black.opacity(0.25)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    GroupInfoSubmenu(category: category,
                                     height: GroupInfoPanelMetrics.height(forAvailable: geo.size.height),
                                     onClose: close) {
                        panelContent(category)
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(GroupInfoPanelMotion.animation(opening: selected != nil, reduceMotion: reduceMotion),
                       value: selected != nil)
        }
        .onChange(of: visible) { _, now in
            if let selected, !now.contains(selected) { close() }
        }
        .task { await consumePendingOpen() }
        // Chip badges: quiet first-page loads, recomputed as the live lists change; opening
        // a submenu marks it seen.
        .task { await refreshBadgeSources() }
        .onChange(of: scenePhase) { _, p in if p == .active { Task { await refreshBadgeSources() } } }
        .onChange(of: announcements.items) { _, _ in recomputeBadges() }
        .onChange(of: threads.threads) { _, _ in recomputeBadges() }
        .onChange(of: pinsVM.pinsRevision) { _, _ in recomputeBadges() }
        .onChange(of: selected) { _, _ in recomputeBadges() }
        .onChange(of: appState.pendingAnnouncementOpen) { _, _ in Task { await consumePendingOpen() } }
        .sheet(item: $viewing) { item in
            NavigationStack {
                // Read-only here; edit/delete stay in the group info panel.
                GroupAnnouncementDetailView(item: readOnly(item), onEdit: {}, onDelete: {},
                                            onRSVP: { join in try await announcements.rsvp(item, join: join) },
                                            pollActions: announcements.pollActions(for: readOnly(item)))
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { viewing = nil }
                                .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func panelContent(_ category: GroupInfoCategory) -> some View {
        switch category {
        case .announcements:
            GroupInfoAnnouncementsList(vm: announcements, groupName: contact.name) { viewing = $0 }
        case .threads:
            GroupInfoThreadsList(vm: threads) { thread in close(); onOpenThread(thread) }
        case .pinned:
            PinnedMessagesSheet(vm: pinsVM, contact: contact, service: appState.service, userId: userId,
                                onSelect: { pin in close(); onJumpToPin(pin) }, inPanel: true)
        case .media:
            GroupInfoMediaGrid(vm: media) { id in close(); onJumpToMessage(id) }
        case .sessions:
            sessionsContent()
        }
    }

    // MARK: Badges

    private var seenStore: GroupInfoSeenStore { GroupInfoSeenStore(userId: userId, groupId: contact.id) }

    private func refreshBadgeSources() async {
        async let a: Void = announcements.load()
        async let t: Void = threads.load()
        async let p: Void = pinsVM.loadPins(service: appState.service, contact: contact, userId: userId, reset: true, quiet: true)
        _ = await (a, t, p)
        recomputeBadges()
    }

    private func badgeItems(_ c: GroupInfoCategory) -> [GroupInfoBadgeLogic.Item]? {
        switch c {
        case .announcements:
            guard announcements.loaded else { return nil }
            return announcements.publishedItems.compactMap { a in
                parseFlexibleISO8601(a.publish_at).map { GroupInfoBadgeLogic.Item(at: $0, byMe: a.creator_id == userId) }
            }
        case .threads:
            guard threads.loaded else { return nil }
            return threads.threads.compactMap { t in
                parseFlexibleISO8601(t.lastActivityAt).map { GroupInfoBadgeLogic.Item(at: $0, byMe: t.createdBy == userId && t.replyCount == 0) }
            }
        case .pinned:
            guard pinsVM.pinsState != .idle else { return nil }
            return pinsVM.pins.compactMap { p in
                p.pinnedAt.flatMap(parseFlexibleISO8601).map { GroupInfoBadgeLogic.Item(at: $0, byMe: p.pinnedById == userId) }
            }
        case .media, .sessions:
            return nil
        }
    }

    private func recomputeBadges() {
        #if DEBUG
        // Screenshot seam (UI tests only, mock data): fixed badge counts on the chips.
        if ProcessInfo.processInfo.arguments.contains("UI-TESTING-BADGES") {
            let fixed: [GroupInfoCategory: Int] = [.announcements: 2, .threads: 1, .pinned: 3]
            badges = fixed.filter { $0.key != selected }
            return
        }
        #endif
        var next: [GroupInfoCategory: Int] = [:]
        for c in [GroupInfoCategory.announcements, .threads, .pinned] {
            guard let items = badgeItems(c) else { continue }
            let newest = GroupInfoBadgeLogic.newest(items)
            if selected == c {                       // looking at it: everything is seen
                if let newest { seenStore.setSeen(c, newest) }
                continue
            }
            // First run (no watermark): seed to the newest item, or to now when the list is empty,
            // so the first item that ever arrives still badges.
            guard let seen = seenStore.seen(c) else { seenStore.setSeen(c, GroupInfoBadgeLogic.seedWatermark(newest: newest)); continue }
            let n = GroupInfoBadgeLogic.unseenCount(items, seen: seen)
            if n > 0 { next[c] = n }
        }
        if next != badges { badges = next }
    }

    private func readOnly(_ item: FSGroupAnnouncement) -> FSGroupAnnouncement {
        var copy = item
        copy.can_edit = false
        return copy
    }

    /// Push deep link: opens the announcement detail; falls back to just the chat if it is gone.
    private func consumePendingOpen() async {
        guard let pending = appState.pendingAnnouncementOpen, pending.groupId == contact.id else { return }
        appState.pendingAnnouncementOpen = nil
        guard let svc = appState.service as? GroupAnnouncementsService,
              let item = try? await svc.fetchAnnouncement(userId: userId, groupId: contact.id, announcementId: pending.announcementId)
        else { return }
        viewing = item
    }
}

/// Keeps the submenu consistent with the rest of the chat screen: opening it
/// dismisses the keyboard and the Sessions overlay; focusing the composer or
/// opening a thread closes it.
struct GroupInfoCoordination: ViewModifier {
    @Binding var category: GroupInfoCategory?
    var composerFocused: FocusState<Bool>.Binding
    @Binding var showSessions: Bool
    let isThreadOpen: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: category) { _, c in
                if c != nil { composerFocused.wrappedValue = false; showSessions = false }
            }
            .onChange(of: composerFocused.wrappedValue) { _, focused in if focused { category = nil } }
            .onChange(of: isThreadOpen) { _, open in if open { category = nil } }
    }
}
