// ReactionPicker.swift -- generic emoji-reaction UI, shared by chat message
// reactions (task 20261010-chat-reactions) and reusable by any other surface
// (e.g. verse reactions). Deliberately has NO chat/verse types: callers pass
// plain emoji strings and closures.
//
// Exports:
//   ReactionSummary            pure value {emoji, count, viewerReacted} (Codable, wire keys
//                              emoji/count/viewer_reacted) + pure list helpers
//                              (toggled / setting / updatingCount) and accessibilityLabel
//   ReactionEmojiName          VoiceOver name for an emoji ("Thumbs up")
//   ReactionChip               one tappable "👍 3" capsule, selected state, a11y label
//   ReactionChipFlow           wrapping layout (Dynamic Type safe) for chips
//   ReactionChipRow            ReactionChipFlow of ReactionChips for [ReactionSummary]
//   ReactionQuickRow           horizontal row of quick emojis + "more" button
//   ReactionMenuSection        the same quick row, built for use INSIDE a .contextMenu
//   ReactionPickerSheet        grid sheet of a larger emoji set
//   reactionAccessibilityActions(...)  VoiceOver custom actions for a quick set
//
// Reduce Motion is read from @Environment(\.accessibilityReduceMotion): no
// scale/bounce effects when it is on.
//
// DEPENDENCY: Theme.swift

import SwiftUI
import UIKit

// ── Value type ────────────────────────────────────────────────────────────────

/// Aggregated reactions for one emoji on one item.
struct ReactionSummary: Codable, Equatable, Identifiable, Hashable {
    let emoji: String
    var count: Int
    var viewerReacted: Bool

    var id: String { emoji }

    enum CodingKeys: String, CodingKey {
        case emoji, count
        case viewerReacted = "viewer_reacted"
    }

    /// e.g. "Thumbs up, 3 reactions, you reacted"
    var accessibilityLabel: String {
        let name = ReactionEmojiName.name(for: emoji)
        let noun = count == 1 ? "1 reaction" : "\(count) reactions"
        return viewerReacted ? "\(name), \(noun), you reacted" : "\(name), \(noun)"
    }

    // ── Pure list helpers (no side effects; unit-testable) ───────────────────

    /// The list after the viewer toggles `emoji`: adds (count + 1, reacted) when
    /// not reacted, removes the viewer's reaction otherwise (entry dropped at 0).
    static func toggled(_ list: [ReactionSummary], emoji: String) -> [ReactionSummary] {
        var out = list
        if let i = out.firstIndex(where: { $0.emoji == emoji }) {
            if out[i].viewerReacted {
                out[i].count -= 1
                out[i].viewerReacted = false
                if out[i].count <= 0 { out.remove(at: i) }
            } else {
                out[i].count += 1
                out[i].viewerReacted = true
            }
        } else {
            out.append(ReactionSummary(emoji: emoji, count: 1, viewerReacted: true))
        }
        return out
    }

    /// Replaces (or inserts / removes when `value` is nil or count <= 0) the
    /// entry for `emoji`, leaving every other emoji untouched. Used to apply a
    /// server result and to roll back one emoji after a failed optimistic toggle.
    static func setting(_ list: [ReactionSummary], emoji: String, to value: ReactionSummary?) -> [ReactionSummary] {
        var out = list
        let idx = out.firstIndex(where: { $0.emoji == emoji })
        if let value, value.count > 0 {
            if let idx { out[idx] = value } else { out.append(value) }
        } else if let idx {
            out.remove(at: idx)
        }
        return out
    }

    /// Applies someone else's change (live frame): new `count` for `emoji`,
    /// keeping the viewer's own state. count <= 0 removes the entry.
    static func updatingCount(_ list: [ReactionSummary], emoji: String, count: Int) -> [ReactionSummary] {
        let existing = list.first(where: { $0.emoji == emoji })
        guard count > 0 else { return setting(list, emoji: emoji, to: nil) }
        return setting(list, emoji: emoji,
                       to: ReactionSummary(emoji: emoji, count: count, viewerReacted: existing?.viewerReacted ?? false))
    }
}

// ── Accessibility names ───────────────────────────────────────────────────────

enum ReactionEmojiName {
    private static let known: [String: String] = [
        "👍": "Thumbs up", "👎": "Thumbs down", "❤️": "Heart", "🙏": "Praying hands",
        "😂": "Laughing", "😮": "Surprised", "😢": "Crying", "🎉": "Celebration",
        "🔥": "Fire", "👏": "Clapping", "🙌": "Raised hands", "😊": "Smiling",
        "🤔": "Thinking", "💯": "One hundred", "✝️": "Cross", "😍": "Heart eyes",
    ]

    /// Known friendly name, else the Unicode name of the first scalar, else the
    /// emoji itself. Never empty for a non-empty input.
    static func name(for emoji: String) -> String {
        if let n = known[emoji] { return n }
        if let scalar = emoji.unicodeScalars.first, let raw = scalar.properties.name, !raw.isEmpty {
            let lower = raw.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return emoji
    }
}

// ── Emoji as a menu-safe image ────────────────────────────────────────────────

/// Context-menu items drop styling from Text labels, so quick emojis are
/// drawn into a UIImage (original rendering) for use as a menu item icon.
enum ReactionEmojiImage {
    static func image(for emoji: String, pointSize: CGFloat = 28) -> UIImage {
        let font = UIFont.systemFont(ofSize: pointSize)
        let attributed = NSAttributedString(string: emoji, attributes: [.font: font])
        let size = attributed.size()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: ceil(size.width), height: ceil(size.height)))
        return renderer.image { _ in attributed.draw(at: .zero) }.withRenderingMode(.alwaysOriginal)
    }
}

