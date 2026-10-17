// BadgeCountsStore.swift -- task 20261016-notification-badges-logic.
// App-level source of truth for notification badges, independent of which tab is
// on screen:
//   * unread conversations: still AppState.unreadConversationCount, but now
//     recomputed here from the shared ChatViewModel (not from ChatRootView);
//   * pending incoming friend requests (Account tab numeral);
//   * pending join requests per owned group (group-row dot, Chat tab count).
//
// Throw-not-fabricate / preserve-cache-on-failed-refresh: a failed fetch never
// changes a count. Counts are only replaced by a proven successful response.
// Sign-out calls clear() and invalidates in-flight refreshes.
//
// Task 20261016-ipad-parity-and-persistent-badges: the published counts are the
// UNSEEN counts, derived from a pure reducer (BadgeState) that is persisted per
// user (BadgeCountsStore+Persistence.swift) and hydrated before the first frame.
// Server snapshots replace "what exists"; seen events add to "what was seen".

import Foundation
import Combine

@MainActor
final class BadgeCountsStore: ObservableObject {

    /// Pending friend requests the user has not yet seen.
    @Published private(set) var pendingFriendRequestCount = 0
    /// groupId -> unseen pending join requests (owned groups only; zeros are not stored).
    @Published private(set) var joinRequestCounts: [String: Int] = [:]

    /// Reducer state (ids / watermarks). Persisted per user after every change.
    var badgeState = BadgeState()
    /// User the persisted state belongs to (set by hydrate / first refresh).
    var activeUserId: String?
    /// True once this session has a proven contacts load; before that the
    /// persisted unread count is kept unless a real (non-empty) list exists.
    private var contactsProven = false

    weak var owner: AppState?
    private weak var chatVM: ChatViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var generation = 0
    private var requestsInFlight = false
    private var lastForegroundRefresh = Date.distantPast

    /// Minimum gap between foreground-triggered refreshes.
    static let foregroundThrottle: TimeInterval = 5

    // MARK: Derived

    /// Owned groups with at least one pending request (each group counted once).
    var pendingJoinRequestGroupCount: Int { joinRequestCounts.values.filter { $0 > 0 }.count }

    func joinRequestCount(forGroup groupId: String) -> Int { joinRequestCounts[groupId] ?? 0 }

    /// The single Chat tab number: unread conversations + groups with join requests.
    func chatBadgeCount(unreadConversations: Int) -> Int {
        unreadConversations + pendingJoinRequestGroupCount
    }

