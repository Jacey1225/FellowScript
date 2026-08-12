// PillButton.swift
// Ported from the standalone ChatSchedule prototype
// (Sources/ChatSchedule/Components/PillButton.swift), re-expressed on top of
// Theme.swift instead of the prototype's own DesignTokens.swift `DS` enum —
// no parallel token system. Used by ChatThreadView's header "Schedule" pill
// and SessionCreatorSheet's header "Schedule" pill (mirrors chat.html's
// `.schedule-pill` / schedule.html's `.fill-pill`).
//
// DEPENDENCY: Theme.swift

import SwiftUI

/// The amber-gradient pill button used in both mockups.
struct PillButton: View {
    let title: String
    var systemIcon: String? = nil
    var textColor: Color = Theme.ink
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 13, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(textColor)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Theme.goldGradient)
            .clipShape(Capsule())
            .shadow(color: Theme.goldDim.opacity(0.32), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

/// A round icon-only button with the translucent card treatment used for the
/// chat header's back button and the composer's send/attach affordances
/// (mirrors chat.html's `.icon-btn`/`.composer-icon`).
struct RoundIconButton: View {
    let systemIcon: String
    var diameter: CGFloat = 36
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemIcon)
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundColor(Theme.gold)
                .frame(width: diameter, height: diameter)
                .background(Color.white.opacity(0.05))
                .overlay(Circle().stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
