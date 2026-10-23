// FSPinnedActionBar.swift
// Pinned bottom action bar (spec 2.8): optional outlined secondary plus gold
// gradient primary. The primary dims when invalid but stays tappable so the
// tap runs validation (spec D8). `saving` swaps the label for a spinner.

import SwiftUI

struct FSPinnedActionBar: View {
    var secondaryTitle: String? = nil
    var secondaryIcon: String? = nil          // used by the tight variant
    var secondaryDestructive: Bool = false
    var onSecondary: (() -> Void)? = nil
    let primaryTitle: String
    var primaryTrailingIcon: String? = nil
    var primaryDimmed: Bool = false
    /// Destructive primary (spec 9.2): danger fill + error text/border, never gold.
    var primaryDestructive: Bool = false
    var primaryAccessibilityLabel: String? = nil
    var saving: Bool = false
    var tight: Bool = false
    let onPrimary: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var stacked: Bool { typeSize >= .accessibility2 }

    var body: some View {
        Group {
            if stacked && secondaryTitle != nil {
                VStack(spacing: 8) { primary; secondary }
            } else {
                HStack(spacing: 12) { secondary; primary }
            }
        }
        .padding(16)
        .background(Theme.navBg.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
        .disabled(saving)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var secondary: some View {
        if let secondaryTitle {
            Button { onSecondary?() } label: {
                Group {
                    if tight, let secondaryIcon {
                        Image(systemName: secondaryIcon).font(.system(size: 16, weight: .bold))
                            .frame(width: 52, height: 52)
                    } else {
                        Text(secondaryTitle).font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: stacked ? .infinity : nil, minHeight: 52)
                            .padding(.horizontal, stacked ? 0 : 20)
                    }
                }
                .foregroundColor(secondaryDestructive ? Theme.error : Theme.gold)
                .background(Capsule().fill(secondaryDestructive ? Theme.dangerBg : Color.clear))
                .overlay(Capsule().strokeBorder(secondaryDestructive ? Theme.errorStrong : Theme.borderGold, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(secondaryTitle)
            .frame(maxWidth: (tight || stacked) ? nil : UIScreen.main.bounds.width * 0.44)
        }
    }

    private var primary: some View {
        Button(action: onPrimary) {
            Group {
                if saving { ProgressView().tint(Theme.ink) }
                else {
                    HStack(spacing: 8) {
                        Text(primaryTitle).font(.system(size: 16, weight: .bold))
                        if let primaryTrailingIcon { Image(systemName: primaryTrailingIcon).font(.system(size: 14, weight: .bold)) }
                    }
                }
            }
            .foregroundColor(primaryDestructive ? Theme.error.opacity(primaryDimmed ? 0.5 : 1)
                                                : (primaryDimmed ? Theme.ink.opacity(0.5) : Theme.ink))
            .frame(maxWidth: .infinity, minHeight: 52)
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
