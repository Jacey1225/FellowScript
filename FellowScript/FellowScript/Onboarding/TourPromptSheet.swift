// TourPromptSheet.swift -- task 20261105-take-tour-prompt.
//
// Bottom sheet offering the onboarding walkthrough to someone who skipped it.
// Reuses the PushPromptSheet scaffold as-is (same gradient, type, PillButton,
// reduce-motion fade, VoiceOver focus, 44pt+ targets, medium detent). Hosted by
// ContentView from TourPromptCoordinator.isPresented.
//
// DEPENDENCY: Theme.swift, PillButton.swift, TourPromptCoordinator.swift

import SwiftUI
import UIKit

struct TourPromptSheet: View {
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @AccessibilityFocusState private var headlineFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacingLG) {
                icon

                VStack(spacing: Theme.spacingSM) {
                    Text("Take a quick tour")
                        .font(.interScaled(Theme.fontDisplayMD, weight: .bold, relativeTo: .title2))
                        .foregroundColor(Color(hex: "#FFF8EE"))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headlineFocused)
                        .accessibilityIdentifier("tourPrompt.headline")

                    Text("A couple of minutes to see how to write a devotion, add a friend and find your way around. You choose what to see.")
                        .font(.interScaled(Theme.fontBody, relativeTo: .body))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: Theme.spacingSM) {
                    PillButton(title: "Start the tour", fullWidth: true, minHeight: 52, action: onPrimary)
                        .accessibilityIdentifier("tourPrompt.primary")

                    Button(action: onSecondary) {
                        Text("Not now")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.parchment.opacity(0.8))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tourPrompt.secondary")
                }
            }
            .padding(.horizontal, Theme.spacingLG)
            .padding(.top, Theme.spacingLG)
            .padding(.bottom, Theme.spacingMD)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.97))
            // Reduce Motion keeps a plain fade; no scale.
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3), value: appeared)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(
            LinearGradient(
                colors: [Color(hex: "#43301A"), Color(hex: "#2A1E11"), Color(hex: "#120D08")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Theme.radiusXXL)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("tourPrompt.sheet")
        .onAppear {
            appeared = true
            // Let the sheet finish presenting before moving VoiceOver focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { headlineFocused = true }
        }
    }

    /// Gold ring icon; meaning is carried by the text. Decorative for VoiceOver.
    private var icon: some View {
        Image(systemName: "map")
            .font(.system(size: 26, weight: .semibold))
            .foregroundColor(Theme.gold)
            .frame(width: 64, height: 64)
            .overlay(Circle().stroke(Theme.gold, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}
