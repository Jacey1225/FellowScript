// Notes/HighlightSearchModel.swift — state for the Highlights-tab search
// (task 20260909-highlight-search). A standalone model (not NotesViewModel
// stored properties) so the notes view-model doesn't grow; it never touches
// vm.highlights, so a failed search can't wipe the cached highlight list, and
// clearing the query just drops back to that untouched list.

import SwiftUI
import Combine

@MainActor
final class HighlightSearchModel: ObservableObject {
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            schedule()
        }
    }
    @Published private(set) var results: [FSHighlightSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var hasMore = false

    private var cursor: FSHighlightSearchPage? = nil
    private var task: Task<Void, Never>? = nil
    private var service: DataServiceProtocol = MockDataService.shared
    private var userId = ""
    private var generation = 0
    private static let debounceNanoseconds: UInt64 = 300_000_000
    // Backend rejects queries over 100 chars (422); clamp client-side.
    static let maxQueryLength = 100

    var trimmedQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { !trimmedQuery.isEmpty }

    deinit { task?.cancel() }

    func configure(service: DataServiceProtocol, userId: String) {
        self.service = service
        self.userId = userId
    }

    func clear() {
        searchText = ""   // didSet -> schedule() resets state
    }

    private func reset() {
        task?.cancel()
        generation += 1
        results = []
        cursor = nil
        hasMore = false
        errorMessage = nil
        isSearching = false
        isLoadingMore = false
    }

    private func schedule() {
        reset()
        guard isActive, !userId.isEmpty else { return }
        let gen = generation
        let q = String(trimmedQuery.prefix(Self.maxQueryLength))
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.run(query: q, generation: gen)
        }
    }

    private func run(query: String, generation gen: Int) async {
        isSearching = true
        defer { if gen == generation { isSearching = false } }
        do {
            let page = try await service.searchHighlights(userId: userId, query: query, limit: nil,
                                                          cursorTimestamp: nil, cursorId: nil, cursorKey: nil)
            guard gen == generation, !Task.isCancelled else { return }
            results = page.results
            cursor = page
            hasMore = page.hasMore
            errorMessage = nil
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            results = []
            errorMessage = "Couldn\u{2019}t search highlights. Check your connection and try again."
        }
    }

    func retry() {
        schedule()
    }

    func loadMoreIfNeeded(current: FSHighlightSearchResult) {
        guard hasMore, !isLoadingMore, !isSearching, current.id == results.last?.id,
              let c = cursor else { return }
        let gen = generation
        let q = String(trimmedQuery.prefix(Self.maxQueryLength))
        isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.service.searchHighlights(
                    userId: self.userId, query: q, limit: nil,
                    cursorTimestamp: c.cursorTimestamp, cursorId: c.cursorId, cursorKey: c.cursorKey)
                guard gen == self.generation else { return }
                let seen = Set(self.results.map(\.id))
                self.results += page.results.filter { !seen.contains($0.id) }
                self.cursor = page
                self.hasMore = page.hasMore
            } catch {
                // Keep what's shown; stop paging until the query changes.
                if gen == self.generation { self.hasMore = false }
            }
            if gen == self.generation { self.isLoadingMore = false }
        }
    }
}
