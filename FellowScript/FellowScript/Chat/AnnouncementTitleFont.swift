// AnnouncementTitleFont.swift — the 8 announcement title fonts (task
// 20261009-announcements-advanced, part C, design-notes.md "C. Title font
// picker"). The key is what the server stores (allowlist in
// api/backend/interactions/announcements.py TITLE_FONT_KEYS); the font files
// are bundled (OFL, see Fonts/NOTICE.md). Unknown/legacy keys render the
// default face, never an error. `default` keeps the exact pre-feature look
// (Inter SemiBold, fixed size), so nothing changes while the flag is off.

import SwiftUI
import UIKit

enum AnnouncementTitleFont: String, CaseIterable, Identifiable {
    case `default`, playfair, schibsted, lora, oswald, dancing, nunito, bebas

    var id: String { rawValue }

    /// Server flag (GET /app/capabilities) that gates the picker.
    static let flagName = "announcement_title_font"

    var displayName: String {
        switch self {
        case .default:   return "Default"
        case .playfair:  return "Playfair"
        case .schibsted: return "Schibsted"
        case .lora:      return "Lora"
        case .oswald:    return "Oswald"
        case .dancing:   return "Dancing Script"
        case .nunito:    return "Nunito"
        case .bebas:     return "Bebas Neue"
        }
    }

    /// Spoken style hint for VoiceOver ("Playfair, serif").
    var styleHint: String {
        switch self {
        case .default:   return "sans serif"
        case .playfair:  return "serif"
        case .schibsted: return "grotesque"
        case .lora:      return "warm serif"
        case .oswald:    return "condensed"
        case .dancing:   return "script"
        case .nunito:    return "rounded"
        case .bebas:     return "heavy capitals"
        }
    }

    var accessibilityName: String { "\(displayName), \(styleHint)" }

    /// PostScript names read from each file's `name` table (see Fonts/NOTICE.md).
    /// nil = the default Inter SemiBold used before this feature.
    var postScriptName: String? {
        switch self {
        case .default:   return nil
        case .playfair:  return "PlayfairDisplay-Bold"
        case .schibsted: return "SchibstedGrotesk-SemiBold"
        case .lora:      return "Lora-SemiBold"
        case .oswald:    return "Oswald-SemiBold"
        case .dancing:   return "DancingScript-Bold"
        case .nunito:    return "NunitoExtraLight-ExtraBold"
        case .bebas:     return "BebasNeue-Regular"
        }
    }

    /// Optical size correction so each face reads about as large as Inter at
    /// the same nominal size (script and all-caps faces run small).
    private var sizeScale: CGFloat {
        switch self {
        case .dancing: return 1.12
        case .bebas:   return 1.15
        case .oswald:  return 1.04
        default:       return 1
        }
    }

    /// True when the font file really resolves at runtime.
    var isAvailable: Bool {
        guard let ps = postScriptName else { return true }
        return UIFont(name: ps, size: 12) != nil
    }

    /// Every face resolves (used by the load test).
    static var allResolve: Bool { allCases.allSatisfy(\.isAvailable) }

    /// Strict allowlist lookup: nil, "default", unknown or legacy -> `.default`.
    static func resolve(_ key: String?) -> AnnouncementTitleFont {
        guard let key, let f = AnnouncementTitleFont(rawValue: key), f.isAvailable else { return .default }
        return f
    }

    /// The key to store: nil for the default (server NULL).
    var storedKey: String? { self == .default ? nil : rawValue }

    /// Title font. The default face is the unchanged fixed-size Inter SemiBold;
    /// the others scale with Dynamic Type relative to `textStyle`.
    func font(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .title3) -> Font {
        guard let ps = postScriptName, isAvailable else { return .inter(size, weight: .semibold) }
        return .custom(ps, size: size * sizeScale, relativeTo: textStyle)
    }

    /// Fixed-size variant for chip specimens (does not grow with Dynamic Type).
    func chipFont(_ size: CGFloat) -> Font {
        guard let ps = postScriptName, isAvailable else { return .inter(size, weight: .semibold) }
        return .custom(ps, fixedSize: size * sizeScale)
    }
}

/// Horizontal font row (design C). Tapping a chip selects it; the selected chip
/// carries an "x" that clears it back to the default and scrolls the row to the
/// start so the user can pick a replacement.
struct AnnouncementTitleFontRow: View {
    @Binding var key: String?
    /// First characters of the draft title, shown in each face.
    let sample: String
    var onChange: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var current: AnnouncementTitleFont { AnnouncementTitleFont.resolve(key) }
    private var specimen: String {
        let s = String(sample.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        return s.isEmpty ? "Aa" : s
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingSM) {
                    ForEach(AnnouncementTitleFont.allCases) { f in
                        chip(f).id(f.rawValue)
                    }
                }
                .padding(.horizontal, Theme.spacingXS)
            }
            .mask(fadeMask)
            .onChange(of: key) { _, new in
                if AnnouncementTitleFont.resolve(new) == .default {
                    withMotionAwareAnimation(.easeOut(duration: 0.2), reduceMotion: reduceMotion) {
                        proxy.scrollTo(AnnouncementTitleFont.default.rawValue, anchor: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Title font")
    }

    @ViewBuilder private var fadeMask: some View {
        if reduceTransparency {
            Rectangle()
        } else {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                   .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }

    private func chip(_ f: AnnouncementTitleFont) -> some View {
        let selected = current == f
        return HStack(spacing: 0) {
            Button {
                key = f.storedKey
                onChange()
            } label: {
                Text(f == .default ? "Default" : specimen)
                    .font(f.chipFont(Theme.fontSM))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(f.accessibilityName)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected && f != .default {
                Button {
                    key = nil
                    onChange()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(Theme.parchment)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear font, \(f.displayName)")
            }
        }
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(selected ? Theme.gold : Color.white.opacity(0.25), lineWidth: selected ? 2 : 1))
    }
}
