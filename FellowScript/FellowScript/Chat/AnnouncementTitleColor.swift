// AnnouncementTitleColor.swift — palette, strict hex validation and contrast
// helpers for the announcement title color (task
// 20260929-announcement-title-color-crop-layer-fix, design-notes.md).
//
// Safety: a server/user string only becomes a `Color` through `resolve`, which
// first requires strict `#RRGGBB`. Anything else falls back to the default at
// render time only; stored values are never rewritten here.

import SwiftUI
import UIKit

enum AnnouncementTitleColor {
    struct Swatch: Identifiable, Equatable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    /// Default = the widget's existing parchment title color (NULL on the server).
    static let defaultHex = "#F2F2F2"

    /// Curated palette (design-notes.md). All >= 4.5:1 over the worst-case scrim.
    static let swatches: [Swatch] = [
        Swatch(name: "Parchment (default)", hex: "#F2F2F2"),
        Swatch(name: "White", hex: "#FFFFFF"),
        Swatch(name: "Gold", hex: "#FFC61A"),
        Swatch(name: "Light gold", hex: "#FFD966"),
        Swatch(name: "Sky", hex: "#9CD3FF"),
        Swatch(name: "Mint", hex: "#9BE7B4"),
        Swatch(name: "Rose", hex: "#FFB3C1"),
        Swatch(name: "Lavender", hex: "#CDB8FF"),
        Swatch(name: "Coral", hex: "#FF9E80"),
    ]

    /// Worst case backdrop for banner-face text: pure white photo under the
    /// 0.72 black scrim (about #474747).
    static let scrimWorstCaseHex = "#474747"
    /// App surface behind list-row / viewer titles (dark warm background).
    static let darkSurfaceHex = "#1A1108"
    static let minContrast = 4.5

    /// Strict `#RRGGBB` (ASCII hex digits only, exactly 7 characters).
    static func isValidHex(_ s: String?) -> Bool {
        guard let s, s.utf8.count == 7, s.hasPrefix("#") else { return false }
        return s.utf8.dropFirst().allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    static func normalized(_ s: String?) -> String? {
        isValidHex(s) ? s!.uppercased() : nil
    }

    static func isDefault(_ hex: String?) -> Bool {
        guard let n = normalized(hex) else { return true }
        return n == defaultHex
    }

    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let n = normalized(hex), let v = UInt32(n.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func luminance(_ hex: String) -> Double? {
        guard let c = rgb(hex) else { return nil }
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio, nil when either input is not a strict hex.
    static func contrastRatio(_ a: String, _ b: String) -> Double? {
        guard let la = luminance(a), let lb = luminance(b) else { return nil }
        let (hi, lo) = (max(la, lb), min(la, lb))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// True when the color is hard to read over some photos (custom colors only).
    static func needsLegibilityWarning(_ hex: String?) -> Bool {
        guard let n = normalized(hex), let ratio = contrastRatio(n, scrimWorstCaseHex) else { return false }
        return ratio < minContrast
    }

    /// Banner-face color: the chosen color when valid, else the default.
    static func bannerColor(_ hex: String?) -> Color {
        Color(hex: normalized(hex) ?? defaultHex)
    }

    /// List-row / viewer color on the app surface: chosen color only when it
    /// meets AA against the surface; otherwise `fallback` (theme text color).
    static func surfaceColor(_ hex: String?, fallback: Color) -> Color {
        guard let n = normalized(hex), !isDefault(n),
              let ratio = contrastRatio(n, darkSurfaceHex), ratio >= minContrast else { return fallback }
        return Color(hex: n)
    }

    static func name(for hex: String?) -> String {
        guard let n = normalized(hex) else { return "Parchment (default)" }
        return swatches.first { $0.hex == n }?.name ?? "Custom color \(n)"
    }

    /// SwiftUI Color -> sRGB `#RRGGBB` (wide-gamut picker output converted).
    static func hex(from color: Color) -> String? {
        let ui = UIColor(color)
        guard let cg = ui.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let comps = cg.components, comps.count >= 3 else { return nil }
        func b(_ x: CGFloat) -> Int { max(0, min(255, Int((x * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", b(comps[0]), b(comps[1]), b(comps[2]))
    }
}

/// Swatch row + custom picker for the announcement title color. `hex == nil`
/// means the default.
struct AnnouncementTitleColorPicker: View {
    @Binding var hex: String?
    var onChange: () -> Void = {}

    @State private var custom: Color = .white

    private var current: String { AnnouncementTitleColor.normalized(hex) ?? AnnouncementTitleColor.defaultHex }
    private var isCustom: Bool {
        !AnnouncementTitleColor.swatches.contains { $0.hex == current }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 44), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(AnnouncementTitleColor.swatches) { s in
                    swatchButton(s)
                }
                customTile
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Title color")
            Text("Title color: \(AnnouncementTitleColor.name(for: hex))")
                .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.7))
            if !AnnouncementTitleColor.isDefault(hex) {
                Button("Reset to default") { hex = nil; onChange() }
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold).frame(minHeight: 44)
            }
            if AnnouncementTitleColor.needsLegibilityWarning(hex) {
                Label("This color may be hard to read over some photos.", systemImage: "exclamationmark.triangle")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.goldLight)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private func checkColor(for hex: String) -> Color {
        (AnnouncementTitleColor.luminance(hex) ?? 1) > 0.4 ? .black : .white
    }

    private func swatchButton(_ s: AnnouncementTitleColor.Swatch) -> some View {
        let selected = current == s.hex && !isCustom
        return Button {
            hex = s.hex == AnnouncementTitleColor.defaultHex ? nil : s.hex
            onChange()
        } label: {
            ZStack {
                Circle().fill(Color(hex: s.hex)).frame(width: 32, height: 32)
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                if selected {
                    Circle().stroke(Theme.gold, lineWidth: 2).frame(width: 40, height: 40)
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(checkColor(for: s.hex))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customTile: some View {
        let selected = isCustom
        return ZStack {
            Circle().fill(selected ? Color(hex: current) : Color.clear).frame(width: 32, height: 32)
                .overlay(Circle().stroke(selected ? Color.white.opacity(0.35) : Theme.gold.opacity(0.6),
                                         style: StrokeStyle(lineWidth: 1, dash: selected ? [] : [3])))
            if selected {
                Circle().stroke(Theme.gold, lineWidth: 2).frame(width: 40, height: 40)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(checkColor(for: current))
            } else {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.gold)
            }
            // The system picker sits on top, invisible, so its 44pt target opens the palette.
            ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
                .labelsHidden().opacity(0.02).frame(width: 44, height: 44)
        }
        .frame(width: 44, height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(selected ? "Custom color \(current)" : "Custom color")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onChange(of: custom) { _, new in
            if let h = AnnouncementTitleColor.hex(from: new) {
                hex = h == AnnouncementTitleColor.defaultHex ? nil : h
                onChange()
            }
        }
    }
}
