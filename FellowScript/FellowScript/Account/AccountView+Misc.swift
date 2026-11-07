// AccountView+Misc.swift — Privacy & Safety (blocked users entry point),
// Legal (privacy policy/terms/version), Sign Out, Danger Zone (delete
// account), and the pull-to-refresh reload method. Split out of
// AccountView.swift (readability #6, 20260904-frontend-arch-sweep) -- same
// type, same behavior, just this section's own file. See AccountView.swift's
// header comment for the full split rationale and the list of sibling
// section files.

import SwiftUI
import UserNotifications

extension AccountView {

    var privacySafetySection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Privacy & Safety")
            Button(action: { showBlockedUsers = true }) {
                HStack {
                    Label("Blocked Users", systemImage: "hand.raised")
                        .font(.system(size: Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .accessibilityLabel("Manage blocked users")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    /// Task 20261012-notification-settings: entry row to the Notifications sub-page.
    /// Task 20261105-onboarding-redo: replay the guided walkthrough. Hidden while one is running.
    @ViewBuilder var replayOnboardingSection: some View {
        if OnboardingEngine.shared.isChatTour {
            ChatTourEndRow()   // task 20261106-chat-tour: always a way out of a stuck chat tour
        } else if !OnboardingEngine.shared.isActive && !OnboardingEngine.shared.blocksPostTourPrompts {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                sectionLabel("Guided tour")
                Button(action: { showReplaySurvey = true }) {
                    HStack {
                        Label("Replay onboarding", systemImage: "play.circle")
                            .font(.system(size: Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Replay onboarding")
                .accessibilityHint("Pick what you want help with and walk through it again")
                ChatTourReplayRow()   // task 20261106-chat-tour; empty unless the flag is on
                Text("Walk through the parts of the app you want help with, step by step.")
                    .font(.system(size: Theme.fontXS))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .glassCard(cornerRadius: 20)
        }
    }

    var notificationsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Notifications")
            Button(action: { showNotificationSettings = true }) {
                HStack {
                    Label("Notification settings", systemImage: "bell")
                        .font(.system(size: Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .onboardingAnchor(.notificationSettingsRow)
            .accessibilityLabel("Notification settings")
            .accessibilityHint("Choose which push notifications you receive")

            // Task 20261105-push-prompt-sheet: .provisional users get quiet
            // delivery only. No sheet; a low-key row that opens iOS Settings
            // (no requestAuthorization call).
            if pushIsProvisional {
                Divider().background(Theme.borderGray)
                Button(action: openSystemNotificationSettings) {
                    HStack {
                        Label("Turn on alerts", systemImage: "bell.badge")
                            .font(.system(size: Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Turn on alerts")
                .accessibilityHint("Opens iOS Settings so notifications can show as alerts")
                .accessibilityIdentifier("account.turnOnAlerts")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    @MainActor
    func refreshPushProvisional() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        pushIsProvisional = (status == .provisional)
    }

    func openSystemNotificationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    var legalSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Legal")

            Link(destination: URL(string: "https://fellowscript.com/#/privacy")!) {
                HStack {
                    Label("Privacy Policy", systemImage: "hand.raised")
                        .font(.system(size: Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .accessibilityLabel("Open Privacy Policy")
            Divider().background(Theme.borderGray)

            Link(destination: URL(string: "https://fellowscript.com/#/terms")!) {
                HStack {
                    Label("Terms of Service", systemImage: "doc.text")
                        .font(.system(size: Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .accessibilityLabel("Open Terms of Service")
            Divider().background(Theme.borderGray)

            HStack {
                Label("Version", systemImage: "info.circle")
                    .font(.system(size: Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    .font(.system(size: Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    // Kept as its own standalone, neutral (non-danger-tinted) card — a distinct,
    // low-risk action that shouldn't visually escalate to Danger Zone's red severity.
    var signOutSection: some View {
        Button(action: appState.signOut) {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                .foregroundColor(Theme.error)
                .font(.system(size: Theme.fontBody))
        }
        .accessibilityLabel("Sign out of your account")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    var dangerZone: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Danger Zone")
                .font(.system(size: 11, weight: .semibold)).tracking(1)
                .foregroundColor(Theme.error.opacity(0.85))

            Text("Permanently deletes your account, all notes, highlights, and removes you from all groups and friend lists. This cannot be undone.")
                .font(.system(size: Theme.fontSM))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { showDeleteSheet = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Delete My Account").font(.system(size: Theme.fontSM, weight: .semibold))
                }
                .foregroundColor(Theme.error)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .overlay(Capsule().stroke(Theme.errorStrong, lineWidth: 1))
            }
            .accessibilityLabel("Delete account button")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(tint: Theme.dangerBg, border: [Color.white.opacity(0.12), Theme.borderDanger])
    }

    /// Pull-to-refresh's reload method (task
    /// 20260831-interaction-polish-conventions): re-runs the profile/agents/
    /// events/usage/friend-requests fetch (`vm.load`) and the subscription
    /// fetch (`vm.loadSubscription`), same as `.task` above, then reseeds
    /// this screen's local @State fields from the freshly-fetched profile —
    /// identical to `.task`'s own seeding. Deliberately does NOT re-run
    /// `store.startListening()`/`loadProducts()`/`syncEntitlements()`: those
    /// are one-time StoreKit session bootstrapping for this app launch, not
    /// this screen's own "reload my data" concern, and re-invoking entitlement
    /// sync on every pull-to-refresh would be new business logic beyond
    /// "wiring the existing reload method into `.refreshable`" (out of this
    /// task's bounds) with its own side effects worth not introducing here.
    func refreshAccountData() async {
        guard let user = appState.currentUser else { return }
        await vm.load(service: appState.service, user: user)
        let freshUser = vm.profileData ?? user
        username   = freshUser.username
        email      = freshUser.email
        timezone   = freshUser.timezone
        mfaEnabled = freshUser.mfa_enabled
        await vm.loadSubscription(userId: user.user_id)
    }

    /// Friend-request push tap (task 20261016-push-notifications-and-ui): jump to the
    /// Friend Requests section (no animation under Reduce Motion) and reload the list.
    func consumePendingFriendRequestsOpen(_ proxy: ScrollViewProxy) {
        guard appState.pendingFriendRequestsOpen else { return }
        appState.pendingFriendRequestsOpen = false
        DispatchQueue.main.async {
            if reduceMotion { proxy.scrollTo("friendRequestsSection", anchor: .top) }
            else { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("friendRequestsSection", anchor: .top) } }
        }
        Task { await refreshAccountData() }
    }
}
