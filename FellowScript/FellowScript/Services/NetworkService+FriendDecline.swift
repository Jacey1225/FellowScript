// NetworkService+FriendDecline.swift (task 20261030-profile-everywhere)
// Decline an incoming friend request.
//
// POST /friends/{userId}/requests/{senderId}/decline -> 204 always (the server
// answers the same whether or not a request existed, so it cannot be probed).
// 429 maps to AppError.rateLimited via the shared request path. Throw-not-
// fabricate: every failure throws; the caller keeps the request on screen.

import Foundation

extension DataServiceProtocol {
    func declineFriendRequest(userId: String, senderId: String) async throws {
        throw AppError.networkError("Friend requests aren't available right now.")
    }
}

extension NetworkService {
    func declineFriendRequest(userId: String, senderId: String) async throws {
        _ = try await request("/friends/\(encodeURIComponent(userId))/requests/\(encodeURIComponent(senderId))/decline",
                              method: "POST")
    }
}
