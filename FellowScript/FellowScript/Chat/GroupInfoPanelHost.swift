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

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var announcements: GroupAnnouncementsViewModel
    @StateObject private var threads: GroupThreadsViewModel
    @StateObject private var media: GroupMediaViewModel
    @State private var viewing: FSGroupAnnouncement?

    init(contact: FSContact, userId: String, selected: Binding<GroupInfoCategory?>,
         visible: [GroupInfoCategory], service: DataServiceProtocol, pinsVM: ChatThreadViewModel,
         onOpenThread: @escaping (FSThreadSummary) -> Void,
         onJumpToPin: @escaping (FSPinnedMessage) -> Void,
         onJumpToMessage: @escaping (String) -> Void) {
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
        .onChange(of: appState.pendingAnnouncementOpen) { _, _ in Task { await consumePendingOpen() } }
        .sheet(item: $viewing) { item in
            NavigationStack {
                // Read-only here; edit/delete stay in the group info panel.
                GroupAnnouncementDetailView(item: readOnly(item), onEdit: {}, onDelete: {},
                                            onRSVP: { join in try await announcements.rsvp(item, join: join) })
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
        }
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