    /// VoiceOver text for the Chat tab, e.g. "3 unread conversations, 1 join request".
    static func chatAccessibilitySummary(unreadConversations: Int, joinRequestGroups: Int) -> String? {
        var parts: [String] = []
        if unreadConversations > 0 {
            parts.append(unreadConversations == 1 ? "1 unread conversation" : "\(unreadConversations) unread conversations")
        }
        if joinRequestGroups > 0 {
            parts.append(joinRequestGroups == 1 ? "1 join request" : "\(joinRequestGroups) groups with join requests")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func friendRequestAccessibilitySummary(_ count: Int) -> String? {
        count > 0 ? (count == 1 ? "1 friend request" : "\(count) friend requests") : nil
    }

    // MARK: Wiring

    /// Subscribes to the shared ChatViewModel so unread is recomputed from the
    /// moment contacts load, whichever tab is visible. Seeds the read baseline
    /// only on a proven successful contacts load (ChatViewModel.contactsSyncVersion).
    func attach(chatVM: ChatViewModel) {
        cancellables.removeAll()
        self.chatVM = chatVM
        contactsProven = false
        lastForegroundRefresh = Date()   // the startup load counts as a refresh

        Publishers.CombineLatest(chatVM.$friends, chatVM.$groups)
            .sink { [weak self] friends, groups in self?.recomputeUnread(friends + groups) }
            .store(in: &cancellables)

        chatVM.$contactsSyncVersion
            .dropFirst()
            .sink { [weak self, weak chatVM] _ in
                guard let self, let chatVM else { return }
                let contacts = chatVM.friends + chatVM.groups
                self.contactsProven = true
                self.owner?.seedUnreadBaselineIfNeeded(contacts: contacts)
                self.recomputeUnread(contacts)
            }
            .store(in: &cancellables)

        owner?.$lastReadVersion
            .sink { [weak self, weak chatVM] _ in
                guard let self, let chatVM else { return }
                self.recomputeUnread(chatVM.friends + chatVM.groups)
            }
            .store(in: &cancellables)
    }

    /// Before a proven contacts load, an empty list is "not loaded yet", not
    /// "no conversations": it must not zero the persisted count (preserve-cache).
    private func recomputeUnread(_ contacts: [FSContact]) {
        guard contactsProven || !contacts.isEmpty else { return }
        owner?.recomputeUnreadConversationCount(contacts: contacts)
        if let n = owner?.unreadConversationCount { noteUnreadCount(n) }
    }

    // MARK: Refresh

    /// Launch / login: friend-request and join-request counts. Contacts are
    /// loaded by StartupCoordinator.
    func refreshRequests() async {
        guard let owner, owner.isAuthenticated, let uid = owner.currentUser?.user_id, !uid.isEmpty,
              !requestsInFlight else { return }
        requestsInFlight = true
        let gen = generation
        if activeUserId != uid { activeUserId = uid }
        let service = owner.service
        defer { requestsInFlight = false }

        async let friends = Self.attempt { try await service.fetchPendingFriendRequestIds(userId: uid) }
        async let joins   = Self.attempt { try await service.fetchPendingJoinSummary(userId: uid) }
        let (friendIds, joinRows) = await (friends, joins)

        // Drop results from a signed-out or replaced session.
        guard gen == generation, owner.currentUser?.user_id == uid else { return }
        // Only a proven response changes state; an empty one is a real "none".
        if let friendIds { badgeState.applyFriendSnapshot(Set(friendIds)) }
        if let joinRows { badgeState.applyJoinSnapshot(joinRows) }
        if friendIds != nil || joinRows != nil { publish() }
    }

    /// Every return to the foreground (throttled): refresh contacts (so unread is
    /// current) and the request counts. A failed contacts refresh keeps the
    /// existing lists (ChatViewModel only splices in a proven success).
    func refreshForeground(capabilities: FSCapabilities, force: Bool = false) async {
        guard let owner, owner.isAuthenticated, let uid = owner.currentUser?.user_id, !uid.isEmpty else { return }
        if !force, Date().timeIntervalSince(lastForegroundRefresh) < Self.foregroundThrottle {
            return
        }
        lastForegroundRefresh = Date()
        if let chatVM {
            chatVM.capabilities = capabilities
            await chatVM.refresh(service: owner.service, userId: uid)
        }
        await refreshRequests()
    }

    // MARK: Action hooks (screens report a state they already proved)

    /// Legacy count-only hook (no ids available): treats the count as proven
    /// and unseen. The app itself reports ids via friendRequestsViewed.
    func setFriendRequestCount(_ count: Int) {
        let c = max(0, count)
        guard c != badgeState.unseenFriendRequestCount else { return }
        badgeState.friendSeen = []
        badgeState.friendPending = Set((0..<c).map { "count-\($0)" })
        publish()
    }

    func setJoinRequestCount(groupId: String, _ count: Int) {
        badgeState.setJoinCount(groupId: groupId, count)
        publish()
    }

    // MARK: Seen events (a screen reports what the user is looking at)

    /// The Account screen is on screen with a successfully loaded friend-request
    /// list (`ids` = requester ids). Marks them seen; a later new id re-raises.
    func friendRequestsViewed(ids: [String]) {
        badgeState.markFriendRequestsSeen(Set(ids))
        publish()
    }

    /// The owner has a group's Join requests list on screen, successfully loaded.
    func joinRequestsViewed(groupId: String, pendingCount: Int, newestRequestAt: String?) {
        badgeState.markJoinRequestsSeen(groupId: groupId, pendingCount: pendingCount,
                                        newestRequestAt: newestRequestAt)
        publish()
    }

    /// Recomputes the published unseen counts from the reducer and persists it.
    func publish() {
        let friends = badgeState.unseenFriendRequestCount
        let joins = badgeState.unseenJoinCounts
        if friends != pendingFriendRequestCount { pendingFriendRequestCount = friends }
        if joins != joinRequestCounts { joinRequestCounts = joins }
        persistBadgeState()
    }

    func noteUnreadCount(_ n: Int) {
        guard badgeState.unreadConversations != n else { return }
        badgeState.unreadConversations = n
        persistBadgeState()
    }

    /// Sign-out: drop everything and invalidate in-flight refreshes.
    /// Also wipes the persisted state for the signed-out user.
    func clear(forUserId userId: String? = nil) {
        generation += 1
        cancellables.removeAll()
        chatVM = nil
        contactsProven = false
        wipePersistedBadgeState(forUserId: userId ?? activeUserId)
        activeUserId = nil
        badgeState = BadgeState()
        pendingFriendRequestCount = 0
        joinRequestCounts = [:]
        lastForegroundRefresh = .distantPast
    }

    // MARK: Helpers

    static func counts(from rows: [FSJoinRequestSummaryRow]) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in rows where r.pendingCount > 0 { out[r.groupId] = r.pendingCount }
        return out
    }


    /// nil on any failure (the caller then keeps its last known value).
    private static func attempt<T>(_ body: () async throws -> T) async -> T? {
        try? await body()
    }
}

extension AppState {
    /// Foreground hook (FellowScriptApp scenePhase .active).
    func refreshBadgesOnForeground() {
        Task { [weak self] in
            guard let self else { return }
            await self.badges.refreshForeground(capabilities: self.capabilities)
        }
    }

    /// Launch / login hook (StartupCoordinator.start).
    func refreshBadgeRequests() {
        Task { [weak self] in await self?.badges.refreshRequests() }
    }
}

// MARK: - Row helpers

extension AppState {
    /// "<base>, unread messages, 2 pending join requests" -- one label so the dots
    /// are not separate accessible elements.
    func rowAccessibilityLabel(_ base: String, contact: FSContact) -> String {
        var label = base
        if hasUnread(contact) { label += ", unread messages" }
        if contact.type == .group {
            let n = badges.joinRequestCount(forGroup: contact.id)
            if n > 0 { label += n == 1 ? ", 1 pending join request" : ", \(n) pending join requests" }
        }
        return label
    }
}
