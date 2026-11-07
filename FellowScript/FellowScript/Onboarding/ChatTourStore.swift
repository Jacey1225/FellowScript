// ChatTourStore.swift -- task 20261106-chat-tour.
//
// Pure logic (Foundation only, unit-testable as a plain script) for the Chat tab
// offer to take the chat tour: the feature flag, the persisted offer state, and
// the strict-priority gate that decides whether the offer may show right now.
// Progress through the tour itself lives in OnboardingProgressStore (own slot).
//
// This file never reads or writes TourPromptStore or PostTourPromptsStore keys.
// Fail closed: a missing or unreadable value never produces an offer.

import Foundation

/// Persisted lifecycle of the Chat tab offer. Absent = never offered.
/// Any stored value, recognised or not, means "do not offer again".
enum ChatTourOfferState: String {
    case shown        // card was presented; one dismissal is permanent
    case dismissed
    case started      // tour started (from the offer or from Account)
    case completed
}

/// Why the offer is held back, listed in strict priority order: the first
/// matching reason wins. Chat tour is the lowest priority of everything.
enum ChatTourOfferBlock: Int, CaseIterable, Comparable {
    case walkthrough       // first-run walkthrough/recap, or any tour state, is live
    case postTourPrompts   // post-tour notifications/subscribe cover showing, owed or seen this session
    case pushPrompt        // push sheet visible, about to be, or shown this session
    case tourPrompt        // "take the tour" prompt presented or eligible
    case otherPresentation // call, loading, not signed in, terms, profile, invite, update nudge
    case notOnChatTab      // the offer only appears when the Chat tab opens

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Inputs built fresh on every evaluation by the host, never cached.
struct ChatTourOfferSuppression: Equatable {
    var walkthroughActive = false       // engine has any state (first-run, replay or chat tour)
    var firstRunBlocking = false        // engine.blocksPostTourPrompts
    var postTourOwed = false
    var postTourSeenThisSession = false
    var pushPromptActive = false
    var pushPromptShownThisSession = false
    var tourPromptPresented = false
    var tourPromptEligible = false
    var inCall = false
    var loadingScreen = false
    var otherPresentationActive = false
    var onChatTab = false

    /// Highest-priority reason the offer is held back, or nil if it may show.
    var blockingReason: ChatTourOfferBlock? {
        if walkthroughActive || firstRunBlocking { return .walkthrough }
        if postTourOwed || postTourSeenThisSession { return .postTourPrompts }
        if pushPromptActive || pushPromptShownThisSession { return .pushPrompt }
        if tourPromptPresented || tourPromptEligible { return .tourPrompt }
        if inCall || loadingScreen || otherPresentationActive { return .otherPresentation }
        if !onChatTab { return .notOnChatTab }
        return nil
    }
}

struct ChatTourStore {
    static let offerStateKey = "chatTourOfferState.v1"

    /// Local flag (same pattern as TourPromptStore). Ships DARK: the default is
    /// off until Jacey approves. An unreadable value reads as off.
    static let featureFlagKey = "chatTourEnabled"
    static let featureFlagDefault = false

    /// Opt-in launch argument; the offer is otherwise suppressed under "UI-TESTING".
    static let uiTestEnableArgument = "UI-TESTING-CHAT-TOUR"

    var defaults: UserDefaults = .standard
    var arguments: [String] = ProcessInfo.processInfo.arguments

    private var suppressedForUITests: Bool {
        arguments.contains("UI-TESTING") && !arguments.contains(Self.uiTestEnableArgument)
    }

    static func isFeatureEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: featureFlagKey) == nil ? featureFlagDefault : defaults.bool(forKey: featureFlagKey)
    }

    var isFeatureEnabled: Bool { Self.isFeatureEnabled(defaults) }

    /// Whether the Account "Chat tour" row may show (flag only; the host also
    /// hides it while the engine is active).
    var isEntryAvailable: Bool { isFeatureEnabled }

    /// nil when never offered. A stored but unrecognised value is `.dismissed`
    /// (fail closed), never nil.
    var offerState: ChatTourOfferState? {
        guard defaults.object(forKey: Self.offerStateKey) != nil else { return nil }
        return defaults.string(forKey: Self.offerStateKey).flatMap(ChatTourOfferState.init(rawValue:)) ?? .dismissed
    }

    /// Flag on, never offered before, not a plain UI test.
    func isEligible() -> Bool {
        !suppressedForUITests && isFeatureEnabled && offerState == nil
    }

    func shouldOffer(suppression: ChatTourOfferSuppression) -> Bool {
        suppression.blockingReason == nil && isEligible()
    }

    /// Counted at presentation, so tap-out, swipe and Dismiss are one path.
    func recordShown() { write(.shown) }

    /// Dismiss is permanent, but never downgrades a started or completed tour.
    func recordDismissed() {
        guard offerState == nil || offerState == .shown else { return }
        write(.dismissed)
    }

    func recordStarted() {
        guard offerState != .completed else { return }
        write(.started)
    }

    func recordCompleted() { write(.completed) }

    private func write(_ s: ChatTourOfferState) {
        defaults.set(s.rawValue, forKey: Self.offerStateKey)
    }
}
