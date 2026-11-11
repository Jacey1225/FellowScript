// ChatAnnouncementEnvironment.swift -- task 20261030-chat-announcements.
// The group id the announcement timeline rows belong to, set once on the message
// list by ChatThreadView (nil in DMs and threads, where the row never renders a
// card). Kept as an environment value so MessageGroupRow's signature is unchanged.

import SwiftUI

private struct ChatAnnouncementGroupIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var chatAnnouncementGroupId: String? {
        get { self[ChatAnnouncementGroupIdKey.self] }
        set { self[ChatAnnouncementGroupIdKey.self] = newValue }
    }
}
