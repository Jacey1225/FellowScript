// FSPinnedActionBar.swift
// Pinned bottom action bar (spec 2.8, option A "stacked"): flush with the form
// background (no fill, hairline or shadow). Full-width 54pt gold primary on
// top, the secondary (Back/Cancel) as a 48pt gold text button below. In a
// destructive confirm the safe action (the secondary) is the gold primary and
// the destructive action sits below it as a 48pt danger outline. With the
// keyboard up the bar collapses to one row: a 54pt round chevron + the primary.
// The primary dims when invalid but stays tappable so the tap runs validation
// (spec D8). `saving` swaps the label for a spinner.

import SwiftUI

struct FSPinnedActionBar: View {
    var secondaryTitle: String? = nil
    var secondaryIcon: String? = nil          // keyboard-up round button (default chevron.left)
    var onSecondary: (() -> Void)? = nil
    let primaryTitle: String
    var primaryTrailingIcon: String? = nil
    var primaryDimmed: Bool = false
    /// Destructive primary (spec 9.2): danger fill + error text/border, never gold.
    var primaryDestructive: Bool = false
    var primaryAccessibilityLabel: String? = nil
    var saving: Bool = false
    let onPrimary: () -> Void
    @State private var keyboardUp = false

    /// Destructive confirm: the secondary is the safe action and takes the gold slot.
    private var confirm: Bool { primaryDestructive && secondaryTitle != nil }

    var body: some View {
        Group {
            if keyboardUp && secondaryTitle != nil && !confirm {
                HStack(spacing: 12) { secondaryRound; primary }
                    .padding(.horizontal, 16).padding(.vertical, 10)
            } else if confirm {
                VStack(spacing: 8) { safeAction; primary }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            } else {
                VStack(spacing: 2) { primary; secondary }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .disabled(saving)
        .accessibilityElement(children: .contain)
    }

    /// 48pt gold text button (no outline, no fill).
    @ViewBuilder private var secondary: some View {
        if let secondaryTitle {
            Button { onSecondary?() } label: {
                Text(secondaryTitle).font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(secondaryTitle)
        }
    }

    /// Keyboard-up secondary: 54pt round chevron with a 1pt card ring, no fill.
    @ViewBuilder private var secondaryRound: some View {
        if let secondaryTitle {
            Button { onSecondary?() } label: {
                Image(systemName: secondaryIcon ?? "chevron.left").font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.gold)
                    .frame(width: 54, height: 54)
                    .overlay(Circle().strokeBorder(Theme.borderGray, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(secondaryTitle)
        }
    }

    /// Destructive-confirm safe action: full-width gold primary slot.
    @ViewBuilder private var safeAction: some View {
        if let secondaryTitle {
            Button { onSecondary?() } label: {
                Text(secondaryTitle).font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(Theme.goldGradient))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(secondaryTitle)
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
            .frame(maxWidth: .infinity, minHeight: primaryDestructive ? 48 : 54)
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
