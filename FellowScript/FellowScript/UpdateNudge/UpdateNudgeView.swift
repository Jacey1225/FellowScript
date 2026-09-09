// Dismissible "an update is available" nudge. Presented by ContentView as a
// sheet once StartupCoordinator.updateAvailable is set (VersionGateService
// confirmed the installed version is behind what's live on the App Store)
// AND the startup readiness race has already resolved — so this never
// overlaps/competes with LoadingScreenView, only ever appearing once the
// user has actually reached mainTabView.
//
// Styled as a compact card sheet, matching this repo's existing dismissible-
// sheet conventions (SessionCreatorSheet.swift, MfaSheets.swift) rather than
// introducing a new presentation style — drag handle, Theme.bgPage ground,
// PillButton for the primary action. A dismissible nudge, not a blocking
// gate (Preference profile UI/UX Q10): no navigation chrome, no
// non-dismissible affordance, "Not Now" always available.
//
// DEPENDENCY: Theme.swift, PillButton.swift (PillButton), VersionGateService.swift,
// StartupCoordinator.swift, ContentView.swift

import SwiftUI

struct UpdateNudgeView: View {
    let update: AppUpdateInfo
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var iconAppeared = false

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            VStack(spacing: Theme.spacingLG) {
                dragHandle

                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(Theme.goldGradient)
                    .scaleEffect(iconAppeared ? 1 : 0.6)
                    .opacity(iconAppeared ? 1 : 0)
                    // Rich-but-not-robotic entrance (Preference profile
                    // UI/UX Q9) — a spring, tuned for this one small glyph
                    // rather than reusing ContentView's crossfade/notice
                    // timings verbatim.
                    .motionAwareAnimation(.spring(response: 0.40, dampingFraction: 0.68), value: iconAppeared, reduceMotion: reduceMotion)
                    .onAppear { iconAppeared = true }
                    .accessibilityHidden(true)

                VStack(spacing: Theme.spacingSM) {
                    Text("A new version of FellowScript is here")
                        .font(.playfair(Theme.fontDisplayMD))
                        .foregroundColor(Theme.parchment)
                        .multilineTextAlignment(.center)

                    // Minimal, non-technical, warm copy (Preference profile
                    // UI/UX Q17) — no version-compare jargon beyond the
                    // number itself.
                    Text("Update to version \(update.latestVersion) for the latest improvements and fixes.")
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.spacingLG)
                }

                Spacer(minLength: Theme.spacingSM)

                PillButton(title: "Update Now", systemIcon: "arrow.up.circle") {
                    openURL(update.storeURL)
                    onDismiss()
                }
                .accessibilityLabel("Update Now, opens the App Store")

                Button("Not Now", action: onDismiss)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textGoldMuted)
                    .padding(.bottom, Theme.spacingSM)
                    .accessibilityLabel("Not now, dismiss this update reminder")
            }
            .padding(.horizontal, Theme.spacingLG)
            .padding(.top, 4)
            .padding(.bottom, Theme.spacingLG)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(Theme.radiusXXL)
        .preferredColorScheme(.dark)
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.2))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .accessibilityHidden(true)
    }
}
