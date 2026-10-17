// NavCountBadge.swift -- task 20261016-ipad-parity-and-persistent-badges.
// The one red numeral capsule used by the phone FloatingTabBar, the iPad
// workspace rail and the iPad header avatar. Theme.error fill, "9+" cap,
// .unreadBadge spring in/out, and a brief scale pulse when the count changes
// while already visible (e.g. 2 -> 3). Reduce Motion: no transition, no pulse.
// Hidden from VoiceOver: the host control folds the count into its own label.
// The caller positions it (offset / overlay alignment); only the ring colour
// varies by backdrop (nav bar vs glass dock).

import SwiftUI

struct NavCountBadge: View {
    let count: Int
    var ring: Color = Theme.navBg
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: Theme.fontXXS, weight: .heavy))
            .foregroundColor(Theme.parchment)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                Capsule()
                    .fill(Theme.error)
                    .overlay(Capsule().stroke(ring, lineWidth: 1.5))
            )
            .scaleEffect(pulsing ? 1.15 : 1.0)
            .transition(.unreadBadge(reduceMotion: reduceMotion))
            .accessibilityHidden(true)
            .onChange(of: count) { old, new in
                // 0 <-> n is handled by the insertion/removal transition.
                guard old > 0, new > 0, new != old else { return }
                let spring = Animation.spring(response: 0.32, dampingFraction: 0.8)
                withMotionAwareAnimation(spring, reduceMotion: reduceMotion) { pulsing = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    withMotionAwareAnimation(spring, reduceMotion: reduceMotion) { pulsing = false }
                }
            }
    }
}
