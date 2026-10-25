// GroupInfoSubmenu.swift -- task 20261023-group-info-row. The bottom-anchored
// panel (grabber, title, close, swipe-down) and its scrim. Width is the chat
// pane's own width (it is laid out inside the pane, never by screen size).

import SwiftUI

enum GroupInfoPanelMotion {
    /// Rise 280ms ease-out (0.22, 1, 0.36, 1); exit 200ms ease-in; reduced motion: 120ms fade.
    static func animation(opening: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return opening ? .timingCurve(0.22, 1, 0.36, 1, duration: 0.28) : .easeIn(duration: 0.20)
    }

    /// Swipe-down dismiss threshold: 80pt travel or a fast flick.
    static func shouldDismiss(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation >= 80 || predicted >= 220
    }
}

struct GroupInfoSubmenu<Content: View>: View {
    let category: GroupInfoCategory
    let height: CGFloat
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragY: CGFloat = 0
    @AccessibilityFocusState private var titleFocused: Bool

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: 24, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content()
                .id(category)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: category)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            // Same warm bloom ground as every other screen (not a flat dark fill).
            ZStack {
                shape.fill(Theme.bgPage)
                shape.fill(RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                                          center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380))
                shape.fill(RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                                          center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340))
            }
        )
        .overlay(shape.stroke(Theme.parchment.opacity(0.14), lineWidth: 1))
        .clipShape(shape)
        .offset(y: max(0, dragY))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(category.title)
        .accessibilityIdentifier("group-info-panel")
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: "\(category.title) list")
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.parchment.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
            HStack {
                Text(category.title)
                    .font(.inter(17, weight: .semibold))
                    .foregroundColor(Theme.parchment)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.parchment.opacity(0.8))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(category.title)")
            }
            .padding(.leading, Theme.spacingMD)
            .padding(.trailing, 4)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { dragY = $0.translation.height }
                .onEnded { v in
                    if GroupInfoPanelMotion.shouldDismiss(translation: v.translation.height,
                                                          predicted: v.predictedEndTranslation.height) {
                        onClose()
                    }
                    withMotionAwareAnimation(.easeOut(duration: 0.2), reduceMotion: reduceMotion) { dragY = 0 }
                }
        )
    }
}
