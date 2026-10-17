// NetworkService+BadgeSummaries.swift -- task 20261016-notification-badges-logic.
// Lightweight reads that feed the app-level BadgeCountsStore.
//
// Throw-not-fabricate: every call throws on a transport error, a non-2xx or an
// undecodable body, so the store keeps its last known counts instead of showing
// a zero or an invented number (preserve-cache-on-failed-refresh).

import Foundation

/// One owned group with at least one pending join request
/// (GET /join-requests/{user_id}/pending-summary). Counts only, no applicant data.
struct FSJoinRequestSummaryRow: Codable, Equatable {
    let groupId: String
    let pendingCount: Int

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case pendingCount = "pending_count"
    }
}

private struct JoinRequestSummaryBody: Decodable {
    let groups: [FSJoinRequestSummaryRow]
}

private struct FriendRequestCountRow: Decodable {
    let user_id: String
}

extension NetworkService {

    // GET /friends/{userId}/requests, counted. Unlike fetchFriendRequests, an
    // undecodable body throws rather than reading as "no requests".
    func fetchPendingFriendRequestCount(userId: String) async throws -> Int {
        let data = try await get("/friends/\(encodeURIComponent(userId))/requests")
        guard let rows = decode([FriendRequestCountRow].self, from: data,
                                endpoint: "/friends/{id}/requests") else {
            throw FSJoinRequestsError.failed("Couldn't load friend requests.")
        }
        return rows.count
    }

    // GET /join-requests/{userId}/pending-summary. Flag off for the caller
    // returns 200 with an empty list server-side (a real "none").
    func fetchPendingJoinSummary(userId: String) async throws -> [FSJoinRequestSummaryRow] {
        let data = try await get("/join-requests/\(encodeURIComponent(userId))/pending-summary")
        guard let body = decode(JoinRequestSummaryBody.self, from: data,
                                endpoint: "/join-requests/{id}/pending-summary") else {
            throw FSJoinRequestsError.failed("Couldn't load join request summary.")
        }
        return body.groups
    }
}

// Defaults so mocks and test doubles keep compiling.
extension DataServiceProtocol {
    func fetchPendingFriendRequestCount(userId: String) async throws -> Int {
        try await fetchFriendRequests(userId: userId).count
    }
    func fetchPendingJoinSummary(userId: String) async throws -> [FSJoinRequestSummaryRow] {
        throw FSJoinRequestsError.failed("Join requests aren't available right now.")
    }
}