// ── Chip ──────────────────────────────────────────────────────────────────────

/// One "👍 3" capsule. Tap toggles (the caller owns the state).
struct ReactionChip: View {
    let emoji: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var minHeight: CGFloat = 28

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(emoji).font(.system(.footnote))
                Text("\(count)")
                    .font(.inter(Theme.fontXS, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? Theme.gold : Theme.parchment)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: minHeight)
            .background(isSelected ? Theme.gold.opacity(0.22) : Color.white.opacity(0.06))
            .overlay(Capsule().stroke(isSelected ? Theme.borderGold : Theme.borderGoldFaint, lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ReactionSummary(emoji: emoji, count: count, viewerReacted: isSelected).accessibilityLabel)
        .accessibilityHint(isSelected ? "Double tap to remove your reaction" : "Double tap to react")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Wrapping left-to-right layout; wraps to new lines instead of truncating, so
/// large Dynamic Type sizes keep every chip reachable.
struct ReactionChipFlow: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + CGFloat(max(lines.count - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for line in lines {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - line.width
            case .center:   x = bounds.minX + (bounds.width - line.width) / 2
            default:        x = bounds.minX
            }
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let needed = lines[lines.count - 1].items.isEmpty ? size.width : lines[lines.count - 1].width + spacing + size.width
            if needed > width, !lines[lines.count - 1].items.isEmpty {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append((i, size))
            lines[lines.count - 1] = line
        }
        return lines.filter { !$0.items.isEmpty }
    }
}

/// Chips for a list of summaries, wrapping.
struct ReactionChipRow: View {
    let reactions: [ReactionSummary]
    var alignment: HorizontalAlignment = .leading
    let onTap: (ReactionSummary) -> Void

    var body: some View {
        if !reactions.isEmpty {
            ReactionChipFlow(spacing: 6, alignment: alignment) {
                ForEach(reactions) { r in
                    ReactionChip(emoji: r.emoji, count: r.count, isSelected: r.viewerReacted) { onTap(r) }
                }
            }
        }
    }
}

// ── Quick row ─────────────────────────────────────────────────────────────────

/// Horizontal quick-reaction row: one button per emoji plus an optional "more".
struct ReactionQuickRow: View {
    let emojis: [String]
    let selected: Set<String>
    let onPick: (String) -> Void
    var onMore: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .title2) private var target: CGFloat = 44

    var body: some View {
        HStack(spacing: 6) {
            ForEach(emojis, id: \.self) { emoji in
                Button { onPick(emoji) } label: {
                    Text(emoji)
                        .font(.system(.title2))
                        .frame(minWidth: target, minHeight: target)
                        .background(selected.contains(emoji) ? Theme.gold.opacity(0.22) : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ReactionEmojiName.name(for: emoji))
                .accessibilityAddTraits(selected.contains(emoji) ? [.isButton, .isSelected] : .isButton)
            }
            if let onMore {
                Button(action: onMore) {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(Theme.gold)
                        .frame(minWidth: target, minHeight: target)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More reactions")
            }
        }
    }
}

/// The quick row for use inside a `.contextMenu { }`: a palette control group of
/// emoji images (selected ones are marked) followed by a "More reactions…" item.
struct ReactionMenuSection: View {
    let emojis: [String]
    let selected: Set<String>
    let onPick: (String) -> Void
    var onMore: (() -> Void)? = nil

    var body: some View {
        if !emojis.isEmpty {
            ControlGroup {
                ForEach(emojis, id: \.self) { emoji in
                    Button { onPick(emoji) } label: {
                        Label {
                            Text(selected.contains(emoji)
                                 ? "\(ReactionEmojiName.name(for: emoji)), selected"
                                 : ReactionEmojiName.name(for: emoji))
                        } icon: {
                            Image(uiImage: ReactionEmojiImage.image(for: emoji))
                        }
                    }
                }
            }
            .controlGroupStyle(.palette)
        }
        if let onMore {
            Button(action: onMore) {
                Label("More reactions", systemImage: "face.smiling")
            }
        }
    }
}

/// VoiceOver custom actions (the accessible alternative to the long-press row).
@ViewBuilder
func reactionAccessibilityActions(emojis: [String], selected: Set<String>,
                                  onPick: @escaping (String) -> Void,
                                  onMore: (() -> Void)?) -> some View {
    ForEach(emojis, id: \.self) { emoji in
        Button(selected.contains(emoji)
               ? "Remove \(ReactionEmojiName.name(for: emoji)) reaction"
               : "React with \(ReactionEmojiName.name(for: emoji))") { onPick(emoji) }
    }
    if let onMore {
        Button("More reactions", action: onMore)
    }
}

// ── Picker sheet ──────────────────────────────────────────────────────────────

/// Grid of a larger emoji set. Calls `onPick` then dismisses itself.
struct ReactionPickerSheet: View {
    let emojis: [String]
    var selected: Set<String> = []
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title) private var cell: CGFloat = 52

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cell), spacing: 8)], spacing: 8) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.system(.title))
                                .frame(maxWidth: .infinity, minHeight: cell)
                                .background(selected.contains(emoji) ? Theme.gold.opacity(0.22) : Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ReactionEmojiName.name(for: emoji))
                        .accessibilityAddTraits(selected.contains(emoji) ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(Theme.spacingMD)
            }
            .navigationTitle("Add reaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
