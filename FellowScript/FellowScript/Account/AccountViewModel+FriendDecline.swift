// AccountViewModel+FriendDecline.swift (task 20261030-profile-everywhere)
// Decline for the Account "Friend Requests" rows. Mirrors acceptRequest: the row
// leaves the list at once, and a failed decline puts it back with the warm error
// (never a silent vanish while the server still holds the request).

import Foundation

extension AccountViewModel {
    static let declineFailureMessage = "Couldn't decline that right now. Please try again."

    func declineRequest(senderId: String) async {
        guard let uid = profileData?.user_id else { return }
        let previous = friendRequests
        friendRequests.removeAll { $0.id == senderId }
        do {
            try await service.declineFriendRequest(userId: uid, senderId: senderId)
        } catch {
            friendRequests = previous
            if case AppError.rateLimited = error {
                friendMsg = "Slow down a little and try again in a moment."
            } else {
                friendMsg = Self.declineFailureMessage
            }
        }
    }
}
