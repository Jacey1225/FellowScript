// GroupAnnouncementsView.swift — list screen of the group info sheet's
// Announcements sub-view (task 20260929-group-announcements, design-notes.md).
// Pushed onto the sheet's NavigationStack. Rows: tap to view, swipe right
// (leading edge) to delete with an 8s undo, plus accessibility actions and a
// Delete button in the detail menu so swipe is never the only path.

import SwiftUI

/// Feature flag mirroring the server's ANNOUNCEMENTS_ENABLED; the entry row is
/// absent (not disabled) when off.
enum GroupAnnouncementsConfig {
    static let enabled = true
}

private enum AnnouncementForm: Identifiable {
    case new
    case edit(FSGroupAnnouncement)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let a): return "edit-\(a.id)"
        }
    }
}

struct GroupAnnouncementsView: View {
    @StateObject private var vm: GroupAnnouncementsViewModel
    var onGroupGone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var form: AnnouncementForm?
    @State private var selectedId: String?
    @State private var showGatePrompt = false

    init(service: DataServiceProtocol, groupId: String, userId: String, onGroupGone: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: GroupAnnouncementsViewModel(service: service, groupId: groupId, userId: userId))
        self.onGroupGone = onGroupGone
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: Theme.spacingSM) {
                if vm.refreshFailed { refreshBanner }
                if showGatePrompt { AnnouncementLimitCard(gate: vm.gate, onDismiss: { showGatePrompt = false }) }
                if let notice = vm.notice {
                    Text(notice).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.spacingMD)
                }
                content
            }
            if vm.undoItem != nil { undoToast }
        }
        .warmBloomBackground()
        .navigationTitle("Announcements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { openNew() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.gold)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("New announcement")
            }
        }
        .task { await vm.load() }
        .onDisappear { vm.commitPendingDeletes() }
        .onChange(of: vm.removedFromGroup) { _, gone in if gone { onGroupGone() } }
        .navigationDestination(isPresented: Binding(get: { selectedItem != nil }, set: { if !$0 { selectedId = nil } })) {
            if let item = selectedItem {
                GroupAnnouncementDetailView(
                    item: item,
                    onEdit: { form = .edit(item) },
                    onDelete: { vm.startDelete(item); selectedId = nil },
                    onRSVP: { join in try await vm.rsvp(item, join: join) }
                )
            }
        }
        .sheet(item: $form) { f in
            switch f {
            case .new:
                GroupAnnouncementFormView(vm: vm, editing: nil) { _ in form = nil }
            case .edit(let item):
                GroupAnnouncementFormView(vm: vm, editing: item) { _ in form = nil }
            }
        }
    }

    private var selectedItem: FSGroupAnnouncement? {
        guard let id = selectedId else { return nil }
        return vm.items.first { $0.id == id }
    }

    private func openNew() {
        vm.notice = nil
        if vm.limitReached { showGatePrompt = true } else { form = .new }
    }

    // ── Content ──────────────────────────────────────────────────────────────
    @ViewBuilder
    private var content: some View {
        if !vm.loaded && vm.loading {
            VStack(spacing: Theme.spacingSM) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.radius).fill(Color.white.opacity(0.08)).frame(height: 72)
                }
            }
            .padding(.horizontal, Theme.spacingMD)
            .accessibilityLabel("Loading announcements")
        } else if !vm.loaded, let err = vm.loadError {
            VStack(spacing: Theme.spacingSM) {
                Text(err).font(.inter(Theme.fontSM)).foregroundColor(Theme.error)
                Button("Retry") { Task { await vm.load() } }
                    .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold).frame(minHeight: 44)
            }
            .padding(Theme.spacingMD)
            Spacer()
        } else if vm.loaded && vm.visibleItems.isEmpty {
            Text("No announcements yet.")
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment.opacity(0.6))
                .frame(maxWidth: .infinity).padding(.top, Theme.spacingLG)
            Spacer()
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !vm.scheduledItems.isEmpty {
                Section {
                    ForEach(vm.scheduledItems) { row($0) }
                } header: {
                    Text("Scheduled")
                        .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
                        .foregroundColor(Theme.gold.opacity(0.7))
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Section {
                ForEach(vm.publishedItems) { row($0) }
            }
            if vm.truncated {
                Text("Showing the most recent announcements.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: vm.hiddenIds)
    }

    @ViewBuilder
    private func row(_ item: FSGroupAnnouncement) -> some View {
        Button { selectedId = item.id } label: {
            AnnouncementRow(item: item)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.can_edit {
                Button(role: .destructive) { vm.startDelete(item) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(Theme.error.opacity(0.85))
            }
        }
        .accessibilityAction(named: "Delete") { if item.can_edit { vm.startDelete(item) } }
        .accessibilityAction(named: "Edit") { if item.can_edit { form = .edit(item) } }
    }

    private var refreshBanner: some View {
        HStack {
            Text("Couldn't refresh. Showing your last loaded list.")
                .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.85))
            Spacer()
            Button("Retry") { Task { await vm.load() } }
                .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold).frame(minHeight: 44)
        }
        .padding(.horizontal, Theme.spacingSM)
        .background(Theme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .padding(.horizontal, Theme.spacingMD)
    }

    private var undoToast: some View {
        HStack {
            Text("Announcement deleted.").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
            Spacer()
            Button("Undo") { vm.undoDelete() }
                .font(.inter(Theme.fontSM, weight: .bold)).foregroundColor(Theme.gold).frame(minHeight: 44)
        }
        .padding(.horizontal, Theme.spacingMD)
        .background(Theme.islandBg)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .padding(Theme.spacingMD)
        .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Announcement deleted. Undo available for a few seconds.")
        .onAppear { UIAccessibility.post(notification: .announcement, argument: "Announcement deleted. Undo available.") }
    }
}

// ── Row ──────────────────────────────────────────────────────────────────────
private struct AnnouncementRow: View {
    let item: FSGroupAnnouncement

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = item.banner_url, let url = URL(string: s) {
                AnnouncementBannerImage(source: .url(url))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(AnnouncementTitleFont.resolve(item.title_font).font(Theme.fontSM, relativeTo: .subheadline))
                    .foregroundColor(AnnouncementTitleColor.surfaceColor(item.title_color, fallback: Theme.parchment)).lineLimit(1)
                Text(item.description).font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.7)).lineLimit(2)
                HStack(spacing: 6) {
                    if !item.published {
                        Text("Scheduled")
                            .font(.inter(Theme.fontXXS, weight: .semibold)).foregroundColor(Theme.gold)
                            .padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Theme.gold.opacity(0.12)).clipShape(Capsule())
                    }
                    Text("\(item.creator_username ?? "a member") · \(FSAnnouncementDates.display(item.publish_at))")
                        .font(.inter(Theme.fontXXS)).foregroundColor(Theme.parchment.opacity(0.6))
                }
            }
        }
        // Same treatment as NoteRow (Notes/NotesRowViews.swift).
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .glassCard(cornerRadius: 20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the announcement")
    }
}

// ── Free-limit upgrade card ──────────────────────────────────────────────────
struct AnnouncementLimitCard: View {
    let gate: FSAnnouncementGate?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            Text("You've used this week's announcement")
                .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.parchment)
            Text("Free plans can post \(gate?.limit ?? 1) announcement every 7 days. Upgrade for unlimited announcements.")
                .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.7))
            HStack(spacing: Theme.spacingSM) {
                PillButton(title: "See plans") {
                    onDismiss?()
                    NotificationCenter.default.post(name: .fsOpenSubscriptionPlans, object: nil)
                }
                if let onDismiss {
                    Button("Not now", action: onDismiss)
                        .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold).frame(minHeight: 44)
                }
            }
        }
        .padding(Theme.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .padding(.horizontal, Theme.spacingMD)
        .accessibilityElement(children: .contain)
    }
}
