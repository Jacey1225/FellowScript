// SOURCE: frontend/src/theme.js, frontend/src/styles/global.css
// All design tokens for FellowScript iOS. Zero hardcoded values elsewhere.

import SwiftUI

enum Theme {

    // ── Brand colors ──────────────────────────────────────────────────────────
    static let gold        = Color(hex: "#D4922A")   // honey amber — warmer & brighter
    static let goldDim     = Color(hex: "#B07820")
    static let goldLight   = Color(hex: "#F0AE40")
    static let parchment   = Color(hex: "#F5EAD0")   // softer warm cream
    static let ink         = Color(hex: "#1A100A")

    // ── Background / surface hierarchy ────────────────────────────────────────
    static let bgPage      = Color(hex: "#1E1812")   // warm dark (replaces cold #1C1C1C)
    static let navBg       = Color(hex: "#120D08").opacity(0.97)
    static let islandBg    = Color(hex: "#180E06").opacity(0.93)
    static let widgetBg    = Color(hex: "#180E06").opacity(0.99)
    static let cardBg      = Color(hex: "#221508").opacity(0.90)
    static let bibleBg     = Color(hex: "#1E1408")
    static let bibleText   = Color(hex: "#EDE1C3")
    static let inputBg     = Color(hex: "#180D05").opacity(0.72)
    static let dangerBg    = Color(hex: "#280808").opacity(0.75)

    // ── Borders ───────────────────────────────────────────────────────────────
    static let borderGold      = Color(hex: "#D4922A").opacity(0.32)
    static let borderGoldDim   = Color(hex: "#D4922A").opacity(0.18)
    static let borderGoldFaint = Color(hex: "#D4922A").opacity(0.12)
    static let borderDanger    = Color(hex: "#DC3232").opacity(0.25)

    // ── Text ──────────────────────────────────────────────────────────────────
    static let textPrimary    = Color(hex: "#F5EAD0")
    static let textSecondary  = Color(hex: "#F5EAD0").opacity(0.55)
    static let textMuted      = Color(hex: "#F5EAD0").opacity(0.28)
    static let textGold       = Color(hex: "#D4922A")
    static let textGoldMuted  = Color(hex: "#D4922A").opacity(0.55)

    // ── Tab bar ───────────────────────────────────────────────────────────────
    static let accentColor  = Color(hex: "#D4922A")
    static let tabInactive  = Color(hex: "#F5EAD0").opacity(0.38)

    // ── Highlight swatch colors ───────────────────────────────────────────────
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

    // ── Corner radii (rounder = friendlier) ──────────────────────────────────
    static let radiusSM: CGFloat = 8
    static let radius:   CGFloat = 12
    static let radiusLG: CGFloat = 16
    static let radiusXL: CGFloat = 24

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

// ── Font builders ─────────────────────────────────────────────────────────────
// lora()    → Apple New York serif   — elegant, built-in, great for reading
// playfair()→ SF Pro Rounded         — modern, warm, friendly for headings & UI
// verseRef()→ New York Light         — graceful for verse references
extension Font {
    static func lora(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func playfair(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func verseRef(_ size: CGFloat) -> Font {
        .system(size: size, weight: .light, design: .serif)
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
            .shadow(color: Color(hex: "#5C3800").opacity(0.30), radius: 12, x: 0, y: 5)
    }
}

extension View {
    func widgetCard(padding: CGFloat = Theme.spacingMD) -> some View {
        modifier(WidgetCard(padding: padding))
    }
}
