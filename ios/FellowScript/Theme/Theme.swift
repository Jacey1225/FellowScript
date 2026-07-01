// SOURCE: frontend/src/theme.js, frontend/src/styles/global.css
// All design tokens for FellowScript iOS. Zero hardcoded values elsewhere.

import SwiftUI

enum Theme {

    // ── Brand colors ──────────────────────────────────────────────────────────
    static let gold        = Color(hex: "#C8861A")
    static let goldDim     = Color(hex: "#A67015")
    static let goldLight   = Color(hex: "#E09A30")
    static let parchment   = Color(hex: "#F4E4C1")
    static let ink         = Color(hex: "#1A100A")

    // ── Background / surface hierarchy ────────────────────────────────────────
    static let bgPage      = Color(hex: "#1C1C1C")
    static let navBg       = Color(hex: "#060401").opacity(0.97)
    static let islandBg    = Color(hex: "#080502").opacity(0.92)
    static let widgetBg    = Color(hex: "#080502").opacity(0.99)
    static let cardBg      = Color(hex: "#060401").opacity(0.88)
    static let bibleBg     = Color(hex: "#231610")
    static let bibleText   = Color(hex: "#E8D9BB")
    static let inputBg     = Color(hex: "#140C04").opacity(0.70)
    static let dangerBg    = Color(hex: "#280808").opacity(0.75)

    // ── Borders ───────────────────────────────────────────────────────────────
    static let borderGold      = Color(hex: "#C8861A").opacity(0.30)
    static let borderGoldDim   = Color(hex: "#C8861A").opacity(0.16)
    static let borderGoldFaint = Color(hex: "#C8861A").opacity(0.14)
    static let borderDanger    = Color(hex: "#DC3232").opacity(0.25)

    // ── Text ──────────────────────────────────────────────────────────────────
    static let textPrimary    = Color(hex: "#F4E4C1")
    static let textSecondary  = Color(hex: "#F4E4C1").opacity(0.55)
    static let textMuted      = Color(hex: "#F4E4C1").opacity(0.28)
    static let textGold       = Color(hex: "#C8861A")
    static let textGoldMuted  = Color(hex: "#C8861A").opacity(0.55)

    // ── Tab bar ───────────────────────────────────────────────────────────────
    static let accentColor  = Color(hex: "#C8861A")
    static let tabInactive  = Color(hex: "#F4E4C1").opacity(0.40)

    // ── Highlight swatch colors (matches NotesSidebar TEXT_COLORS + HighlightPicker) ──
    static let hlYellow  = Color(hex: "#F5E642")
    static let hlRed     = Color(hex: "#E07070")
    static let hlGreen   = Color(hex: "#6DBF7E")
    static let hlBlue    = Color(hex: "#7EB8E0")
    static let hlPurple  = Color(hex: "#B07EE0")

    static let highlightColors: [Color] = [hlYellow, hlRed, hlGreen, hlBlue, hlPurple]
    static let highlightHex: [String]   = ["#F5E642", "#E07070", "#6DBF7E", "#7EB8E0", "#B07EE0"]

    // ── Status ────────────────────────────────────────────────────────────────
    static let success = Color(hex: "#4CAF78")
    static let error   = Color(hex: "#E06060")

    // ── Corner radii ─────────────────────────────────────────────────────────
    static let radiusSM: CGFloat = 6
    static let radius:   CGFloat = 8
    static let radiusLG: CGFloat = 12
    static let radiusXL: CGFloat = 18

    // ── Spacing ───────────────────────────────────────────────────────────────
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32

    // ── Typography sizes ──────────────────────────────────────────────────────
    static let fontDisplayXL: CGFloat = 34
    static let fontDisplayLG: CGFloat = 28
    static let fontDisplayMD: CGFloat = 22
    static let fontHeading:   CGFloat = 18
    static let fontBody:      CGFloat = 16
    static let fontSM:        CGFloat = 14
    static let fontXS:        CGFloat = 12
    static let fontXXS:       CGFloat = 10

    // ── Bible reader font size steps ─────────────────────────────────────────
    static let bibleFontSizes: [CGFloat] = [14, 17, 20, 24]
    static let bibleFontLabels = ["Small", "Medium", "Large", "X-Large"]
}

// ── Font builders (mirrors Lora + Playfair Display) ──────────────────────────
extension Font {
    static func lora(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Georgia", size: size).weight(weight)
    }
    static func playfair(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("Georgia-Bold", size: size).weight(weight)
    }
    static func verseRef(_ size: CGFloat) -> Font {
        .custom("Georgia-Italic", size: size)
    }
}

// ── Color from hex string ─────────────────────────────────────────────────────
extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        if h.count == 6 { h += "FF" }
        let v = UInt64(h, radix: 16) ?? 0
        let r = Double((v >> 24) & 0xFF) / 255
        let g = Double((v >> 16) & 0xFF) / 255
        let b = Double((v >>  8) & 0xFF) / 255
        let a = Double( v        & 0xFF) / 255
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

// ── Shared card modifier ──────────────────────────────────────────────────────
struct WidgetCard: ViewModifier {
    var padding: CGFloat = Theme.spacingMD

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLG)
                    .stroke(Theme.borderGoldDim, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)
    }
}

extension View {
    func widgetCard(padding: CGFloat = Theme.spacingMD) -> some View {
        modifier(WidgetCard(padding: padding))
    }
}
