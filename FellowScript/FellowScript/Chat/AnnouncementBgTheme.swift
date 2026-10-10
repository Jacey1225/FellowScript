// AnnouncementBgTheme.swift — background theme presets for the area below the
// banner (task 20261009-announcements-advanced, part D, design-notes.md "D.
// Background theme palette"). The key is what the server stores (allowlist in
// api/backend/interactions/announcements.py BG_THEME_KEYS); the colors are
// client design tokens. Every preset is dark-leaning so parchment/white text
// stays WCAG AA; `worstCaseContrast` is the number a unit test asserts.
// Unknown/legacy keys render as `.none` (the pre-feature look).

import SwiftUI

enum AnnouncementBgTheme: String, CaseIterable, Identifiable {
    case none
    case ember, dusk, forest, ocean, plum, slate
    case espresso, moss, navy, wine, graphite, ink

    var id: String { rawValue }

    /// Server flag (GET /app/capabilities) that gates the palette.
    static let flagName = "announcement_bg_theme"

    static let parchmentHex = "#F5EAD0"
    static let whiteHex = "#FFFFFF"

    var name: String {
        switch self {
        case .none: return "None"
        default:    return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Spoken name ("Dusk gradient", "Navy solid").
    var accessibilityName: String {
        switch self {
        case .none: return "No background theme"
        default:    return "\(name) \(isGradient ? "gradient" : "solid")"
        }
    }

    /// Gradient stops (top-leading to bottom-trailing); one stop = solid; empty = none.
    var stops: [String] {
        switch self {
        case .none:     return []
        case .ember:    return ["#2A1A0C", "#4A2A10"]
        case .dusk:     return ["#1D1A33", "#3A2748"]
        case .forest:   return ["#10241A", "#1E3A2A"]
        case .ocean:    return ["#0F2233", "#1B3B52"]
        case .plum:     return ["#2B1530", "#4A2450"]
        case .slate:    return ["#1B1F26", "#343B46"]
        case .espresso: return ["#2A1F16"]
        case .moss:     return ["#1F2B1E"]
        case .navy:     return ["#16213A"]
        case .wine:     return ["#3A1A22"]
        case .graphite: return ["#25262B"]
        case .ink:      return ["#101010"]
        }
    }

    var isGradient: Bool { stops.count > 1 }
    static let gradients: [AnnouncementBgTheme] = [.ember, .dusk, .forest, .ocean, .plum, .slate]
    static let solids: [AnnouncementBgTheme] = [.espresso, .moss, .navy, .wine, .graphite, .ink]

    /// Strict allowlist lookup: nil, unknown or legacy -> `.none`.
    static func resolve(_ key: String?) -> AnnouncementBgTheme {
        guard let key, let t = AnnouncementBgTheme(rawValue: key) else { return .none }
        return t
    }

    /// The key to store: nil for none (server NULL).
    var storedKey: String? { self == .none ? nil : rawValue }

    /// Fill for the theme, nil for `.none`.
    @ViewBuilder var fill: some View {
        if stops.count > 1 {
            LinearGradient(colors: stops.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        } else if let one = stops.first {
            Color(hex: one)
        } else {
            Color.clear
        }
    }

    // ── Contrast ─────────────────────────────────────────────────────────────
    /// The lightest stop (worst case for light text).
    var worstCaseStopHex: String? {
        stops.max { (AnnouncementTitleColor.luminance($0) ?? 0) < (AnnouncementTitleColor.luminance($1) ?? 0) }
    }

    /// Text hex that reads best on this theme: parchment, or white if it wins
    /// over the worst-case stop. `.none` sits on the app surface (parchment).
    var readableTextHex: String {
        guard let bg = worstCaseStopHex else { return Self.parchmentHex }
        let p = AnnouncementTitleColor.contrastRatio(Self.parchmentHex, bg) ?? 0
        let w = AnnouncementTitleColor.contrastRatio(Self.whiteHex, bg) ?? 0
        return w > p ? Self.whiteHex : Self.parchmentHex
    }

    var readableText: Color { Color(hex: readableTextHex) }

    /// WCAG ratio of `textHex` (fully opaque) over this theme's worst-case stop.
    func worstCaseContrast(textHex: String) -> Double? {
        let bg = worstCaseStopHex ?? AnnouncementTitleColor.darkSurfaceHex
        return AnnouncementTitleColor.contrastRatio(textHex, bg)
    }

    /// Surface hex a title color must clear on this theme.
    var surfaceHex: String { worstCaseStopHex ?? AnnouncementTitleColor.darkSurfaceHex }
}

/// Palette sheet: gradients and solids, "None" first, gold ring on the selected
/// tile, VoiceOver names, Done button.
struct AnnouncementBgThemeSheet: View {
    @Binding var key: String?
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private var current: AnnouncementBgTheme { AnnouncementBgTheme.resolve(key) }
    private let columns = [GridItem(.adaptive(minimum: 56, maximum: 64), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) { tile(.none) }
                    section("Gradients", AnnouncementBgTheme.gradients)
                    section("Solids", AnnouncementBgTheme.solids)
                }
                .padding(Theme.spacingMD)
            }
            .warmBloomBackground()
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.bold).foregroundColor(Theme.gold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }

    private func section(_ title: String, _ items: [AnnouncementBgTheme]) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text(title)
                .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.gold.opacity(0.7))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(items) { tile($0) }
            }
        }
    }

    private func tile(_ t: AnnouncementBgTheme) -> some View {
        let selected = current == t
        return Button {
            key = t.storedKey
            onChange()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.bgPage)
                if t != .none {
                    t.fill.clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                } else {
                    Image(systemName: "nosign").font(.system(size: 18)).foregroundColor(Theme.parchment.opacity(0.7))
                }
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(selected ? Theme.gold : Color.white.opacity(0.25), lineWidth: selected ? 2 : 1)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18)).foregroundColor(Theme.gold)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(4)
                }
            }
            .frame(height: 56)
            .frame(minWidth: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
