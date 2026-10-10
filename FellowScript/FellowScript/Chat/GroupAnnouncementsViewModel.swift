// GroupAnnouncementsViewModel.swift — state for the Announcements sub-view of
// the group info sheet (task 20260929-group-announcements, design-notes.md).
//
// Failure behavior (throw-not-fabricate, preserve-cache-on-failed-refresh):
// every network call throws; a failed refresh keeps the cached list and sets
// `refreshFailed` rather than blanking it; delete is the one deferred-optimistic
// action (row hidden for an 8s undo window, restored if the server rejects).

import SwiftUI
import Combine

@MainActor
final class GroupAnnouncementsViewModel: ObservableObject {
    static let undoSeconds: UInt64 = 8

    let groupId: String
    let userId:  String
    private let service: GroupAnnouncementsService?

    @Published var items: [FSGroupAnnouncement] = []
    @Published var gate: FSAnnouncementGate?
    @Published var truncated = false
    @Published var loaded = false
    @Published var loading = false
    @Published var refreshFailed = false
    @Published var loadError: String?
    @Published var notice: String?
    @Published var removedFromGroup = false
    @Published private(set) var hiddenIds: Set<String> = []
    @Published var undoItem: FSGroupAnnouncement?

    private var pending: [String: (task: Task<Void, Never>, item: FSGroupAnnouncement)] = [:]

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service as? GroupAnnouncementsService
        self.groupId = groupId
        self.userId  = userId
    }

    private var cacheKey: String { "groupannouncements_\(userId)_\(groupId)" }

    private func svc() throws -> GroupAnnouncementsService {
        guard let service else { throw AppError.networkError("Announcements aren't available right now.") }
        return service
    }

    private func isNotMember(_ error: Error) -> Bool {
        if case AppError.networkError(let m) = error { return m.localizedCaseInsensitiveContains("not a member") }
        return false
    }

    private func message(_ error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }

    var visibleItems: [FSGroupAnnouncement] { items.filter { !hiddenIds.contains($0.id) } }
    var scheduledItems: [FSGroupAnnouncement] { visibleItems.filter { !$0.published } }
    var publishedItems: [FSGroupAnnouncement] { visibleItems.filter { $0.published } }
    /// True when the server says the free limit is used up (UX pre-check only;
    /// the server 403 is the source of truth).
    var limitReached: Bool { gate?.allowed == false }

    private func apply(_ page: FSAnnouncementsPage) {
        items = page.announcements
        gate = page.gate
        truncated = page.truncated ?? false
        loaded = true
    }

    private func persist() async {
        await DiskCache.shared.save(FSAnnouncementsPage(announcements: items, truncated: truncated, gate: gate), forKey: cacheKey)
    }

    // Cached first, then refresh. A failed refresh keeps whatever is cached.
    func load() async {
        if !loaded, let cached = await DiskCache.shared.load(FSAnnouncementsPage.self, forKey: cacheKey) { apply(cached) }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let page = try await svc().fetchAnnouncements(userId: userId, groupId: groupId)
            apply(page)
            refreshFailed = false
            await persist()
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else if loaded { refreshFailed = true }
            else { loadError = "Couldn't load announcements." }
        }
    }

    /// Create or update. Throws so the form can keep its content and show the
    /// right message; `.limitReached` also refreshes the local gate.
    func save(_ draft: FSAnnouncementDraft, editing: FSGroupAnnouncement?) async throws -> FSGroupAnnouncement {
        do {
            let saved: FSGroupAnnouncement
            if let editing {
                saved = try await svc().updateAnnouncement(userId: userId, groupId: groupId, announcementId: editing.id, draft: draft)
                if let idx = items.firstIndex(where: { $0.id == saved.id }) { items[idx] = saved }
            } else {
                saved = try await svc().createAnnouncement(userId: userId, groupId: groupId, draft: draft)
                items.insert(saved, at: 0)
            }
            await persist()
            if editing == nil { Task { await load() } }   // refresh gate/usage
            return saved
        } catch {
            if case AppError.limitReached(_, let used, let limit) = error {
                gate = FSAnnouncementGate(allowed: false, unlimited: false, used: used, limit: limit, remaining: 0)
            } else if isNotMember(error) {
                removedFromGroup = true
            } else if case AppError.networkError(let m) = error, m.localizedCaseInsensitiveContains("not found") {
                notice = "That announcement is no longer available."
                Task { await load() }
            }
            throw error
        }
    }

    func uploadBanner(data: Data, contentType: String) async throws -> String {
        try await svc().uploadAnnouncementBanner(userId: userId, groupId: groupId, data: data, contentType: contentType)
    }

    /// RSVP join / leave. Throws so the detail view can roll its optimistic
    /// count back; on success the cached item is replaced with the fresh one.
    func rsvp(_ item: FSGroupAnnouncement, join: Bool) async throws -> FSGroupAnnouncement {
        do {
            let updated = try await svc().rsvpAnnouncement(userId: userId, groupId: groupId, announcementId: item.id, join: join)
            if let idx = items.firstIndex(where: { $0.id == updated.id }) { items[idx] = updated }
            await persist()
            return updated
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            throw error
        }
    }

    // ── Delete with undo grace ───────────────────────────────────────────────
    func startDelete(_ item: FSGroupAnnouncement) {
        commitPendingDeletes()          // one grace window at a time
        notice = nil
        hiddenIds.insert(item.id)
        undoItem = item
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.undoSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.finishDelete(item)
        }
        pending[item.id] = (task, item)
    }

    func undoDelete() {
        guard let item = undoItem else { return }
        pending[item.id]?.task.cancel()
        pending[item.id] = nil
        hiddenIds.remove(item.id)
        undoItem = nil
    }

    /// Commits every grace-period delete now (a new delete started, or the
    /// view closed): not pressing Undo means the delete stands.
    func commitPendingDeletes() {
        let all = pending.values.map { $0.item }
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
        for item in all { Task { await finishDelete(item) } }
    }

    private func finishDelete(_ item: FSGroupAnnouncement) async {
        pending[item.id] = nil
        do {
            try await svc().deleteAnnouncement(userId: userId, groupId: groupId, announcementId: item.id)
            items.removeAll { $0.id == item.id }
            hiddenIds.remove(item.id)
            await persist()
        } catch {
            hiddenIds.remove(item.id)     // restore the row
            if isNotMember(error) { removedFromGroup = true }
            else if case AppError.networkError(let m) = error, m.localizedCaseInsensitiveContains("not found") {
                notice = "That announcement is no longer available."
                await load()
            } else {
                notice = "That announcement couldn't be deleted. Please try again."
            }
        }
        if undoItem?.id == item.id { undoItem = nil }
    }
}
