// FSFormTokens.swift
// Form-only tokens and the system-font helper for the forms restyle
// (design-spec.md Revision 2: SF Pro at the Notes/Home weights, gray glass
// boxes). Everything resolves to Theme.swift; nothing here is a new color.

import SwiftUI

extension Theme {
    /// Field fill: parchment @6% (same recipe as the Notes search field).
    static let fieldFill   = Color(hex: "#F5EAD0").opacity(0.06)
    /// Field border: parchment @12%.
    static let fieldBorder = Color(hex: "#F5EAD0").opacity(0.12)
    /// Error borders use the error token at full strength (spec D31).
    static let errorStrong = Theme.error
    /// Form card radius (spec 2.2).
    static let formCardRadius: CGFloat = 20
    /// Field height (spec 2.3).
    static let formFieldHeight: CGFloat = 48
}

extension Font {
    /// System font, spec weights. Use instead of `.inter()` / `.playfair()` in form views.
    static func fsForm(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static let fsSheetTitle = Font.system(size: 22, weight: .heavy)
    static let fsCardHeading = Font.system(size: 17, weight: .semibold)
    static let fsLabel = Font.system(size: 14, weight: .semibold)
    static let fsBody = Font.system(size: 16, weight: .regular)
    static let fsHelper = Font.system(size: 12, weight: .regular)
}
