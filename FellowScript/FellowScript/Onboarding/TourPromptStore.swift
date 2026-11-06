// TourPromptStore.swift -- task 20261105-take-tour-prompt.
//
// Pure logic for the in-app "Take a quick tour" prompt shown to signed-in users
// whose first-run walkthrough ended without finishing any part. Foundation only
// (no SwiftUI) so it stays unit-testable as a plain script. The @MainActor
// coordinator lives in TourPromptCoordinator.swift. Mirrors PushPromptStore.
//
// Marker: `tourPromptOutcome.v1` is written by OnboardingEngine.finishRecap for
// a FIRST-RUN flow only (never replay). Absent or unrecognised = never prompt
// (fail closed): that covers users who finished the old 12-step tour and anyone
// who skipped before this build shipped (the outcome was never saved).

import Foundation

enum TourPromptOutcome: String {
    case completed
    case skipped
}

/// Inputs that block the prompt regardless of eligibility. Built fresh by the
/// caller on every evaluation; never cached. Strict priority: walkthrough,
/// add-a-friend and recap, then post-tour covers, then the push sheet, then
/// this prompt. Never two at once.
struct TourPromptSuppression: Equatable {
    var walkthroughActive = false           // first-run flow live, or ran this session
    var replayActive = false                // a replay is running (startReplay would no-op)
    var postTourOwed = false                // post-tour notifications/subscribe cover showing or owed
    var postTourSeenThisSession = false
    var pushPromptActive = false            // push sheet visible or about to be
    var pushPromptShownThisSession = false
    var inCall = false
    var readingSession = false              // phone layout, not on Home
    var loadingScreen = false
    var otherPresentationActive = false     // not signed in, terms, profile, invite, update nudge

    var isSuppressed: Bool {
        walkthroughActive || replayActive || postTourOwed || postTourSeenThisSession
            || pushPromptActive || pushPromptShownThisSession || inCall
            || readingSession || loadingScreen || otherPresentationActive
    }
}

struct TourPromptStore {
    static let outcomeKey        = "tourPromptOutcome.v1"
    static let askCountKey       = "tourPromptAskCount"
    static let nextEligibleAtKey = "tourPromptNextEligibleAt"
    static let resolvedKey       = "tourPromptResolved"

    /// Days to wait after ask number 1, 2, 3. The cap of `maxAsks` means the
    /// third interval is stored but ends the run.
    static let tourPromptSnoozeDays: [Int] = [7, 14, 30]
    static var maxAsks: Int { tourPromptSnoozeDays.count }

    /// Local flag (same pattern as WorkspaceLayout): UserDefaults key with a
    /// single default constant. Flag off = never shown; the outcome is still
    /// recorded so turning it on later works. Flip the default to ship dark.
    static let featureFlagKey = "tourPromptEnabled"
    static let featureFlagDefault = true

    /// Extra launch argument that lets UI tests drive the prompt; it is
    /// otherwise suppressed under "UI-TESTING" so existing flows are unchanged.
    static let uiTestEnableArgument = "UI-TESTING-TOUR-PROMPT"

    var defaults: UserDefaults = .standard
    var arguments: [String] = ProcessInfo.processInfo.arguments
    /// Device clock; injectable for tests.
    var now: () -> Date = { Date() }

    private var suppressedForUITests: Bool {
        arguments.contains("UI-TESTING") && !arguments.contains(Self.uiTestEnableArgument)
    }

    static func isFeatureEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: featureFlagKey) == nil ? featureFlagDefault : defaults.bool(forKey: featureFlagKey)
    }

    var isFeatureEnabled: Bool { Self.isFeatureEnabled(defaults) }

    /// nil when absent or unrecognised.
    var outcome: TourPromptOutcome? {
        defaults.string(forKey: Self.outcomeKey).flatMap(TourPromptOutcome.init(rawValue:))
    }

    var askCount: Int { defaults.integer(forKey: Self.askCountKey) }
    var isResolved: Bool { defaults.bool(forKey: Self.resolvedKey) }

    private var nextEligibleAt: Date? {
        let t = defaults.double(forKey: Self.nextEligibleAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// First-run flow ended. "Skipped" means zero parts completed; finishing at
    /// least one part counts as completed. Never call for a replay. No-op under
    /// plain UI-TESTING so tests never write real state.
    func recordFirstRunOutcome(completedParts: Int) {
        guard !suppressedForUITests else { return }
        let value: TourPromptOutcome = completedParts > 0 ? .completed : .skipped
        defaults.set(value.rawValue, forKey: Self.outcomeKey)
        defaults.removeObject(forKey: Self.askCountKey)
        defaults.removeObject(forKey: Self.nextEligibleAtKey)
        defaults.removeObject(forKey: Self.resolvedKey)
    }

    /// True when the prompt may be shown now: flag on, outcome is exactly
    /// `.skipped`, not resolved, under the cap and past any snooze.
    func isEligible() -> Bool {
        guard !suppressedForUITests, isFeatureEnabled, outcome == .skipped, !isResolved,
              askCount < Self.maxAsks else { return false }
        if let next = nextEligibleAt, now() < next { return false }
        return true
    }

    /// Records that the prompt was presented and starts the snooze. Counting at
    /// presentation means tap-out, swipe-down and "Not now" are one code path.
    func recordAsk() {
        let n = askCount + 1
        defaults.set(n, forKey: Self.askCountKey)
        let days = Self.tourPromptSnoozeDays[min(n, Self.tourPromptSnoozeDays.count) - 1]
        let next = now().addingTimeInterval(TimeInterval(days) * 86_400)
        defaults.set(next.timeIntervalSince1970, forKey: Self.nextEligibleAtKey)
    }

    /// Primary button: permanent, never asks again.
    func markResolved() {
        defaults.set(true, forKey: Self.resolvedKey)
    }

    /// Full decision for a fresh evaluation (nothing currently showing).
    func shouldPresent(suppression: TourPromptSuppression) -> Bool {
        !suppression.isSuppressed && isEligible()
    }
}
