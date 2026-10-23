// GroupRowThreadsView.swift -- a group row in ChatRootView's Groups segment
// plus its expandable thread list (tasks 20261008-group-row-thread-dropdown,
// 20261022-ios-group-threads-folder). A slim "Threads" folder row (label +
// chevron) is tucked beneath the group card; tapping it slides down a panel
// in the same glass material as the card with the group's thread titles flush
// left and hairline dividers between them. Tapping a title opens that thread
// inside the group chat.
//
// Gating: the folder row only renders when capabilities.isEnabled("threads").
// That is display gating only; the server enforces membership and the flag on
// GET /groups/{user}/{group}/threads.
//
// Data: reuses GroupThreadsViewModel (lazy: nothing is fetched until the first
// expand; later expands reuse the in-memory result; DiskCache behaviour and
// preserve-cache-on-failed-refresh are inherited).

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

    /// How far the group card overlaps the top of the Threads tray. The tray
    /// adds the same amount of top padding inside itself so its label and
    /// chevron sit in the visible (non-overlapped) part.
    private let trayOverlap: CGFloat = 12
    private let trayRadius: CGFloat = 14

    var body: some View {
        // Layering lives inside the row (negative spacing + zIndex), not as an
        // out-of-bounds offset, so List never clips it.
        VStack(spacing: 0) {
            ContactRow(contact: contact)
                .onTapGesture { onOpenChat() }
                .accessibilityLabel(accessibilityText)
                .zIndex(1)
            if threadsEnabled { tray.zIndex(0) }
        }
        .onChange(of: threadsEnabled) { _, on in if !on { expanded = false } }
    }

    /// Folder row + (expanded) panel as one continuous shape tucked beneath the
    /// card: the card covers the tray's top edge, the tray is a darker inset of
    /// the card's material with rounded bottom corners only.
    private var tray: some View {
        VStack(spacing: 0) {
            folderRow
            if expanded {
                VStack(spacing: 0) {
                    hairline
                    threadList
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, trayOverlap)
        .clipShape(trayShape)
        .background(trayBackground)
        .overlay(alignment: .top) {
            // Shadow the card casts onto the tray.
            LinearGradient(colors: [Color.black.opacity(0.28), Color.clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: trayOverlap + 8)
                .clipShape(trayShape)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 18)
        .padding(.top, -trayOverlap)
    }

    private var trayShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: trayRadius,
                               bottomTrailingRadius: trayRadius, topTrailingRadius: 0,
                               style: .continuous)
    }

    private var trayBackground: some View {
        ZStack {
            trayShape.fill(.ultraThinMaterial)
            trayShape.fill(Color.black.opacity(0.32))
            trayShape.strokeBorder(Theme.gold.opacity(0.12), lineWidth: 0.5)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.parchment.opacity(0.10))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    private var folderRow: some View {
        Button(action: toggle) {
            HStack {
                Text("Threads")
                    .font(.inter(Theme.fontXS, weight: .semibold))
                    .foregroundColor(Theme.parchment.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.gold.opacity(0.8))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide threads" : "Show threads")
        .accessibilityHint("For \(contact.name)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("group-row-threads-toggle")
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
                .padding(.horizontal, 14)
            }

            if !vm.loaded && !vm.loadFailed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.gold)
                    Text("Loading threads…")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            if vm.loaded && vm.threads.isEmpty && !vm.loadFailed {
                Text("No threads yet.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }

            ForEach(Array(vm.threads.enumerated()), id: \.element.id) { index, thread in
                if index > 0 { hairline }
                Button { onOpenThread(thread) } label: {
                    Text(thread.title.isEmpty ? "Thread" : thread.title)
                        .font(.inter(Theme.fontSM, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
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
                if !vm.threads.isEmpty { hairline }
                Button { Task { await vm.loadMore() } } label: {
                    Text(vm.moreFailed ? "Couldn't load more. Retry" : (vm.isLoadingMore ? "Loading…" : "Show more"))
                        .font(.inter(Theme.fontXS, weight: .semibold))
                        .foregroundColor(Theme.gold)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.isLoadingMore)
                .accessibilityLabel(vm.moreFailed ? "Couldn't load more threads, retry" : "Show more threads")
            }
        }
        .padding(.bottom, 4)
        .accessibilityIdentifier("group-row-threads-list")
    }
}
