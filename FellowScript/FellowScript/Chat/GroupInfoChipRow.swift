// GroupInfoChipRow.swift -- task 20261023-group-info-row. The slim sliding chip
// row under the group chat header (Announcements, Threads, Pinned, Media).
// Chip tokens are copied from the Notes tab `chip(title:id:)`
// (NotesListView+Toolbar.swift): capsule, 13.5pt bold, 38pt tall, gold gradient
// when selected (its submenu is open), parchment 7% fill + 14% stroke otherwise. The look
// itself lives in ChipButtonStyle (shared with the attach buttons). 20261024-chat-chips-bottom:
// the row now sits in the composer's accessory slot (ComposerAccessorySlot), which owns
// the vertical spacing.

import SwiftUI

struct GroupInfoChipRow: View {
    let categories: [GroupInfoCategory]
    @Binding var selected: GroupInfoCategory?
    let pinCount: Int
    /// Phone width: slightly smaller chips (full labels, still 44pt tall hit area).
    var compact: Bool = false
    /// Unseen counts per chip, drawn as a red badge at each chip's top-left.
    var badges: [GroupInfoCategory: Int] = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedChip: GroupInfoCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    GroupInfoChip(category: category,
                                  label: category.chipLabel(pinCount: pinCount),
                                  value: category == .pinned ? (FSPinnedListCopy.buttonValue(count: pinCount) ?? "") : "",
                                  isSelected: selected == category, compact: compact,
                                  badge: badges[category] ?? 0) {
                        withMotionAwareAnimation(.easeOut(duration: 0.18), reduceMotion: reduceMotion) {
                            selected = GroupInfoCategory.toggled(selected, tapped: category)
                        }
                    }
                    .accessibilityFocused($focusedChip, equals: category)
                }
            }
            .padding(.horizontal, Theme.spacingMD)
        }
        .scrollClipDisabled()
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
    var compact: Bool = false
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(label) }
        .buttonStyle(ChipButtonStyle(isSelected: isSelected, compact: compact))
        .overlay(alignment: .topLeading) {
            if badge > 0 {
                NavCountBadge(count: badge, ring: Theme.bgPage)
                    .offset(x: -5, y: compact ? -3 : -5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(category.title)
        .accessibilityValue(badge > 0 ? "\(value) \(badge) new".trimmingCharacters(in: .whitespaces) : value)
        .accessibilityHint(category == .sessions ? "View and schedule study sessions" : "Opens the list")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
