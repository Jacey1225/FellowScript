// PushPromptStore.swift -- task 20261105-push-prompt-sheet.
//
// Pure logic for the in-app push-notification prompt sheet: ask counts, the
// 7/14/30-day snooze cadence, the denied-variant cap, counter reset and the
// authorization-status to sheet-state mapping. Foundation + UserNotifications
// only (no SwiftUI) so it stays unit-testable as a plain script. The
// @MainActor coordinator lives in PushPromptCoordinator.swift.

import Foundation
import UserNotifications

/// What the sheet should show right now.
enum PushPromptState: Equatable {
    case hidden
    case primer        // .notDetermined: value-moment primer
    case openSettings  // .denied: point the user at iOS Settings
}

/// Inputs that block the sheet regardless of eligibility. Built fresh by the
/// caller on every evaluation; never cached.
struct PushPromptSuppression: Equatable {
    var postTourPromptOwed = false      // first launch / post-tour primer still owns notifications
    var postTourAnsweredThisSession = false
    var inCall = false
    var readingSession = false
    var loadingScreen = false
    var otherPresentationActive = false // onboarding, terms, profile, update nudge, etc.

    var isSuppressed: Bool {
        postTourPromptOwed || postTourAnsweredThisSession || inCall
            || readingSession || loadingScreen || otherPresentationActive
    }
}

struct PushPromptStore {
    static let askCountKey         = "pushPromptAskCount"
    static let nextEligibleAtKey   = "pushPromptNextEligibleAt"
    static let deniedAskCountKey   = "pushPromptDeniedAskCount"

    /// Days to wait after ask number 1, 2, 3 respectively. The cap of
    /// `maxPrimerAsks` means the third interval is stored but ends the run.
    static let primerSnoozeDays: [Int] = [7, 14, 30]
    static let deniedSnoozeDays: [Int] = [7, 14]
    static var maxPrimerAsks: Int { primerSnoozeDays.count }
    static var maxDeniedAsks: Int { deniedSnoozeDays.count }

    var defaults: UserDefaults = .standard
    /// Device clock; injectable for tests.
    var now: () -> Date = { Date() }

    var askCount: Int { defaults.integer(forKey: Self.askCountKey) }
    var deniedAskCount: Int { defaults.integer(forKey: Self.deniedAskCountKey) }

    private var nextEligibleAt: Date? {
        let t = defaults.double(forKey: Self.nextEligibleAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// True when a sheet of `state` may be shown now: under its cap and past
    /// any snooze. `.hidden` is never eligible.
    func isEligible(for state: PushPromptState) -> Bool {
        switch state {
        case .hidden:       return false
        case .primer:       guard askCount < Self.maxPrimerAsks else { return false }
        case .openSettings: guard deniedAskCount < Self.maxDeniedAsks else { return false }
        }
        if let next = nextEligibleAt, now() < next { return false }
        return true
    }

    /// Records that a sheet was presented and starts the snooze. Counting at
    /// presentation (not on a button) means any dismissal, including a swipe,
    /// behaves as "Not now".
    func recordAsk(for state: PushPromptState) {
        let days: Int
        switch state {
        case .hidden:
            return
        case .primer:
            let n = askCount + 1
            defaults.set(n, forKey: Self.askCountKey)
            days = Self.primerSnoozeDays[min(n, Self.primerSnoozeDays.count) - 1]
        case .openSettings:
            let n = deniedAskCount + 1
            defaults.set(n, forKey: Self.deniedAskCountKey)
            days = Self.deniedSnoozeDays[min(n, Self.deniedSnoozeDays.count) - 1]
        }
        let next = now().addingTimeInterval(TimeInterval(days) * 86_400)
        defaults.set(next.timeIntervalSince1970, forKey: Self.nextEligibleAtKey)
    }

    /// Permission is granted: forget all cadence state.
    func clearCounters() {
        defaults.removeObject(forKey: Self.askCountKey)
        defaults.removeObject(forKey: Self.deniedAskCountKey)
        defaults.removeObject(forKey: Self.nextEligibleAtKey)
    }
}

/// Status-to-state mapping. Pure; fail closed on anything unrecognised.
enum PushPromptMapping {
    /// The sheet kind the status calls for, ignoring cadence and suppression.
    /// `pushDeferred == false` with `.notDetermined` means the system dialog
    /// is about to fire from requestPushNotifications(): stay hidden so the
    /// two never race.
    static func kind(for status: UNAuthorizationStatus, pushDeferred: Bool) -> PushPromptState {
        switch status {
        case .notDetermined: return pushDeferred ? .primer : .hidden
        case .denied:        return .openSettings
        case .authorized, .provisional, .ephemeral: return .hidden
        @unknown default:    return .hidden
        }
    }

    /// Whether the status means permission is on (counters should reset).
    static func isGranted(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        @unknown default: return false
        }
    }

    /// Full decision for a fresh evaluation (nothing currently showing).
    static func resolve(status: UNAuthorizationStatus,
                        pushDeferred: Bool,
                        suppression: PushPromptSuppression,
                        store: PushPromptStore) -> PushPromptState {
        let kind = kind(for: status, pushDeferred: pushDeferred)
        guard kind != .hidden, !suppression.isSuppressed, store.isEligible(for: kind) else { return .hidden }
        return kind
    }
}
