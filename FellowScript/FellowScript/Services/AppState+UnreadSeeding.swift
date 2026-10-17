// AppState+UnreadSeeding.swift -- task 20261016-notification-badges-logic.
// Baseline seeding for the device-local last-read markers.
//
// Read state stays device-local (fs_last_read_timestamps). Without a baseline, a
// reinstall, a second device or a first launch would show every old conversation
// as unread. On the first SUCCESSFUL contacts load for a user (never on a failed
// load or a cache-only render) every conversation that has no marker gets one
// set to its current lastMessageAt, and the seed point is persisted per user.
// Seeding applies only when the device holds NO read markers at all (fresh install,
// reinstall, new device). A user who already has markers (an upgrader; markers have
// been persisted in UserDefaults since build 47) keeps real unread state for
// never-opened conversations.
// A conversation that shows up later with no marker is unread only if its newest
// message postdates the seed point (see AppState.hasUnread).

import Foundation

extension AppState {

    private static func unreadSeedKey(_ userId: String) -> String { "fs_last_read_seed_\(userId)" }

    /// The persisted seed point for the signed-in user, or nil if not seeded yet.
    var unreadSeedDate: Date? {
        guard let uid = currentUser?.user_id, !uid.isEmpty,
              let raw = UserDefaults.standard.string(forKey: Self.unreadSeedKey(uid)) else { return nil }
        return parseFlexibleISO8601(raw)
    }

    /// Seeds markers + the seed point once per user, and only when no read marker
    /// exists yet. `contacts` must come from a proven successful load. Returns
    /// true when seeding happened.
    @discardableResult
    func seedUnreadBaselineIfNeeded(contacts: [FSContact]) -> Bool {
        guard let uid = currentUser?.user_id, !uid.isEmpty,
              UserDefaults.standard.string(forKey: Self.unreadSeedKey(uid)) == nil,
              lastReadTimestamps.isEmpty else { return false }

        var timestamps = lastReadTimestamps
        var newest: (raw: String, date: Date)?
        for c in contacts {
            guard let d = parseFlexibleISO8601(c.lastMessageAt) else { continue }
            if timestamps[c.id] == nil { timestamps[c.id] = c.lastMessageAt }
            if newest == nil || d > newest!.date { newest = (c.lastMessageAt, d) }
        }
        lastReadTimestamps = timestamps

        // Seed point in server time (newest known message) so device clock skew
        // cannot hide or invent unread messages; device time only if there is none.
        let seedRaw = newest?.raw ?? ISO8601DateFormatter().string(from: Date())
        UserDefaults.standard.set(seedRaw, forKey: Self.unreadSeedKey(uid))
        return true
    }

    func clearUnreadSeed(forUserId userId: String) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.unreadSeedKey(userId))
    }
}
