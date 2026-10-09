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

    private var changeObserver: NSObjectProtocol?

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service
        self.groupId = groupId
        self.userId = userId
        // Keep every list for this group (info section, group-list dropdown)
        // consistent with renames/deletes made elsewhere or pushed by the WS.
        changeObserver = NotificationCenter.default.addObserver(
            forName: FSThreadChange.notification, object: nil, queue: .main) { [weak self] note in
            guard let change = FSThreadChange.from(note) else { return }
            Task { @MainActor in await self?.apply(change) }
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    /// Applies a rename/delete to the in-memory rows and the persisted cache.
    /// Idempotent; ignores other groups. Never touches load-failure state.
    func apply(_ change: FSThreadChange) async {
        guard change.groupId.lowercased() == groupId.lowercased() else { return }
        var next = threads
        switch change.kind {
        case .deleted:
            next.removeAll { $0.id == change.threadId }
        case .renamed(let title):
            guard let i = next.firstIndex(where: { $0.id == change.threadId }) else { return }
            next[i].title = title
        }
        guard next != threads else { return }
        threads = next
        if loaded { await DiskCache.shared.save(next, forKey: cacheKey) }
    }

    /// Throws on failure (the shown rows are untouched). A 404 on delete means
    /// the thread is already gone, so it is removed locally and reported as such.
    func rename(_ thread: FSThreadSummary, to raw: String) async throws {
        guard let title = FSThreadPolicy.validTitle(raw) else {
            throw FSThreadsError.failed("Use a title of 1 to \(FSThreadPolicy.titleMaxLength) characters.")
        }
        let updated = try await service.renameThread(userId: userId, groupId: groupId, threadId: thread.id, title: title)
        let newTitle = updated.title.isEmpty ? title : updated.title
        FSThreadChange(groupId: groupId, threadId: thread.id, kind: .renamed(newTitle)).post()
    }

    func delete(_ thread: FSThreadSummary) async throws {
        do {
            try await service.deleteThread(userId: userId, groupId: groupId, threadId: thread.id)
        } catch let e as FSThreadsError where e == .notFound {
            FSThreadChange(groupId: groupId, threadId: thread.id, kind: .deleted).post()
            throw e
        }
        FSThreadChange(groupId: groupId, threadId: thread.id, kind: .deleted).post()
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
    @EnvironmentObject private var appState: AppState
    @State private var renaming: FSThreadSummary?
    @State private var renameText = ""
    @State private var deleting: FSThreadSummary?
    @State private var actionError: String?
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 60

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

            if !vm.threads.isEmpty {
                // A non-scrolling List (same as Notes) so native swipeActions
                // work inside the sheet's ScrollView; height is rows * pitch.
                List {
                    ForEach(vm.threads) { thread in listRow(thread) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .environment(\.defaultMinListRowHeight, 1)
                .frame(height: CGFloat(vm.threads.count) * (rowHeight + Self.rowGap))
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
        .alert("Rename thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Thread title", text: $renameText)
            Button("Save") { if let t = renaming { submitRename(t) } }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Up to \(FSThreadPolicy.titleMaxLength) characters.")
        }
        .alert("Delete this thread?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let t = deleting { submitDelete(t) } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The thread and all its replies will be permanently deleted for everyone. This can't be undone.")
        }
        .alert("Thread", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .accessibilityIdentifier("group-threads-section")
    }

    // ── Rename / delete ───────────────────────────────────────────────────────
    private var username: String? { appState.currentUser?.username }
    private func canRename(_ t: FSThreadSummary) -> Bool { FSThreadPolicy.canRename(t, username: username) }
    private func canDelete(_ t: FSThreadSummary) -> Bool {
        FSThreadPolicy.canDelete(t, username: username, isOwner: context.isOwner)
    }

    private func startRename(_ t: FSThreadSummary) {
        renameText = t.title
        renaming = t
    }

    private func submitRename(_ t: FSThreadSummary) {
        renaming = nil
        Task {
            do { try await vm.rename(t, to: renameText) }
            catch let e as FSThreadsError where e == .notFound {
                actionError = "You can't rename that thread, or it no longer exists."
                await vm.load()
            }
            catch { actionError = (error as? LocalizedError)?.errorDescription ?? "Couldn't rename that thread." }
        }
    }

    private func submitDelete(_ t: FSThreadSummary) {
        deleting = nil
        Task {
            do { try await vm.delete(t) }
            catch let e as FSThreadsError where e == .notFound {
                actionError = "That thread is already gone."
            }
            catch { actionError = (error as? LocalizedError)?.errorDescription ?? "Couldn't delete that thread." }
        }
    }

    /// One List row. The list is the same native List + .swipeActions the Notes
    /// list uses (NotesListView+List.notesList), so the swipe looks and behaves
    /// identically: gold circular Delete action, full-swipe expansion, haptics,
    /// tap-to-close. Delete only asks for confirmation (alert) because a thread
    /// delete is permanent for everyone. Long-press menu and VoiceOver custom
    /// actions are the other ways in.
    @ViewBuilder
    private func listRow(_ thread: FSThreadSummary) -> some View {
        let deletable = canDelete(thread)
        let renamable = canRename(thread)
        row(thread)
            .modifier(ThreadRowAccessibilityActions(
                rename: renamable ? { startRename(thread) } : nil,
                delete: deletable ? { deleting = thread } : nil))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Self.rowGap / 2, leading: 0, bottom: Self.rowGap / 2, trailing: 0))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if deletable {
                    Button(role: .destructive) { deleting = thread } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .contextMenu {
                if renamable {
                    Button { startRename(thread) } label: { Label("Rename", systemImage: "pencil") }
                }
                if deletable {
                    Button(role: .destructive) { deleting = thread } label: { Label("Delete", systemImage: "trash") }
                }
            }
    }

    private static let rowGap: CGFloat = 8

    private func row(_ thread: FSThreadSummary) -> some View {
        // Tap gesture like the Notes rows (NotesListView+List).
        Group {
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
            .frame(height: rowHeight)
            .background(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldFaint, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .onTapGesture {
            openThread?.run(thread)
        }
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


/// VoiceOver alternatives to swipe and long-press; only offered when allowed.
private struct ThreadRowAccessibilityActions: ViewModifier {
    let rename: (() -> Void)?
    let delete: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        switch (rename, delete) {
        case let (r?, d?):
            content.accessibilityAction(named: "Rename thread", r).accessibilityAction(named: "Delete thread", d)
        case let (r?, nil):
            content.accessibilityAction(named: "Rename thread", r)
        case let (nil, d?):
            content.accessibilityAction(named: "Delete thread", d)
        default:
            content
        }
    }
}
