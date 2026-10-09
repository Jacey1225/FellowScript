// GroupRowThreadsView.swift — a group row in ChatRootView's Groups segment
// plus its inline, expandable thread list (task 20261008-group-row-thread-
// dropdown). A small chevron at the card's bottom-right toggles a list of the
// group's thread titles directly beneath the card; tapping a title opens that
// thread inside the group chat.
//
// Gating: the chevron only renders when capabilities.isEnabled("threads").
// That is display gating only; the server enforces membership and the flag on
// GET /groups/{user}/{group}/threads.
//
// Data: reuses GroupThreadsViewModel (lazy: nothing is fetched until the first
// expand; later expands reuse the in-memory result; DiskCache behaviour and
// preserve-cache-on-failed-refresh are inherited). Thread rows are flush on
// the page background -- no fill, border or glass -- by design.

import SwiftUI

struct GroupRowWithThreads: View {
    let contact: FSContact
    let accessibilityText: String
    let onOpenChat: () -> Void
    let onOpenThread: (FSThreadSummary) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var vm: GroupThreadsViewModel
    @State private var expanded = false

    /// Leading inset of the flush thread rows: lines up under the group name
    /// (card padding 14 + avatar 48 + spacing 13).
    private static let threadIndent: CGFloat = 75

    init(contact: FSContact, service: DataServiceProtocol, userId: String,
         accessibilityText: String,
         onOpenChat: @escaping () -> Void,
         onOpenThread: @escaping (FSThreadSummary) -> Void) {
        self.contact = contact
        self.accessibilityText = accessibilityText
        self.onOpenChat = onOpenChat
        self.onOpenThread = onOpenThread
        _vm = StateObject(wrappedValue: GroupThreadsViewModel(service: service, groupId: contact.id, userId: userId))
    }

    private var threadsEnabled: Bool { appState.capabilities.isEnabled("threads") }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                ContactRow(contact: contact, trailingReserve: threadsEnabled ? 30 : 0)
                    .onTapGesture { onOpenChat() }
                    .accessibilityLabel(accessibilityText)
                if threadsEnabled { chevron }
            }
            if threadsEnabled && expanded {
                threadList
                    .transition(.opacity)
            }
        }
        .onChange(of: threadsEnabled) { _, on in if !on { expanded = false } }
    }

    private var chevron: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.gold.opacity(0.8))
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide threads" : "Show threads")
        .accessibilityHint("For \(contact.name)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("group-row-threads-chevron")
    }

    private func toggle() {
        let willExpand = !expanded
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { expanded = willExpand }
        if willExpand && !vm.loaded { Task { await vm.load() } }
    }

    // ── Expanded list ──────────────────────────────────────────────────────────
    private var threadList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.loadFailed {
                HStack {
                    Text(vm.threads.isEmpty ? "Couldn't load threads." : "Couldn't refresh just now.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.85))
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await vm.load() } }
                        .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint("Reloads the thread list")
                }
            }

            if !vm.loaded && !vm.loadFailed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.gold)
                    Text("Loading threads…")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }

            if vm.loaded && vm.threads.isEmpty && !vm.loadFailed {
                Text("No threads yet.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    .frame(minHeight: 44, alignment: .leading)
            }

            ForEach(vm.threads) { thread in
                Button { onOpenThread(thread) } label: {
                    Text(thread.title.isEmpty ? "Thread" : thread.title)
                        .font(.inter(Theme.fontSM, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(thread.title.isEmpty ? "Thread" : thread.title)
                .accessibilityHint("Opens this thread")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("group-row-thread")
            }

            if vm.hasMore {
                Button { Task { await vm.loadMore() } } label: {
                    Text(vm.moreFailed ? "Couldn't load more. Retry" : (vm.isLoadingMore ? "Loading…" : "Show more"))
                        .font(.inter(Theme.fontXS, weight: .semibold))
                        .foregroundColor(Theme.gold)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.isLoadingMore)
                .accessibilityLabel(vm.moreFailed ? "Couldn't load more threads, retry" : "Show more threads")
            }
        }
        .padding(.leading, Self.threadIndent)
        .padding(.trailing, 14)
        .padding(.top, 4)
        .accessibilityIdentifier("group-row-threads-list")
    }
}
