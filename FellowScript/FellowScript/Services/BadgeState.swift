// BadgeState.swift -- task 20261016-ipad-parity-and-persistent-badges (step 4).
// Pure reducer for the persisted notification badges. No UIKit, no I/O.
//
// Three facts per badge: what EXISTS (server snapshot), what the user has SEEN
// (device watermark), and the last-known display value. Displayed badge =
// exists AND unseen.
//   * A server snapshot only ever replaces the "exists" side (and prunes seen
//     entries that no longer exist). It can neither resurrect a seen item nor
//     hide an unseen one.
//   * A seen event only ever adds to the "seen" side.
//   * A failed refresh never reaches this type (callers apply a snapshot only
//     on a proven response). An empty snapshot is a proven "none" and clears.
// Payload is ids, counts and timestamps only: no applicant data, no secrets.

import Foundation

struct BadgeState: Codable, Equatable {

    struct JoinEntry: Codable, Equatable {
        var count: Int
        /// `newest_request_at` from pending-summary (UTC ISO-8601, 6-digit
        /// microseconds, trailing Z, so string order is chronological). nil when
        /// the server did not send it.
        var newest: String?
    }

    static let currentVersion = 1

    var version = BadgeState.currentVersion
    /// Pending incoming friend requests (requester user ids), last proven.
    var friendPending: Set<String> = []
    /// Subset of requester ids the user has already seen.
    var friendSeen: Set<String> = []
    /// Owned groups with pending join requests, last proven.
    var joinSummary: [String: JoinEntry] = [:]
    /// groupId -> newest_request_at the owner had seen ("" = seen, no timestamp).
    var joinSeen: [String: String] = [:]
    /// Last-known unread conversation count (display hydrate only).
    var unreadConversations = 0

    // MARK: Displayed values

    var unseenFriendRequestCount: Int { friendPending.subtracting(friendSeen).count }

    /// groupId -> pending count, only for groups whose newest request is unseen.
    var unseenJoinCounts: [String: Int] {
        var out: [String: Int] = [:]
        for (gid, e) in joinSummary where e.count > 0 && isUnseen(gid, e) { out[gid] = e.count }
        return out
    }

    private func isUnseen(_ groupId: String, _ e: JoinEntry) -> Bool {
        guard let watermark = joinSeen[groupId] else { return true }
        guard let newest = e.newest else { return false }   // seen, and the server gave no newer marker
        return newest > watermark
    }

    // MARK: Friend requests

    /// Proven list of pending requester ids (HTTP 200, decoded). Empty clears.
    mutating func applyFriendSnapshot(_ ids: Set<String>) {
        friendPending = ids
        friendSeen.formIntersection(ids)
    }

    /// The user is looking at a successfully loaded friend-request list.
    mutating func markFriendRequestsSeen(_ ids: Set<String>) {
        applyFriendSnapshot(ids)   // the list on screen is itself a proven snapshot
        friendSeen.formUnion(ids)
    }

    // MARK: Join requests

    /// Proven pending-summary rows. Rows with a zero count are not stored.
    mutating func applyJoinSnapshot(_ rows: [FSJoinRequestSummaryRow]) {
        var next: [String: JoinEntry] = [:]
        for r in rows where r.pendingCount > 0 {
            next[r.groupId] = JoinEntry(count: r.pendingCount, newest: r.newestRequestAt)
        }
        joinSummary = next
        joinSeen = joinSeen.filter { next[$0.key] != nil }
    }

    /// The owner is looking at a successfully loaded Join requests list for one
    /// group. `newestRequestAt` is the newest created_at in that list, if known.
    mutating func markJoinRequestsSeen(groupId: String, pendingCount: Int, newestRequestAt: String?) {
        guard pendingCount > 0 else {
            joinSummary[groupId] = nil
            joinSeen[groupId] = nil
            return
        }
        let newest = [joinSummary[groupId]?.newest, newestRequestAt].compactMap { $0 }.max()
        joinSummary[groupId] = JoinEntry(count: pendingCount, newest: newest)
        joinSeen[groupId] = max(joinSeen[groupId] ?? "", newest ?? "")
    }

    /// A count the screen proved (approve / deny / undo) without a viewing event.
    mutating func setJoinCount(groupId: String, _ count: Int) {
        if count <= 0 {
            joinSummary[groupId] = nil
            joinSeen[groupId] = nil
        } else {
            joinSummary[groupId] = JoinEntry(count: count, newest: joinSummary[groupId]?.newest)
        }
    }
}
