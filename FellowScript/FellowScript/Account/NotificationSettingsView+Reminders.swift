// NotificationSettingsView+Reminders.swift -- task 20261016-push-notifications-and-ui.
// "Daily reminders" card (three opt-in reminders, each with a time of day shown
// only while the reminder is on) and the non-interactive "Always on" card that
// lists the pushes the server never lets a user switch off.

import SwiftUI

struct NotificationRemindersCard: View {
    @ObservedObject var model: NotificationPreferencesModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("DAILY REMINDERS")
                .font(.system(size: Theme.fontXS, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(NotificationPushType.reminders.enumerated()), id: \.element.id) { idx, type in
                if idx > 0 { Divider().background(Theme.borderGray) }
                row(type)
            }
            Text("Reminders arrive around your chosen time in your account time zone.")
                .font(.system(size: Theme.fontXS))
                .foregroundColor(Theme.textMuted)
                .padding(.top, Theme.spacingXS)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    @ViewBuilder
    private func row(_ type: NotificationPushType) -> some View {
        let isOn = model.prefs[type.key] ?? false
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Toggle(isOn: Binding(
                get: { model.prefs[type.key] ?? false },
                set: { v in Task { await model.set(type.key, v) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.label).font(.system(size: Theme.fontBody)).foregroundColor(Theme.parchment)
                    Text(type.detail).font(.system(size: Theme.fontXS)).foregroundColor(Theme.textMuted)
                }
            }
            .tint(Theme.gold)
            .disabled(model.savingKey != nil)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isOn)
            .accessibilityLabel("\(type.label) notifications")
            .accessibilityHint(type.detail)

            if isOn, let timeKey = PushReminderKeys.timeKey[type.key],
               let confirmed = model.times[timeKey],
               let date = PushReminderKeys.date(from: confirmed) {
                timeRow(label: type.label, timeKey: timeKey, date: date)
                    .transition(.opacity)
            }
        }
    }

    private func timeRow(label: String, timeKey: String, date: Date) -> some View {
        let picker = DatePicker("", selection: Binding(
            get: { date },
            set: { d in Task { await model.setTime(timeKey, PushReminderKeys.format(d)) } }),
            displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(Theme.gold)
            .disabled(model.savingKey != nil)
            .accessibilityLabel("\(label) reminder time")
        return VStack(alignment: .leading, spacing: 0) {
            Divider().background(Theme.borderGray)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Theme.spacingXS) { timeText; picker }
                } else {
                    HStack { timeText; Spacer(); picker }
                }
            }
            .frame(minHeight: 44)
        }
    }

    private var timeText: some View {
        Text("Time").font(.system(size: Theme.fontBody)).foregroundColor(Theme.parchment)
            .accessibilityHidden(true)
    }
}

struct NotificationAlwaysOnCard: View {
    private static let lines: [(icon: String, title: String, detail: String)] = [
        ("bell.badge", "Friend requests", "When someone sends you a friend request."),
        ("bell.badge", "Join requests", "When someone asks to join a group you own."),
        ("bell.badge", "New members", "When someone joins a group you are in."),
        ("lock", "Incoming calls", "When someone rings you for a call."),
        ("lock", "Replies to your join requests", "When a group owner answers your request to join."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("ALWAYS ON")
                .font(.system(size: Theme.fontXS, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: Theme.spacingSM + 4) {
                    Image(systemName: line.icon)
                        .font(.system(size: Theme.fontBody))
                        .foregroundColor(Theme.gold)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.system(size: Theme.fontBody)).foregroundColor(Theme.parchment)
                        Text(line.detail).font(.system(size: Theme.fontXS)).foregroundColor(Theme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(line.title), always on. \(line.detail)")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }
}
