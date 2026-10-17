// PushRouting+Social.swift -- task 20261016-push-notifications-and-ui.
// Tap routing for the always-on social pushes. Payloads carry identifiers only
// (`action` plus `group_id`); anything malformed stays inert.

import Foundation

extension Notification.Name {
    static let friendRequestPushTapped = Notification.Name("friendRequestPushTapped")
    static let groupMembershipPushTapped = Notification.Name("groupMembershipPushTapped")
}

/// `action: "join_request"` or `"member_joined"` with a non-empty `group_id`.
struct GroupMembershipPushTarget: Equatable {
    enum Kind: Equatable { case joinRequest, memberJoined }
    let kind: Kind
    let groupId: String

    init?(userInfo: [AnyHashable: Any]) {
        guard let action = userInfo["action"] as? String,
              let gid = userInfo["group_id"] as? String, !gid.isEmpty, gid.count <= 128 else { return nil }
        switch action {
        case "join_request": kind = .joinRequest
        case "member_joined": kind = .memberJoined
        default: return nil
        }
        groupId = gid
    }
}

enum SocialPushRouting {
    /// Posts the matching notification. Returns true when the payload was handled.
    @discardableResult
    static func route(userInfo: [AnyHashable: Any]) -> Bool {
        let action = userInfo["action"] as? String
        if action == "friend_request" {
            NotificationCenter.default.post(name: .friendRequestPushTapped, object: nil)
            return true
        }
        if let target = GroupMembershipPushTarget(userInfo: userInfo) {
            NotificationCenter.default.post(name: .groupMembershipPushTapped, object: target)
            return true
        }
        return false
    }
}

extension AppState {
    func handleGroupMembershipPush(_ target: GroupMembershipPushTarget) {
        if target.kind == .joinRequest { pendingGroupInfoOpen = target.groupId }
        openSession(groupId: target.groupId)
    }
}
