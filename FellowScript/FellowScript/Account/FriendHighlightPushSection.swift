// FriendHighlightPushSection.swift -- task 20261010-reaction-highlight-push.
// Model for the (now superseded by NotificationSettingsView, task
// 20261012-notification-settings) Account-tab toggle for "friend highlight" pushes (GET/PUT
// /notification/{id}/push-preferences). Rendered only when the server's
// `friend_highlight_push` capability is on (AccountView+Misc.swift), so it is
// hidden while the flag is off. Throw-not-fabricate: the switch only shows the
// server-confirmed value; a failed save reverts and shows an inline error.

import SwiftUI
import Combine

@MainActor
final class FriendHighlightPushModel: ObservableObject {
    @Published private(set) var enabled = true
    @Published private(set) var loaded = false
    @Published private(set) var saving = false
    @Published var errorMessage: String?

    private let service: DataServiceProtocol
    private let userId: String

    init(service: DataServiceProtocol, userId: String) {
        self.service = service
        self.userId = userId
    }

    func load() async {
        guard !userId.isEmpty else { return }
        if let v = try? await service.fetchFriendHighlightPush(userId: userId) {
            enabled = v
            loaded = true
            errorMessage = nil
        } else if !loaded {
            errorMessage = "Couldn't load this setting."
        }
    }

    func set(_ newValue: Bool) async {
        guard loaded, !saving, newValue != enabled, !userId.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            try await service.setFriendHighlightPush(userId: userId, enabled: newValue)
            enabled = newValue
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save. Please try again."
        }
    }
}
