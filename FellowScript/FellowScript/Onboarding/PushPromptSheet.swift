// PushPromptSheet.swift -- task 20261105-push-prompt-sheet.
//
// Value-moment bottom sheet that asks for push notifications (primer, for
// .notDetermined) or points to iOS Settings (.denied). Presented by
// DashboardView from PushPromptCoordinator.state. Design: approved
// mockup-v2.png. Fonts match the shipped Home (system SF for buttons, Inter
// Bold headline like WaysToExploreSection), never Playfair.
//
// DEPENDENCY: Theme.swift, PillButton.swift, PushPromptStore.swift,
// PushPromptCoordinator.swift

import SwiftUI
import UIKit

// Lets the coordinator state drive `.sheet(item:)`. `.hidden` is never presented.
extension PushPromptState: Identifiable {
    var id: String {
        switch self {
        case .hidden:       return "hidden"
        case .primer:       return "primer"
        case .openSettings: return "openSettings"
        }
    }
}

struct PushPromptSheet: View {
    let kind: PushPromptState
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @AccessibilityFocusState private var headlineFocused: Bool

    private var isSettings: Bool { kind == .openSettings }
    private var headline: String { isSettings ? "Notifications are off" : "Hear back from your group" }
    private var message: String {
        isSettings
            ? "You'll miss group replies and your daily devotion. You can switch them on in Settings."
            : "Turn on notifications and we'll tell you when someone replies in your study group. No marketing, ever."
    }
    private var primaryTitle: String { isSettings ? "Open Settings" : "Turn on notifications" }
    private var secondaryTitle: String { isSettings ? "Dismiss" : "Not now" }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacingLG) {
                bell

                VStack(spacing: Theme.spacingSM) {
                    Text(headline)
                        .font(.interScaled(Theme.fontDisplayMD, weight: .bold, relativeTo: .title2))
                        .foregroundColor(Color(hex: "#FFF8EE"))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headlineFocused)
                        .accessibilityIdentifier("pushPrompt.headline")

                    Text(message)
                        .font(.interScaled(Theme.fontBody, relativeTo: .body))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: Theme.spacingSM) {
                    PillButton(title: primaryTitle, fullWidth: true, minHeight: 52, action: onPrimary)
                        .accessibilityIdentifier("pushPrompt.primary")

                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.parchment.opacity(0.8))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pushPrompt.secondary")
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
        .accessibilityIdentifier("pushPrompt.sheet")
        .onAppear {
            appeared = true
            // Let the sheet finish presenting before moving VoiceOver focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { headlineFocused = true }
        }
    }

    /// Gold ring bell (crossed in the denied variant). Meaning is carried by
    /// the icon and the text, not by gold alone. Decorative for VoiceOver.
    private var bell: some View {
        Image(systemName: isSettings ? "bell.slash" : "bell")
            .font(.system(size: 26, weight: .semibold))
            .foregroundColor(Theme.gold)
            .frame(width: 64, height: 64)
            .overlay(Circle().stroke(Theme.gold, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}
