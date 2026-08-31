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
    static let bibleText   = Color(hex: "#EDE1C3")
    static let inputBg     = Color(hex: "#180D05").opacity(0.72)
    static let dangerBg    = Color(hex: "#280808").opacity(0.75)
    // Translucent panel glass (task 20260830-bible-nav-dropdown-blur): meant
    // to sit as an overlay in front of a `.ultraThinMaterial` backdrop-blur
    // layer (never as a background on its own), so a floating panel can show
    // real blurred content behind it instead of an opaque fill, while still
    // landing in this app's warm dark tone rather than the material's
    // default cool system-grey. Built from the same base hue as islandBg/
    // widgetBg above, just non-opaque. Mirrors the web app's Warm Vellum
    // Glass panel tint (task 20260826-glass-verse-selector-messages),
    // adapted to this token's own base hex rather than importing the web's.
    // Opacity corrected 0.35 -> 0.14 (task 20260830-bible-nav-dropdown-blur,
    // second pass): 0.35 live-measured as compounding with `.ultraThinMaterial`'s
    // own dark-mode opacity into a near-fully-opaque composite (backdrop
    // correlation -0.20, i.e. none) -- 0.14 verified live to keep a real,
    // clearly-blurred-not-opaque backdrop signal (correlation up to ~0.57
    // against the true backdrop in the panel's non-chrome areas). This token
    // no longer carries the AA-contrast floor for panel text on its own --
    // text that can't tolerate a variable/bright backdrop (e.g. the header
    // row) gets its own dedicated near-opaque background instead; see
    // BibleNavDropdown.header in BibleReaderView.swift.
    static let panelGlassTint = Color(hex: "#180E06").opacity(0.14)

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
    // Full-height bottom-sheet presentation chrome (e.g. SessionCreatorSheet)
    // needs a rounder corner than any existing card/tile radius above — no
    // existing token covers this larger "sheet" scale, so it's added here
    // rather than reusing radiusXL and losing the bottom-sheet's intended
    // roundness. Continues the SM/·/LG/XL naming ladder.
    static let radiusXXL: CGFloat = 36

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
// Ember Glass typography (task 20260827-ember-glass-chat-rewrite, design gate
// §7): real bundled fonts, not system-font stand-ins. Font files live in
// FellowScript/Fonts/*.ttf (picked up automatically by the FellowScript
// target's file-system-synchronized group) and are registered in Info.plist's
// UIAppFonts. License check (SIL Open Font License 1.1, verified against the
// actual shipped font files) recorded in FellowScript/Fonts/NOTICE.md.
//
// playfair()→ real Playfair Display        — display-scale headings (18pt+);
//              name is kept because it is now literally accurate (previously
//              rendered SF Pro Rounded despite the name).
// inter()   → real Inter                   — everything else; replaces the
//              retired lora() (which rendered New York and would still have
//              lied under a name/font mismatch — Lora is itself a distinct
//              real Google-Fonts serif — so a correctly-named function was
//              introduced instead of repointing the old name).
// verseRef()→ real Playfair Display Italic — scripture verse references only
//              (previously New York Light); the sole reusable italic role.
extension Font {
    /// Only the weights actually bundled (Regular/SemiBold/Bold) are mapped;
    /// anything else falls back to its nearest bundled neighbor rather than
    /// silently resolving to no font at all.
    private static func playfairPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .regular, .light, .thin, .ultraLight:
            return "PlayfairDisplay-Regular"
        case .medium, .semibold:
            return "PlayfairDisplay-SemiBold"
        default: // .bold, .heavy, .black, and any future case
            return "PlayfairDisplay-Bold"
        }
    }

    private static func interPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold:
            return "Inter-SemiBold"
        case .bold, .heavy, .black:
            return "Inter-Bold"
        default: // .regular, .light, .thin, .ultraLight, and any future case
            return "Inter-Regular"
        }
    }

    static func playfair(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom(playfairPostScriptName(for: weight), size: size)
    }
    static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(interPostScriptName(for: weight), size: size)
    }
    static func verseRef(_ size: CGFloat) -> Font {
        .custom("PlayfairDisplay-Italic", size: size)
    }

    /// Dynamic-Type-responsive `.inter` (task 20260828-note-reply-continuation-ios,
    /// critique R7 partial): `.custom(_:size:)` above is a fixed point size that
    /// never grows with the user's text-size setting. NoteDetailView's new reply
    /// cards ("most text-dense new surface," per the source design critique) use
    /// this `relativeTo:` overload instead so that one new surface scales, without
    /// touching every other `.inter` call site's fixed sizing screen-wide.
    static func interScaled(_ size: CGFloat, weight: Font.Weight = .regular,
                             relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom(interPostScriptName(for: weight), size: size, relativeTo: textStyle)
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

// ── Elevation mechanism (Ember Glass) ──────────────────────────────────────────
// Design gate decision (task 20260827-ember-glass-chat-rewrite, §1): drop every
// drop shadow — Chat had zero native blur to begin with, so this is an
// explicit adoption of a flat/hairline elevation language, not a regression.
// A surface's existing full-perimeter border stroke is kept unchanged; this
// only adds a top-edge-only lit hairline (a 1px stroke with a light-to-clear
// vertical gradient) so the surface still reads as "raised" without a shadow.
// One reusable primitive here, applied identically everywhere a shadow used
// to live (WidgetCard below; PillButton/RoundIconButton, SessionBanner,
// SessionCreatorSheet, and message bubbles in the frontend step that follows)
// so there is exactly one elevation language across all five surfaces named
// in the acceptance criteria — no mixing.
extension View {
    func topEdgeHighlight<S: Shape>(_ shape: S, lineWidth: CGFloat = 1) -> some View {
        overlay(alignment: .top) {
            shape
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.30), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: lineWidth
                )
        }
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
            .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusLG))
    }
}

extension View {
    func widgetCard(padding: CGFloat = Theme.spacingMD) -> some View {
        modifier(WidgetCard(padding: padding))
    }
}

// ── Gold gradient (amber-gradient buttons/chips) ───────────────────────────
// Composed entirely from the existing goldLight/goldDim tokens above — no new
// hex literals. Several restyled Chat surfaces (PillButton, SegmentedDuration-
// Control's active segment, ChipToggle's "on" state, outgoing message
// avatars) need a reusable diagonal gold gradient rather than each call site
// hand-rolling its own `LinearGradient(colors: [...])`.
extension Theme {
    static let goldGradient = LinearGradient(
        colors: [goldLight, goldDim],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
