// GroupInfoThreadsList.swift -- task 20261023-group-info-row. Thread rows for the
// group info submenu. Reuses GroupThreadsViewModel (cache first, paging,
// preserve-cache-on-failed-refresh).

import SwiftUI

enum GroupInfoThreadsCopy {
    /// "3 replies" / "1 reply" / "No replies yet", plus relative time when known.
    static func detail(_ thread: FSThreadSummary) -> String {
        let n = thread.replyCount
        let replies = n == 0 ? "No replies yet" : (n == 1 ? "1 reply" : "\(n) replies")
        let when = FSMessageActionPolicy.relativeTime(thread.lastActivityAt)
        return when.isEmpty ? replies : "\(replies) · \(when)"
    }
}

struct GroupInfoThreadsList: View {
    @ObservedObject var vm: GroupThreadsViewModel
    let onSelect: (FSThreadSummary) -> Void

    var body: some View {
        Group {
            if !vm.loaded {
                if vm.loadFailed {
                    GroupInfoErrorView(category: .threads) { Task { await vm.load() } }
                } else {
                    GroupInfoLoadingView(category: .threads)
                }
            } else if vm.threads.isEmpty && !vm.loadFailed {
                GroupInfoEmptyView(category: .threads)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if vm.loadFailed { GroupInfoRefreshNote { Task { await vm.load() } } }
                        ForEach(Array(vm.threads.enumerated()), id: \.element.id) { index, thread in
                            if index > 0 { Rectangle().fill(Theme.parchment.opacity(0.10)).frame(height: 0.5) }
                            row(thread)
                        }
                        if vm.hasMore {
                            Button { Task { await vm.loadMore() } } label: {
                                Text(vm.moreFailed ? "Couldn't load more. Try again" : (vm.isLoadingMore ? "Loading…" : "Show more"))
                                    .font(.inter(Theme.fontSM, weight: .bold)).foregroundColor(Theme.gold)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.isLoadingMore)
                        }
                    }
                    .padding(.horizontal, Theme.spacingMD)
                }
            }
        }
        .task { await vm.load() }
    }

    private func row(_ thread: FSThreadSummary) -> some View {
        Button { onSelect(thread) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title.isEmpty ? "Thread" : thread.title)
                        .font(.inter(15, weight: .semibold)).foregroundColor(Theme.parchment)
                        .lineLimit(1)
                    Text(GroupInfoThreadsCopy.detail(thread))
                        .font(.inter(13)).foregroundColor(Theme.parchment.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.gold.opacity(0.8))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this thread")
        .accessibilityAddTraits(.isButton)
    }
}
