// BadgeCountsStore+Persistence.swift -- task 20261016-ipad-parity-and-persistent-badges.
// Per-user, on-device persistence for the badge reducer (BadgeState).
//
// Key: fs_badge_state_<userId> in UserDefaults (same store as the read markers).
// Payload: requester/group ids, counts and timestamps only. Hydrated
// synchronously at launch/sign-in so the first frame already shows the last
// known badges; replaced only by a proven server response or a seen event;
// removed on sign-out. An undecodable or wrong-version payload is dropped (it is
// a cache, never a source of truth).

import Foundation

extension BadgeCountsStore {

    static func persistenceKey(_ userId: String) -> String { "fs_badge_state_\(userId)" }

    /// Loads the persisted state for `userId` (or starts empty) and publishes it,
    /// including the last-known unread count. Replaces any previous user's state.
    func hydrate(userId: String) {
        guard !userId.isEmpty else { return }
        activeUserId = userId
        badgeState = Self.loadPersistedState(userId: userId) ?? BadgeState()
        publish()   // re-persisting the identical state is harmless
        owner?.unreadConversationCount = badgeState.unreadConversations
    }

    static func loadPersistedState(userId: String) -> BadgeState? {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey(userId)),
              let state = try? JSONDecoder().decode(BadgeState.self, from: data),
              state.version == BadgeState.currentVersion else { return nil }
        return state
    }

    func persistBadgeState() {
        guard let uid = owner?.currentUser?.user_id ?? activeUserId, !uid.isEmpty,
              owner?.isAuthenticated ?? false else { return }
        guard let data = try? JSONEncoder().encode(badgeState) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey(uid))
    }

    func wipePersistedBadgeState(forUserId userId: String?) {
        guard let userId, !userId.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey(userId))
    }
}
