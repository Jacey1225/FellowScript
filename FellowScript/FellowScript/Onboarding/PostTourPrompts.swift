// PostTourPrompts.swift — task 20261008-post-tour-prompts.
//
// First-run coordinator for the two prompts shown once, in order, after a
// brand-new install finishes the onboarding tour AND signs in/up:
//   1. a notifications pre-prompt ("Enable notifications" / "Maybe later")
//   2. a subscribe prompt (StoreKit purchase / "Continue with free plan")
//
// Placement: they follow auth (a purchase needs a user id), once the main
// screen is ready (see ContentView). Existing users never see them: the
// pending flag is only ever set while onboarding has NOT completed, so an
// update from a build that already finished onboarding never arms it.
//
// All persistence/gating logic lives in `PostTourPromptsStore` (injectable
// UserDefaults, unit-testable). The views are in PostTourPromptViews.swift.

import SwiftUI
import Combine
import UserNotifications

enum PostTourPrompt: String, Identifiable {
    case notifications, subscribe
    var id: String { rawValue }
}

struct PostTourPromptsStore {
    static let pendingKey         = "postTourPromptsPending"
    static let pushDeferredKey    = "postTourPushDeferred"
    static let notificationsDoneKey = "postTourNotificationsDone"
    static let subscribeDoneKey   = "postTourSubscribeDone"
    /// Extra launch argument that lets UI tests drive the prompts; they are
    /// otherwise suppressed under "UI-TESTING" so existing onboarding tests
    /// keep their exact flow.
    static let uiTestEnableArgument = "UI-TESTING-POST-TOUR"

    var defaults: UserDefaults = .standard
    var arguments: [String] = ProcessInfo.processInfo.arguments

    private var suppressedForUITests: Bool {
        arguments.contains("UI-TESTING") && !arguments.contains(Self.uiTestEnableArgument)
    }

    /// Arms the flow for a genuinely new install: call while onboarding has
    /// not completed. Does nothing once onboarding is done (existing users)
    /// or if the flow already ran.
    func armIfNeeded(onboardingCompleted: Bool) {
        guard !suppressedForUITests, !onboardingCompleted else { return }
        guard !defaults.bool(forKey: Self.notificationsDoneKey),
              !defaults.bool(forKey: Self.subscribeDoneKey) else { return }
        defaults.set(true, forKey: Self.pendingKey)
        defaults.set(true, forKey: Self.pushDeferredKey)
    }

    /// While true, `AppState.requestPushNotifications()` must not show the
    /// system dialog (the pre-prompt owns it). Cleared only by the user
    /// choosing "Enable notifications" (or a later explicit enable action).
    var defersSystemPushDialog: Bool {
        !suppressedForUITests && defaults.bool(forKey: Self.pushDeferredKey)
    }

    func clearPushDeferral() {
        defaults.set(false, forKey: Self.pushDeferredKey)
    }

    /// The next prompt still owed, or nil when nothing is pending.
    func nextPrompt() -> PostTourPrompt? {
        guard !suppressedForUITests, defaults.bool(forKey: Self.pendingKey) else { return nil }
        if !defaults.bool(forKey: Self.notificationsDoneKey) { return .notifications }
        if !defaults.bool(forKey: Self.subscribeDoneKey) { return .subscribe }
        defaults.set(false, forKey: Self.pendingKey)
        return nil
    }

    /// `enabled == true` lifts the push deferral; "Maybe later" leaves it in
    /// place so the system dialog never fires on its own afterwards.
    func markNotificationsDone(enabled: Bool) {
        defaults.set(true, forKey: Self.notificationsDoneKey)
        if enabled { clearPushDeferral() }
        finishIfComplete()
    }

    func markSubscribeDone() {
        defaults.set(true, forKey: Self.subscribeDoneKey)
        finishIfComplete()
    }

    private func finishIfComplete() {
        if defaults.bool(forKey: Self.notificationsDoneKey),
           defaults.bool(forKey: Self.subscribeDoneKey) {
            defaults.set(false, forKey: Self.pendingKey)
        }
    }
}

@MainActor
final class PostTourPromptsCoordinator: ObservableObject {
    @Published var current: PostTourPrompt?
    let store: PostTourPromptsStore

    init(store: PostTourPromptsStore = PostTourPromptsStore()) {
        self.store = store
    }

    /// Presents the next owed prompt, skipping any whose purpose is already
    /// satisfied. Safe to call repeatedly.
    func evaluate() async {
        guard current == nil else { return }
        while let next = store.nextPrompt() {
            switch next {
            case .notifications:
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                if status != .notDetermined {
                    // Already decided (or granted): nothing to ask. Granted
                    // users keep the normal register-on-foreground path.
                    store.markNotificationsDone(enabled: status != .denied)
                    continue
                }
            case .subscribe:
                // Fail-closed on the prompt, not on access: if StoreKit shows
                // an active entitlement the upsell is pointless; otherwise
                // the user stays on the free plan until a verified purchase.
                if !(await StoreKitManager.shared.activeEntitlementProductIDs()).isEmpty {
                    store.markSubscribeDone()
                    continue
                }
            }
            current = next
            return
        }
    }

    /// Called by a prompt view when the user finishes it by any action.
    func finish(_ prompt: PostTourPrompt, notificationsEnabled: Bool = false) {
        switch prompt {
        case .notifications: store.markNotificationsDone(enabled: notificationsEnabled)
        case .subscribe:     store.markSubscribeDone()
        }
        current = nil
        Task {
            // Let the dismissing cover finish before presenting the next.
            try? await Task.sleep(nanoseconds: 450_000_000)
            await evaluate()
        }
    }
}
