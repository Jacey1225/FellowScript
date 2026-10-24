// FSPinnedActionBar.swift
// Pinned bottom action bar (spec 2.8, option B, always ONE row): flush with the
// form background (no fill, hairline or shadow). Back/Cancel hugs its label as a
// ghost pill on the left; the 54pt gold primary fills the rest. In a
// destructive confirm the safe action is the gold pill and the destructive
// action a danger outline pill, both in the same row; long labels wrap to two
// lines, the row never stacks. The primary dims when invalid but stays tappable
// so the tap runs validation (spec D8). `saving` swaps the label for a spinner.

import SwiftUI

struct FSPinnedActionBar: View {
    var secondaryTitle: String? = nil
    var onSecondary: (() -> Void)? = nil
    let primaryTitle: String
    var primaryTrailingIcon: String? = nil
    var primaryDimmed: Bool = false
    /// Destructive primary (spec 9.2): danger fill + error text/border, never gold.
    var primaryDestructive: Bool = false
    var primaryAccessibilityLabel: String? = nil
    var saving: Bool = false
    let onPrimary: () -> Void
    /// Destructive confirm: the secondary is the safe action and takes the gold slot.
    private var confirm: Bool { primaryDestructive && secondaryTitle != nil }

    var body: some View {
        HStack(spacing: 12) {
            if confirm { safeAction } else { secondary }
            primary
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        .disabled(saving)
        .accessibilityElement(children: .contain)
    }

    /// Hugging ghost pill (field recipe: parchment 6% fill, 12% border, primary-text label), min 92pt wide.
    @ViewBuilder private var secondary: some View {
        if let secondaryTitle {
            Button { onSecondary?() } label: {
                Text(secondaryTitle).font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .frame(minWidth: 92, minHeight: 54)
                    .background(Capsule().fill(Theme.fieldFill))
                    .overlay(Capsule().strokeBorder(Theme.fieldBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(secondaryTitle)
        }
    }

    /// Destructive-confirm safe action: gold pill that hugs its label.
    @ViewBuilder private var safeAction: some View {
        if let secondaryTitle {
            Button { onSecondary?() } label: {
                Text(secondaryTitle).font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .frame(minWidth: 92, minHeight: 54)
                    .background(Capsule().fill(Theme.goldGradient))
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(secondaryTitle)
        }
    }

    private var primary: some View {
        Button(action: onPrimary) {
            Group {
                if saving { ProgressView().tint(Theme.ink) }
                else {
                    HStack(spacing: 8) {
                        Text(primaryTitle).font(.system(size: 16, weight: .bold)).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 8)
                        if let primaryTrailingIcon { Image(systemName: primaryTrailingIcon).font(.system(size: 14, weight: .bold)) }
                    }
                }
            }
            .foregroundColor(primaryDestructive ? Theme.error.opacity(primaryDimmed ? 0.5 : 1)
                                                : (primaryDimmed ? Theme.ink.opacity(0.5) : Theme.ink))
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                if primaryDestructive { Capsule().fill(Theme.dangerBg) }
                else if primaryDimmed { Capsule().fill(Theme.goldDim.opacity(0.4)) }
                else { Capsule().fill(Theme.goldGradient) }
            }
            .overlay { if primaryDestructive { Capsule().strokeBorder(Theme.errorStrong.opacity(primaryDimmed ? 0.5 : 1), lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saving ? "Saving" : (primaryAccessibilityLabel ?? primaryTitle))
        .accessibilityValue(primaryDimmed ? "dimmed" : "")
        .accessibilityAddTraits(.isButton)
    }
}
