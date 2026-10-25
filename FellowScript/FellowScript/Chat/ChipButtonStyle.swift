// ChipButtonStyle.swift -- task 20261024-chat-chips-bottom. The one capsule look shared by
// the group info chips (GroupInfoChipRow) and the attach buttons (AttachPickerRow) so the
// two can never drift apart. Tokens are the chips' existing ones: capsule, 13.5pt bold
// (12.5 compact), 38pt tall (34 compact) with a 44pt touch target, parchment 7% fill and
// 14% stroke, gold gradient when selected. New: a shared press feel (fill 7% -> 14% and a
// 0.97 scale; fill only under Reduce Motion). PillButton is not involved.

import SwiftUI

struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    /// Phone width: slightly smaller chip (full labels, still a 44pt hit area).
    var compact: Bool = false
    /// Icon + title buttons use a little less side padding than text-only chips.
    var hasIcon: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ChipButtonBody(configuration: configuration, isSelected: isSelected, compact: compact, hasIcon: hasIcon)
    }
}

private struct ChipButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let compact: Bool
    let hasIcon: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var chipHeight: CGFloat = 38

    private var pressed: Bool { configuration.isPressed }

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 13.5, weight: .bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(isSelected ? Color(hex: "#24170A") : Theme.parchment.opacity(0.7))
            .padding(.horizontal, hasIcon ? (compact ? 11 : 14) : (compact ? 12 : 16))
            .frame(minHeight: max(compact ? 34 : 38, compact ? chipHeight - 4 : chipHeight))
            .background(
                isSelected
                    ? LinearGradient(colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Theme.parchment.opacity(pressed ? 0.14 : 0.07),
                                              Theme.parchment.opacity(pressed ? 0.14 : 0.07)],
                                     startPoint: .leading, endPoint: .trailing)
            )
            .overlay(Capsule().stroke(isSelected ? Color.clear : Theme.parchment.opacity(0.14), lineWidth: 1))
            .clipShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(pressed ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.8), value: pressed)
            // 38pt (34pt compact) visual, 44pt touch target: invisible slop above and below.
            .padding(.vertical, compact ? 5 : 3)
            .contentShape(Rectangle())
    }
}

/// Icon + title label used inside a `ChipButtonStyle` button (attach buttons).
struct ChipIconLabel: View {
    let title: String
    let systemIcon: String
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemIcon)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundColor(Theme.gold.opacity(0.9))
            Text(title)
        }
    }
}
