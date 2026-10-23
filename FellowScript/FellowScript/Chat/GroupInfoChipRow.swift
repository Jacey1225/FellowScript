// GroupInfoChipRow.swift -- task 20261023-group-info-row. The slim sliding chip
// row under the group chat header (Announcements, Threads, Pinned, Media).
// Chip tokens are copied from the Notes tab `chip(title:id:)`
// (NotesListView+Toolbar.swift): capsule, 13.5pt bold, 38pt tall, gold gradient
// when selected (its submenu is open), parchment 7% fill + 14% stroke otherwise.

import SwiftUI

struct GroupInfoChipRow: View {
    let categories: [GroupInfoCategory]
    @Binding var selected: GroupInfoCategory?
    let pinCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedChip: GroupInfoCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    GroupInfoChip(category: category,
                                  label: category.chipLabel(pinCount: pinCount),
                                  value: category == .pinned ? (FSPinnedListCopy.buttonValue(count: pinCount) ?? "") : "",
                                  isSelected: selected == category) {
                        withMotionAwareAnimation(.easeOut(duration: 0.18), reduceMotion: reduceMotion) {
                            selected = GroupInfoCategory.toggled(selected, tapped: category)
                        }
                    }
                    .accessibilityFocused($focusedChip, equals: category)
                }
            }
            .padding(.horizontal, Theme.spacingMD)
        }
        .padding(.vertical, Theme.spacingSM)
        // Focus returns to the chip that opened the panel once it closes.
        .onChange(of: selected) { old, new in
            if new == nil, let old { focusedChip = old }
        }
        .accessibilityIdentifier("group-info-row")
    }
}

private struct GroupInfoChip: View {
    let category: GroupInfoCategory
    let label: String
    let value: String
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var chipHeight: CGFloat = 38

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13.5, weight: .bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isSelected ? Color(hex: "#24170A") : Theme.parchment.opacity(0.7))
                .padding(.horizontal, 16)
                .frame(minHeight: max(38, chipHeight))
                .background(
                    isSelected
                        ? LinearGradient(colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [Theme.parchment.opacity(0.07), Theme.parchment.opacity(0.07)], startPoint: .leading, endPoint: .trailing)
                )
                .overlay(Capsule().stroke(isSelected ? Color.clear : Theme.parchment.opacity(0.14), lineWidth: 1))
                .clipShape(Capsule())
                // 38pt visual, 44pt touch target: 3pt invisible slop above and below.
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityValue(value)
        .accessibilityHint("Opens the list")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
