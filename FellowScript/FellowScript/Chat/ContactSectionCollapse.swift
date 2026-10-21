// ContactSectionCollapse.swift
// Device-local, per-user collapsed state for the iPad Messages panel's
// FRIENDS / GROUPS sections, plus the tappable chevron header.
// Task 20261021-ipad-note-bg-collapsible-contacts. No backend; both expanded by default.

import SwiftUI

enum ContactSectionCollapse {
    enum Section: String, CaseIterable { case friends, groups }

    static func key(_ section: Section, userId: String?) -> String {
        "chat.section.collapsed.\(section.rawValue).\(userId ?? "anon")"
    }

    static func isCollapsed(_ section: Section, userId: String?, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(section, userId: userId))
    }

    static func setCollapsed(_ section: Section, _ collapsed: Bool, userId: String?, defaults: UserDefaults = .standard) {
        defaults.set(collapsed, forKey: key(section, userId: userId))
    }

    static func collapsedSections(userId: String?, defaults: UserDefaults = .standard) -> Set<Section> {
        Set(Section.allCases.filter { isCollapsed($0, userId: userId, defaults: defaults) })
    }
}

/// Section label with a rotating chevron; the whole row is the toggle (>= 44pt tall).
struct CollapsibleSectionHeader: View {
    let title: String
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.inter(Theme.fontXXS, weight: .bold)).tracking(3)
            }
            .foregroundColor(Theme.goldLight)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Double tap to expand" : "Double tap to collapse")
        .accessibilityAddTraits(.isHeader)
    }
}
