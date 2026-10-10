// FriendHighlightPushSection.swift -- task 20261010-reaction-highlight-push.
// Account-tab toggle for "friend highlight" pushes (GET/PUT
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

struct FriendHighlightPushSection: View {
    @StateObject private var model: FriendHighlightPushModel

    init(service: DataServiceProtocol, userId: String) {
        _model = StateObject(wrappedValue: FriendHighlightPushModel(service: service, userId: userId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("NOTIFICATIONS")
                .font(.inter(Theme.fontXS, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .accessibilityAddTraits(.isHeader)
            Toggle(isOn: Binding(get: { model.enabled },
                                 set: { v in Task { await model.set(v) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Friend highlights")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Text("Notify me when a friend highlights a verse")
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .tint(Theme.gold)
            .disabled(!model.loaded || model.saving)
            .accessibilityLabel("Friend highlight notifications")
            .accessibilityHint("Turns notifications for friends' verse highlights on or off")
            if let msg = model.errorMessage {
                Text(msg)
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(.red)
                    .accessibilityLabel(msg)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
        .task { await model.load() }
    }
}
