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
            .init(key: "announcement_reminder", label: "Announcement reminder", detail: "A reminder one hour before a scheduled announcement goes live, and each repeat of a recurring announcement.", flag: nil),
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
    /// Key that just saved; drives the 2-second inline "Saved" check (TD1).
    @Published private(set) var savedKey: String?
    @Published var errorMessage: String?
    private var savedClear: Task<Void, Never>?

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
            markSaved(key)
            // Onboarding: the prayer reminder is really on (server-confirmed).
            if key == "prayer_reminder", newValue, snap.toggles[key] == true {
                OnboardingEngine.shared.report(.prayerReminderEnabled)
            }
        } catch {
            errorMessage = "Couldn't save. Please try again."
            if key == "prayer_reminder" {
                OnboardingEngine.shared.reportFailure(.prayerReminderEnabled, message: "We couldn't turn that on. Try again.")
            }
        }
    }

    private func markSaved(_ key: String) {
        savedKey = key
        savedClear?.cancel()
        savedClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.savedKey = nil
        }
    }

    /// Saves a reminder time ("HH:MM"). The picker reads `times`, so a failed
    /// save snaps back to the confirmed value. `force` re-saves an unchanged
    /// value (onboarding "Keep this time": still a real server write).
    func setTime(_ key: String, _ newValue: String, force: Bool = false) async {
        guard loaded, savingKey == nil, !userId.isEmpty, force || times[key] != newValue,
              PushReminderKeys.isValidTime(newValue) else { return }
        savingKey = key
        defer { savingKey = nil }
        do {
            let snap = try await service.setPushPreferenceValue(userId: userId, key: key, value: newValue)
            prefs = snap.toggles
            times = snap.times
            loadFailed = false
            errorMessage = nil
            markSaved(key)
            if key == PushReminderKeys.timeKey["prayer_reminder"], snap.toggles["prayer_reminder"] == true {
                OnboardingEngine.shared.report(.prayerReminderTimeSaved)
            }
        } catch {
            errorMessage = "Couldn't save. Please try again."
            if key == PushReminderKeys.timeKey["prayer_reminder"] {
                OnboardingEngine.shared.reportFailure(.prayerReminderTimeSaved, message: "We couldn't save that time. Try again.")
            }
        }
    }
}

/// One instant-apply toggle row (TD1): FSToggleRow plus an inline "Saved" check for 2 seconds.
struct NotificationToggleRow: View {
    let type: NotificationPushType
    @ObservedObject var model: NotificationPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FSToggleRow(
                title: type.label,
                helper: type.detail,
                isOn: Binding(
                    get: { model.prefs[type.key] ?? false },
                    set: { v in Task { await model.set(type.key, v) } }),
                disabled: model.savingKey != nil)
                .accessibilityLabel("\(type.label) notifications")
                .accessibilityHint(type.detail)
            if model.savedKey == type.key {
                Label("Saved", systemImage: "checkmark")
                    .font(.fsHelper)
                    .foregroundColor(Theme.success)
                    .padding(.bottom, 8)
                    .accessibilityLabel("\(type.label) saved")
            }
        }
    }
}

struct NotificationSettingsView: View {
    @StateObject private var model: NotificationPreferencesModel
    @ObservedObject private var onboarding = OnboardingEngine.shared
    private let capabilities: FSCapabilities

    init(userId: String, service: DataServiceProtocol, capabilities: FSCapabilities) {
        _model = StateObject(wrappedValue: NotificationPreferencesModel(service: service, userId: userId))
        self.capabilities = capabilities
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Choose which push notifications you receive. The ones listed under Always on can't be turned off.")
                    .font(.fsHelper)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let msg = model.errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.error)
                            Text(msg).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.error)
                                .accessibilityLabel(msg)
                        }
                        if model.loadFailed {
                            Button("Try again") { Task { await model.load() } }
                                .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.gold)
                                .frame(minHeight: 44).padding(.horizontal, 16)
                                .overlay(Capsule().strokeBorder(Theme.borderGold, lineWidth: 1))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).fill(Theme.dangerBg))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).strokeBorder(Theme.errorStrong, lineWidth: 1))
                }

                if model.loaded {
                    ForEach(NotificationPushType.visibleGroups(capabilities: capabilities), id: \.title) { group in
                        FSFormCard(title: group.title) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.types.enumerated()), id: \.element.id) { idx, type in
                                    if idx > 0 { Divider().overlay(Theme.borderGray) }
                                    NotificationToggleRow(type: type, model: model)
                                }
                            }
                        }
                    }
                    NotificationRemindersCard(model: model)
                    NotificationAlwaysOnCard()
                } else if model.errorMessage == nil {
                    ProgressView().tint(Theme.gold).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, Theme.spacingMD)
            .padding(.bottom, 150)
            // Readable column on wide (iPad) sheets; a no-op at phone widths.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .warmBloomBackground()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onAppear { onboarding.report(.notificationSettingsOpened) }
        .onDisappear { onboarding.surfaceDismissed(cueIDs: ["prayer.toggle", "prayer.time"]) }
        // Already on (replay, or turned on earlier): the toggle cue is satisfied by the real state.
        .onChange(of: model.loaded) { _, _ in syncPrayerCue() }
        .onChange(of: onboarding.currentCue?.id) { _, _ in syncPrayerCue() }
        .onChange(of: model.errorMessage) { _, msg in
            if let msg { UIAccessibility.post(notification: .announcement, argument: msg) }
        }
    }

    private func syncPrayerCue() {
        guard model.loaded, onboarding.currentCue?.id == "prayer.toggle",
              model.prefs["prayer_reminder"] == true else { return }
        onboarding.report(.prayerReminderEnabled)
    }
}
