// GroupMediaViewModel.swift -- task 20261023-group-info-row. State for the
// Media grid in the group info submenu. Keyset paging (30 per page), in-memory
// cache while the chat is open (presigned URLs expire, so nothing is persisted),
// preserve-cache-on-failed-refresh, throw-not-fabricate.

import SwiftUI
import Combine

@MainActor
final class GroupMediaViewModel: ObservableObject {
    @Published private(set) var items: [FSGroupMediaItem] = []
    @Published private(set) var loaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    /// First load / refresh failed (items, if any, are kept).
    @Published private(set) var loadFailed = false
    @Published private(set) var moreFailed = false
    @Published private(set) var hasMore = false
    private var cursor: FSGroupMediaCursor?

    private let service: GroupMediaService?
    private let groupId: String
    private let userId: String

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service as? GroupMediaService
        self.groupId = groupId
        self.userId = userId
    }

    private func cursor(from page: FSGroupMediaPage) -> FSGroupMediaCursor? {
        guard page.hasMore, let ts = page.cursorTimestamp, let id = page.cursorId else { return nil }
        return FSGroupMediaCursor(timestamp: ts, seq: page.cursorSeq, id: id)
    }

    /// First open shows the spinner; later opens refresh quietly under the cached grid.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            guard let service else { throw AppError.networkError("Media isn't available right now.") }
            let page = try await service.fetchGroupMedia(userId: userId, groupId: groupId,
                                                         limit: FSGroupMediaLayout.pageSize, cursor: nil)
            items = page.items
            hasMore = page.hasMore && cursor(from: page) != nil
            cursor = cursor(from: page)
            loaded = true
            moreFailed = false
        } catch {
            loadFailed = true
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, let next = cursor else { return }
        isLoadingMore = true
        moreFailed = false
        defer { isLoadingMore = false }
        do {
            guard let service else { throw AppError.networkError("Media isn't available right now.") }
            let page = try await service.fetchGroupMedia(userId: userId, groupId: groupId,
                                                         limit: FSGroupMediaLayout.pageSize, cursor: next)
            let have = Set(items.map(\.id))
            items += page.items.filter { !have.contains($0.id) }
            hasMore = page.hasMore && cursor(from: page) != nil
            cursor = cursor(from: page)
        } catch {
            moreFailed = true
        }
    }
}
