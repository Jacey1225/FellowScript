// NotificationSettingsView.swift -- task 20261012-notification-settings.
// Account > Notification settings: one switch per user-toggleable push type
// (GET/PUT /notification/{id}/push-preferences, default on server-side).
// Throw-not-fabricate: switches show only server-confirmed values; a failed
// save leaves the confirmed value and shows an inline error. Types behind a
// server flag are hidden while the capability is off. Essential pushes (incoming
// call ring, join-request approval) are not listed: the server never lets them
// be switched off.

import SwiftUI
import Combine

struct NotificationPushType: Equatable, Identifiable {
    let key: String
    let label: String
    let detail: String
    /// /app/capabilities feature that must be on for this type to show (nil = always).
    let flag: String?
    var id: String { key }

    static let all: [NotificationPushType] = groups.flatMap { $0.types }

    static let groups: [(title: String, types: [NotificationPushType])] = [
        ("Chat", [
            .init(key: "messages", label: "Messages", detail: "New chat messages and thread replies.", flag: nil),
            .init(key: "pins", label: "Pinned messages", detail: "When someone pins a message.", flag: "message_pins"),
            .init(key: "reactions", label: "Reactions", detail: "When someone reacts to your message.", flag: "message_reaction_push"),
            .init(key: "announcements", label: "Announcements", detail: "Group announcements, including heads-ups before they publish.", flag: nil),
        ]),
        ("Groups and sessions", [
            .init(key: "session_reminders", label: "Session reminders", detail: "New sessions and sessions that are starting.", flag: nil),
            .init(key: "join_requests", label: "Join requests", detail: "When someone asks to join a group you own.", flag: "join_request_push"),
        ]),
        ("Friends and reminders", [
            .init(key: "friend_highlight", label: "Friend highlights", detail: "When a friend highlights a verse.", flag: "friend_highlight_push"),
            .init(key: "friend_activity", label: "Friend activity", detail: "When a friend is active again, and friend nudges.", flag: nil),
            .init(key: "reminders", label: "Gentle reminders", detail: "Daily nudges and your scheduled devotion events.", flag: nil),
        ]),
    ]

    /// Groups with capability-gated types removed and empty groups dropped.
    static func visibleGroups(capabilities: FSCapabilities) -> [(title: String, types: [NotificationPushType])] {
        groups.compactMap { g in
            let t = g.types.filter { $0.flag == nil || capabilities.isEnabled($0.flag!) }
            return t.isEmpty ? nil : (g.title, t)
        }
    }
}

@MainActor
final class NotificationPreferencesModel: ObservableObject {
    @Published private(set) var prefs: [String: Bool] = [:]
    @Published private(set) var loaded = false
    @Published private(set) var savingKey: String?
    @Published var errorMessage: String?

    private let service: DataServiceProtocol
    private let userId: String

    init(service: DataServiceProtocol, userId: String) {
        self.service = service
        self.userId = userId
    }

    func load() async {
        guard !userId.isEmpty else { return }
        if let map = try? await service.fetchPushPreferences(userId: userId) {
            prefs = map
            loaded = true
            errorMessage = nil
        } else if !loaded {
            errorMessage = "Couldn't load your notification settings."
        }
    }

    func set(_ key: String, _ newValue: Bool) async {
        guard loaded, savingKey == nil, !userId.isEmpty, prefs[key] != newValue else { return }
        savingKey = key
        defer { savingKey = nil }
        do {
            prefs = try await service.setPushPreference(userId: userId, key: key, enabled: newValue)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save. Please try again."
        }
    }
}

struct NotificationSettingsView: View {
    @StateObject private var model: NotificationPreferencesModel
    private let capabilities: FSCapabilities

    init(userId: String, service: DataServiceProtocol, capabilities: FSCapabilities) {
        _model = StateObject(wrappedValue: NotificationPreferencesModel(service: service, userId: userId))
        self.capabilities = capabilities
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Choose which push notifications you receive. Incoming call alerts and replies to your own join requests are always sent.")
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let msg = model.errorMessage {
                    HStack {
                        Text(msg)
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(.red)
                            .accessibilityLabel(msg)
                        Spacer()
                        if !model.loaded {
                            Button("Try again") { Task { await model.load() } }
                                .font(.inter(Theme.fontXS, weight: .semibold))
                                .foregroundColor(Theme.gold)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassCard(cornerRadius: 20)
                }

                if model.loaded {
                    ForEach(NotificationPushType.visibleGroups(capabilities: capabilities), id: \.title) { group in
                        VStack(alignment: .leading, spacing: Theme.spacingSM) {
                            Text(group.title.uppercased())
                                .font(.inter(Theme.fontXS, weight: .semibold))
                                .foregroundColor(Theme.textMuted)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.types) { type in
                                Toggle(isOn: Binding(
                                    get: { model.prefs[type.key] ?? true },
                                    set: { v in Task { await model.set(type.key, v) } })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(type.label)
                                            .font(.inter(Theme.fontBody))
                                            .foregroundColor(Theme.parchment)
                                        Text(type.detail)
                                            .font(.inter(Theme.fontXS))
                                            .foregroundColor(Theme.textMuted)
                                    }
                                }
                                .tint(Theme.gold)
                                .disabled(model.savingKey != nil)
                                .accessibilityLabel("\(type.label) notifications")
                                .accessibilityHint(type.detail)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 16)
                        .glassCard(cornerRadius: 20)
                    }
                } else if model.errorMessage == nil {
                    ProgressView().tint(Theme.gold).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, Theme.spacingMD)
            .padding(.bottom, 150)
        }
        .background(Theme.bgPage)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}
