// ChipToggle.swift
// Ported from the standalone ChatSchedule prototype
// (Sources/ChatSchedule/Components/ChipToggle.swift), re-expressed on
// Theme.swift tokens. Also carries two small sibling views from the same
// prototype file: `SectionEyebrow` (a shared uppercase/tracked section
// label, replacing several near-identical private `sectionLabel` helpers
// scattered in ChatThreadView.swift) and `DateTimeTile`, adapted here to
// wrap a real, functional `DatePicker` binding rather than the prototype's
// static mock label — SessionCreatorSheet must keep letting the user
// actually pick a start date/time, not just display one.
//
// DEPENDENCY: Theme.swift

import SwiftUI

/// Chip-shaped toggle used in schedule.html's `.chip-toggle-row`/
/// `.chip-toggle.on`/`.chip-toggle.off` (Repeat weekly / Summarize with
/// agent). Tapping flips the bound boolean state.
struct ChipToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
            }
            Text(title)
                .font(.system(size: 15, weight: .bold))
        }
        .foregroundColor(isOn ? Theme.ink : Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background {
            if isOn {
                RoundedRectangle(cornerRadius: Theme.radiusXL).fill(Theme.goldGradient)
            } else {
                RoundedRectangle(cornerRadius: Theme.radiusXL)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                isOn.toggle()
            }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// One of the two large tappable date/time tiles — mirrors schedule.html's
/// `.dt-tile`. Unlike the prototype's static mock version, this wraps a real
/// `DatePicker` binding so the underlying start date/time is still editable
/// after the restyle.
struct DateTimeTile: View {
    let systemIcon: String
    let label:      String
    @Binding var date: Date
    let displayedComponents: DatePickerComponents

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.gold)
            DatePicker(label, selection: $date, displayedComponents: displayedComponents)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Theme.gold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.045))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
        .accessibilityLabel(label)
    }
}

/// A section eyebrow label — mirrors schedule.html's `.eyebrow` (uppercase,
/// tracked, amber, small-caps-style).
struct SectionEyebrow: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.lora(Theme.fontXXS)).tracking(2)
            .foregroundColor(Theme.gold.opacity(0.60))
    }
}
