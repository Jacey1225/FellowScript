// AnnouncementRepeatSection.swift — author-only repeat controls for the
// create/edit sheet plus the member-facing indicator row (task
// 20261016-announcement-recurring-reminder). Uses existing Theme tokens and the
// same chip look as the Publish field. State lives in the form; this view only
// edits the bound `AnnouncementRepeatDraft`.

import SwiftUI

struct AnnouncementRepeatSection: View {
    @Binding var draft: AnnouncementRepeatDraft
    /// First post time: the end date must fall after it.
    let base: Date
    let saving: Bool
    var onChange: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasEnd: Bool { draft.until != nil }
    private var earliest: Date { AnnouncementRepeatDraft.earliestEndDay(after: max(base, Date())) }
    private var latest: Date { Date().addingTimeInterval(TimeInterval(AnnouncementLimits.horizonDays * 86_400 - 3600)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            Text("Repeat")
                .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.gold.opacity(0.7))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Theme.spacingSM) {
                chip("Off", selected: draft.interval == nil) { draft = .off }
                ForEach(AnnouncementRepeat.allCases, id: \.self) { option in
                    chip(option.title, selected: draft.interval == option) {
                        draft = AnnouncementRepeatDraft(interval: option, until: draft.until)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Repeat")
            .disabled(saving)
            if draft.interval != nil {
                endDate
                Text("Members with announcement reminders on get a push each time. It stops by itself after 52 reminders or a year.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
                Text("Times follow your time zone, \(TimeZone.current.identifier).")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: draft.interval)
    }

    private var endDate: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            Toggle(isOn: Binding(
                get: { hasEnd },
                set: { on in
                    draft.until = on ? AnnouncementRepeatDraft.endOfDay(earliest) : nil
                    onChange()
                })) {
                Text("End date").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
            }
            .tint(Theme.gold)
            .frame(minHeight: 44)
            .disabled(saving)
            .accessibilityLabel("End date")
            if let until = draft.until {
                DatePicker("Last day to repeat",
                           selection: Binding(get: { until }, set: { draft.until = AnnouncementRepeatDraft.endOfDay($0); onChange() }),
                           in: earliest...latest, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .font(.inter(Theme.fontSM))
                    .tint(Theme.gold)
                    .disabled(saving)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); onChange() } label: {
            Text(title)
                .font(.inter(Theme.fontXS, weight: .semibold))
                .foregroundColor(selected ? Theme.gold : Theme.parchment.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(selected ? Theme.gold.opacity(0.15) : Color.clear)
                .overlay(Capsule().stroke(selected ? Theme.borderGold : Theme.borderGoldDim, lineWidth: 1))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Read-only line shown to every member in the list row and the detail view.
struct AnnouncementRepeatIndicator: View {
    let item: FSGroupAnnouncement
    var color: Color = Theme.parchment
    var font: Font = .inter(Theme.fontXXS)

    var body: some View {
        if let text = item.repeatIndicator {
            HStack(spacing: 4) {
                Image(systemName: "repeat").font(font).accessibilityHidden(true)
                Text(text).font(font)
            }
            .foregroundColor(color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        }
    }
}
