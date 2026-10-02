// GroupThreadsSection.swift — "Threads" section of the group info sheet
// (task 20261001-message-threads step 10; registry order 30, after Join
// requests and before Members). Registered as one line in
// GroupInfoExtraSections.registry; GroupInfoSheet.swift is not edited.
//
// Visible only when capabilities.features.threads is true (false/missing =
// nothing rendered). Rows: title, root snippet ("Original message deleted"
// when the root was deleted), "N replies" and relative last activity. Tapping a
// row opens that thread straight away (fsOpenThread, provided by
// ChatThreadView) in the chat view's thread mode on its single socket.
//
// Loading: skeleton rows. Failure: inline "Couldn't load threads" + Retry with
// the previously shown rows kept (preserve-cache-on-failed-refresh; last good
// page is persisted in DiskCache). Paging: "Show more" via the keyset cursor.
// Throw-not-fabricate: an empty list is shown only after a successful fetch.

import SwiftUI
import Combine

/// Provided by ChatThreadView to anything presented from it (the group info
/// sheet): open this thread now. nil outside a chat.
struct FSOpenThreadAction {
    let run: (FSThreadSummary) -> Void
}

private struct FSOpenThreadKey: EnvironmentKey {
    static let defaultValue: FSOpenThreadAction? = nil
}
extension EnvironmentValues {
    var fsOpenThread: FSOpenThreadAction? {
        get { self[FSOpenThreadKey.self] }
        set { self[FSOpenThreadKey.self] = newValue }
    }
}

@MainActor
final class GroupThreadsViewModel: ObservableObject {
    static let pageSize = 20

    @Published private(set) var threads: [FSThreadSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    /// true once a fetch (or the disk cache) has produced a list.
    @Published private(set) var loaded = false
    @Published private(set) var loadFailed = false
    @Published private(set) var moreFailed = false
    @Published private(set) var hasMore = false
    private var cursorTimestamp: String?
    private var cursorId: String?

    private let service: DataServiceProtocol
    private let groupId: String
    private let userId: String
    private var cacheKey: String { "threads:\(userId):\(groupId)" }

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service
        self.groupId = groupId
        self.userId = userId
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        if !loaded, let cached: [FSThreadSummary] = await DiskCache.shared.load([FSThreadSummary].self, forKey: cacheKey) {
            threads = cached
            loaded = true
        }
        do {
            let page = try await service.fetchThreads(userId: userId, groupId: groupId, limit: Self.pageSize,
                                                       cursorTimestamp: nil, cursorId: nil)
            threads = page.threads
            hasMore = page.hasMore
            cursorTimestamp = page.cursorTimestamp
            cursorId = page.cursorId
            loaded = true
            moreFailed = false
            await DiskCache.shared.save(page.threads, forKey: cacheKey)
        } catch {
            // Keep whatever is already shown; only flag the failure.
            print("[GroupThreadsViewModel] load failed: \(error)")
            loadFailed = true
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let ts = cursorTimestamp, let id = cursorId else { return }
        isLoadingMore = true
        moreFailed = false
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchThreads(userId: userId, groupId: groupId, limit: Self.pageSize,
                                                       cursorTimestamp: ts, cursorId: id)
            let have = Set(threads.map(\.id))
            threads += page.threads.filter { !have.contains($0.id) }
            hasMore = page.hasMore
            cursorTimestamp = page.cursorTimestamp
            cursorId = page.cursorId
        } catch {
            print("[GroupThreadsViewModel] load more failed: \(error)")
            moreFailed = true
        }
    }
}

struct GroupThreadsSection: View {
    let context: GroupInfoSectionContext
    @StateObject private var vm: GroupThreadsViewModel
    @Environment(\.fsOpenThread) private var openThread

    init(context: GroupInfoSectionContext) {
        self.context = context
        _vm = StateObject(wrappedValue: GroupThreadsViewModel(
            service: context.service, groupId: context.groupId, userId: context.userId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Threads")
                .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.gold.opacity(0.7))
                .accessibilityAddTraits(.isHeader)

            if vm.loadFailed {
                HStack {
                    Text(vm.threads.isEmpty ? "Couldn't load threads." : "Couldn't refresh just now. Showing what we have.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.85))
                    Spacer()
                    Button("Retry") { Task { await vm.load() } }
                        .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint("Reloads the thread list")
                }
                .padding(.horizontal, Theme.spacingSM)
                .background(Theme.gold.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }

            if !vm.loaded && !vm.loadFailed {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.radius).fill(Color.white.opacity(0.08)).frame(height: 56)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading threads")
            }

            if vm.loaded && vm.threads.isEmpty && !vm.loadFailed {
                Text("No threads yet. Press and hold a message to start one.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(vm.threads) { thread in
                row(thread)
            }

            if vm.hasMore {
                Button {
                    Task { await vm.loadMore() }
                } label: {
                    Text(vm.moreFailed ? "Couldn't load more. Retry" : (vm.isLoadingMore ? "Loading…" : "Show more"))
                        .font(.inter(Theme.fontXS, weight: .semibold))
                        .foregroundColor(Theme.gold)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(vm.isLoadingMore)
                .accessibilityLabel(vm.moreFailed ? "Couldn't load more threads, retry" : "Show more threads")
            }
        }
        .task { await vm.load() }
        .accessibilityIdentifier("group-threads-section")
    }

    private func row(_ thread: FSThreadSummary) -> some View {
        Button {
            openThread?.run(thread)
        } label: {
            HStack(spacing: Theme.spacingSM) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.parchment)
                        .lineLimit(1)
                    Text(snippet(thread))
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                        .italic(thread.rootDeleted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(replyLabel(thread))
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textGoldMuted)
                    let when = FSMessageActionPolicy.relativeTime(thread.lastActivityAt)
                    if !when.isEmpty {
                        Text(when).font(.inter(Theme.fontXXS)).foregroundColor(Theme.textSecondary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(Theme.spacingSM)
            .frame(minHeight: 56)
            .background(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldFaint, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread.title). \(snippet(thread)). \(replyLabel(thread))")
        .accessibilityHint("Opens this thread")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("group-thread-row")
    }

    private func snippet(_ thread: FSThreadSummary) -> String {
        thread.rootDeleted ? "Original message deleted" : thread.rootPreview
    }

    private func replyLabel(_ thread: FSThreadSummary) -> String {
        thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies"
    }

    static let registration = GroupInfoExtraSection(
        id: "threads",
        order: 30,
        isVisible: { caps, _ in caps.isEnabled("threads") },
        makeView: { _, ctx in AnyView(GroupThreadsSection(context: ctx)) }
    )
}
