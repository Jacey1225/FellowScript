// NotificationSettingsView+Reminders.swift -- task 20261016-push-notifications-and-ui.
// "Daily reminders" card (three opt-in reminders, each with a time of day shown
// only while the reminder is on) and the non-interactive "Always on" card that
// lists the pushes the server never lets a user switch off.

import SwiftUI

struct NotificationRemindersCard: View {
    @ObservedObject var model: NotificationPreferencesModel
    @ObservedObject private var onboarding = OnboardingEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        FSFormCard(title: "Daily reminders") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(NotificationPushType.reminders.enumerated()), id: \.element.id) { idx, type in
                    if idx > 0 { Divider().overlay(Theme.borderGray) }
                    row(type)
                }
                Text("Reminders arrive around your chosen time in your account time zone.")
                    .font(.fsHelper)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private func row(_ type: NotificationPushType) -> some View {
        let isOn = model.prefs[type.key] ?? false
        VStack(alignment: .leading, spacing: 0) {
            NotificationToggleRow(type: type, model: model)
                .onboardingAnchor(type.key == "prayer_reminder" ? .prayerToggle : nil)
            if isOn, let timeKey = PushReminderKeys.timeKey[type.key],
               let confirmed = model.times[timeKey],
               let date = PushReminderKeys.date(from: confirmed) {
                timeTile(label: type.label, timeKey: timeKey, confirmed: confirmed, date: date,
                         isPrayer: type.key == "prayer_reminder")
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isOn)
    }

    /// "Remind me at" time tile: field-recipe tile with the compact time picker.
    private func timeTile(label: String, timeKey: String, confirmed: String, date: Date, isPrayer: Bool) -> some View {
        let picker = DatePicker("", selection: Binding(
            get: { date },
            set: { d in Task { await model.setTime(timeKey, PushReminderKeys.format(d)) } }),
            displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(Theme.gold)
            .disabled(model.savingKey != nil)
            .accessibilityLabel("\(label) reminder time")
        return VStack(alignment: .leading, spacing: 8) {
            Text("Remind me at").font(.fsLabel).foregroundColor(Theme.textPrimary)
            HStack {
                Image(systemName: "clock").foregroundColor(Theme.gold).accessibilityHidden(true)
                Spacer()
                picker
            }
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.formFieldHeight)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
            .onboardingAnchor(isPrayer ? .prayerTime : nil)
            // Onboarding only: accept the time already shown (a real re-save).
            if isPrayer, onboarding.currentCue?.id == "prayer.time" {
                Button {
                    Task { await model.setTime(timeKey, confirmed, force: true) }
                } label: {
                    Text("Keep this time")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.gold)
                        .frame(minHeight: 44).padding(.horizontal, 16)
                        .overlay(Capsule().strokeBorder(Theme.borderGold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.savingKey != nil)
            }
        }
        .padding(.top, 4)
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
        FSFormCard(title: "Always on") {
          VStack(alignment: .leading, spacing: Theme.spacingSM) {
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
        }
    }
}
