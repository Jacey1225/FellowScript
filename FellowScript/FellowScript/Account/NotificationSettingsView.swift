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
            .init(key: "announcement_reminder", label: "Announcement reminder", detail: "A reminder one hour before a scheduled announcement goes live.", flag: nil),
        ]),
        ("Groups and sessions", [
            .init(key: "session_reminders", label: "Session reminders", detail: "New sessions and sessions that are starting.", flag: nil),
        ]),
        ("Friends and reminders", [
            .init(key: "friend_highlight", label: "Friend highlights", detail: "When a friend highlights a verse.", flag: "friend_highlight_push"),
            .init(key: "friend_activity", label: "Friend activity", detail: "When a friend is active again, and friend nudges.", flag: nil),
            .init(key: "reminders", label: "Gentle reminders", detail: "Daily nudges and your scheduled devotion events.", flag: nil),
        ]),
    ]

    /// Opt-in daily reminders (default off on the server), each with a time of day.
    /// Rendered by NotificationSettingsView+Reminders.swift, not in `groups`.
    static let reminders: [NotificationPushType] = [
        .init(key: "prayer_reminder", label: "Prayer", detail: "A gentle nudge to pray.", flag: nil),
        .init(key: "check_in_reminder", label: "Check in with someone", detail: "A nudge to reach out to a friend.", flag: nil),
        .init(key: "deep_question_reminder", label: "Ask a deep question", detail: "A thoughtful question to start a conversation.", flag: nil),
    ]

    /// Every toggle key the screen needs from the server.
    static let allKeys: [NotificationPushType] = all + reminders

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
    /// "HH:MM" per `<type>_time` key, server-confirmed only.
    @Published private(set) var times: [String: String] = [:]
    /// True when the last load/refresh failed (drives the Try again button).
    @Published private(set) var loadFailed = false
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
        if let snap = try? await service.fetchPushPreferenceSnapshot(userId: userId) {
            prefs = snap.toggles
            times = snap.times
            loaded = true
            loadFailed = false
            errorMessage = nil
        } else {
            // Keep whatever was last confirmed; never invent values.
            loadFailed = true
            errorMessage = loaded
                ? "Couldn't refresh your settings. Showing what we last loaded."
                : "Couldn't load your notification settings."
        }
    }

    func set(_ key: String, _ newValue: Bool) async {
        guard loaded, savingKey == nil, !userId.isEmpty, prefs[key] != newValue else { return }
        savingKey = key
        defer { savingKey = nil }
        do {
            let snap = try await service.setPushPreferenceValue(userId: userId, key: key, value: newValue)
            prefs = snap.toggles
            times = snap.times
            loadFailed = false
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save. Please try again."
        }
    }

    /// Saves a reminder time ("HH:MM"). The picker reads `times`, so a failed
    /// save snaps back to the confirmed value.
    func setTime(_ key: String, _ newValue: String) async {
        guard loaded, savingKey == nil, !userId.isEmpty, times[key] != newValue,
              PushReminderKeys.isValidTime(newValue) else { return }
        savingKey = key
        defer { savingKey = nil }
        do {
            let snap = try await service.setPushPreferenceValue(userId: userId, key: key, value: newValue)
            prefs = snap.toggles
            times = snap.times
            loadFailed = false
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
                Text("Choose which push notifications you receive. The ones listed under Always on can't be turned off.")
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let msg = model.errorMessage {
                    HStack {
                        Text(msg)
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.error)
                            .accessibilityLabel(msg)
                        Spacer()
                        if model.loadFailed {
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
                                    get: { model.prefs[type.key] ?? false },
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
                    NotificationRemindersCard(model: model)
                    NotificationAlwaysOnCard()
                } else if model.errorMessage == nil {
                    ProgressView().tint(Theme.gold).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, Theme.spacingMD)
            .padding(.bottom, 150)
        }
        .warmBloomBackground()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onChange(of: model.errorMessage) { _, msg in
            if let msg { UIAccessibility.post(notification: .announcement, argument: msg) }
        }
    }
}
