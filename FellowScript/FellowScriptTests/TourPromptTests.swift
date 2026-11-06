// TourPromptTests.swift -- testing gate for task 20261105-take-tour-prompt.
//
// Bug class guarded: nagging users who finished (or never ran) the walkthrough,
// prompting when the outcome is unknown (must fail closed), exceeding the 3-ask
// cap, stacking on top of the push sheet / post-tour covers / walkthrough, and
// a replay launched from the prompt re-arming PostTourPromptsStore.

import XCTest
@testable import FellowScript

final class TourPromptStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "TourPromptStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store(args: [String] = []) -> TourPromptStore {
        TourPromptStore(defaults: defaults, arguments: args, now: { [unowned self] in self.clock })
    }
    private func days(_ d: Double) { clock = clock.addingTimeInterval(d * 86_400) }

    // MARK: marker states

    func testAbsentMarkerNeverPrompts_legacyAndPreShipSkippers() {
        // Legacy user: hasCompletedOnboarding true, old 12-step tour, no marker.
        defaults.set(true, forKey: "hasCompletedOnboarding")
        XCTAssertNil(store().outcome)
        XCTAssertFalse(store().isEligible())
        XCTAssertFalse(store().shouldPresent(suppression: TourPromptSuppression()))
    }

    func testUnknownOrCorruptMarkerFailsClosed() {
        for bad: Any in ["", "SKIPPED", "garbage", "skipped ", 1, true, Data("skipped".utf8)] {
            defaults.set(bad, forKey: TourPromptStore.outcomeKey)
            XCTAssertNil(store().outcome, "\(bad)")
            XCTAssertFalse(store().isEligible(), "\(bad)")
        }
    }

    func testCompletedNeverPrompts() {
        defaults.set("completed", forKey: TourPromptStore.outcomeKey)
        XCTAssertEqual(store().outcome, .completed)
        XCTAssertFalse(store().isEligible())
    }

    func testSkippedPromptsImmediately() {
        defaults.set("skipped", forKey: TourPromptStore.outcomeKey)
        XCTAssertEqual(store().outcome, .skipped)
        XCTAssertTrue(store().isEligible())
        XCTAssertTrue(store().shouldPresent(suppression: TourPromptSuppression()))
    }

    func testRecordFirstRunOutcomeZeroPartsIsSkippedOneOrMoreIsCompleted() {
        store().recordFirstRunOutcome(completedParts: 0)
        XCTAssertEqual(store().outcome, .skipped)
        store().recordFirstRunOutcome(completedParts: 1)
        XCTAssertEqual(store().outcome, .completed)
        store().recordFirstRunOutcome(completedParts: 4)
        XCTAssertEqual(store().outcome, .completed)
    }

    func testRecordOutcomeResetsCadenceState() {
        store().recordFirstRunOutcome(completedParts: 0)
        store().recordAsk(); store().markResolved()
        store().recordFirstRunOutcome(completedParts: 0)
        XCTAssertEqual(store().askCount, 0)
        XCTAssertFalse(store().isResolved)
        XCTAssertTrue(store().isEligible())
    }

    // MARK: cadence

    func testCadenceIs7Then14Then30AndConfigured() {
        XCTAssertEqual(TourPromptStore.tourPromptSnoozeDays, [7, 14, 30])
        XCTAssertEqual(TourPromptStore.maxAsks, 3)
        store().recordFirstRunOutcome(completedParts: 0)

        store().recordAsk()                       // ask 1 -> 7 days
        XCTAssertFalse(store().isEligible())
        days(6.99); XCTAssertFalse(store().isEligible())
        days(0.02); XCTAssertTrue(store().isEligible())

        store().recordAsk()                       // ask 2 -> 14 days
        days(13.99); XCTAssertFalse(store().isEligible())
        days(0.02); XCTAssertTrue(store().isEligible())

        store().recordAsk()                       // ask 3 -> cap reached
        XCTAssertEqual(store().askCount, 3)
        days(365); XCTAssertFalse(store().isEligible(), "cap of 3: never asks a 4th time")
        XCTAssertFalse(store().shouldPresent(suppression: TourPromptSuppression()))
    }

    func testThirdAskStoresThirtyDayInterval() {
        store().recordAsk(); store().recordAsk(); store().recordAsk()
        let next = defaults.double(forKey: TourPromptStore.nextEligibleAtKey)
        XCTAssertEqual(next, clock.addingTimeInterval(30 * 86_400).timeIntervalSince1970, accuracy: 1)
    }

    func testResolvedIsPermanent() {
        store().recordFirstRunOutcome(completedParts: 0)
        store().markResolved()
        XCTAssertTrue(store().isResolved)
        days(1000)
        XCTAssertFalse(store().isEligible())
    }

    // MARK: feature flag

    func testFlagDefaultOnAndOffBlocksEvenWhenEligible() {
        store().recordFirstRunOutcome(completedParts: 0)
        XCTAssertTrue(store().isFeatureEnabled)
        defaults.set(false, forKey: TourPromptStore.featureFlagKey)
        XCTAssertFalse(store().isFeatureEnabled)
        XCTAssertFalse(store().isEligible())
        XCTAssertEqual(store().outcome, .skipped, "outcome still recorded so enabling later works")
        defaults.set(true, forKey: TourPromptStore.featureFlagKey)
        XCTAssertTrue(store().isEligible())
    }

    // MARK: UI-testing suppression

    func testPlainUITestingSuppressesAndDoesNotWrite() {
        let s = store(args: ["UI-TESTING"])
        s.recordFirstRunOutcome(completedParts: 0)
        XCTAssertNil(defaults.string(forKey: TourPromptStore.outcomeKey))
        defaults.set("skipped", forKey: TourPromptStore.outcomeKey)
        XCTAssertFalse(s.isEligible())
    }

    func testOptInArgumentLiftsUITestingSuppression() {
        defaults.set("skipped", forKey: TourPromptStore.outcomeKey)
        XCTAssertTrue(store(args: ["UI-TESTING", TourPromptStore.uiTestEnableArgument]).isEligible())
    }

    // MARK: suppression ordering

    func testEachSuppressionInputBlocksIndividually() {
        store().recordFirstRunOutcome(completedParts: 0)
        let cases: [(String, WritableKeyPath<TourPromptSuppression, Bool>)] = [
            ("walkthrough", \.walkthroughActive), ("replay", \.replayActive),
            ("postTourOwed", \.postTourOwed), ("postTourSeen", \.postTourSeenThisSession),
            ("pushActive", \.pushPromptActive), ("pushShown", \.pushPromptShownThisSession),
            ("call", \.inCall), ("reading", \.readingSession),
            ("loading", \.loadingScreen), ("other", \.otherPresentationActive),
        ]
        XCTAssertFalse(TourPromptSuppression().isSuppressed)
        for (name, kp) in cases {
            var s = TourPromptSuppression(); s[keyPath: kp] = true
            XCTAssertTrue(s.isSuppressed, name)
            XCTAssertFalse(store().shouldPresent(suppression: s), name)
        }
    }

    @MainActor
    func testCoordinatorPresentsOnceCountsAskAndDoesNotRaceWithPush() {
        store().recordFirstRunOutcome(completedParts: 0)
        let c = TourPromptCoordinator(store: store())

        var push = TourPromptSuppression(); push.pushPromptActive = true
        c.evaluate(suppression: push)
        XCTAssertFalse(c.isPresented, "push sheet visible: tour prompt must wait")
        XCTAssertEqual(store().askCount, 0, "a suppressed evaluation must not burn an ask")

        var shown = TourPromptSuppression(); shown.pushPromptShownThisSession = true
        c.evaluate(suppression: shown)
        XCTAssertFalse(c.isPresented, "push sheet already shown this session")

        var postTour = TourPromptSuppression(); postTour.postTourOwed = true
        c.evaluate(suppression: postTour)
        XCTAssertFalse(c.isPresented)

        c.evaluate(suppression: TourPromptSuppression())
        XCTAssertTrue(c.isPresented)
        XCTAssertEqual(store().askCount, 1)
        c.evaluate(suppression: TourPromptSuppression())   // re-evaluation keeps one ask
        XCTAssertEqual(store().askCount, 1)

        c.dismiss()                                          // tap-out / Not now
        XCTAssertFalse(c.isPresented)
        XCTAssertFalse(store().isResolved)
        c.evaluate(suppression: TourPromptSuppression())
        XCTAssertFalse(c.isPresented, "snoozed 7 days")
    }

    @MainActor
    func testCoordinatorAcceptResolvesForGood() {
        store().recordFirstRunOutcome(completedParts: 0)
        let c = TourPromptCoordinator(store: store())
        c.evaluate(suppression: TourPromptSuppression())
        XCTAssertTrue(c.isPresented)
        c.accept()
        XCTAssertFalse(c.isPresented)
        XCTAssertTrue(store().isResolved)
        days(500)
        c.evaluate(suppression: TourPromptSuppression())
        XCTAssertFalse(c.isPresented)
    }
}

// MARK: - Engine wiring

@MainActor
final class TourPromptEngineWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TourPromptEngineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func tp(_ args: [String] = []) -> TourPromptStore { TourPromptStore(defaults: defaults, arguments: args) }
    private func engine() -> OnboardingEngine {
        OnboardingEngine(store: OnboardingProgressStore(defaults: defaults), tourPromptStore: tp(), arguments: [])
    }
    private func complete(_ part: OnboardingPart, on e: OnboardingEngine) {
        for cue in part.cues { e.report(cue.advancesOn) }
    }

    func testFirstRunSkipEverythingRecordsSkipped() {
        let e = engine()
        e.savePicks([.prayer]); e.startIfPending()
        e.skipPart(); e.skipPart()
        XCTAssertTrue(e.isRecap)
        XCTAssertNil(tp().outcome, "nothing written until recap ends")
        e.finishRecap()
        XCTAssertEqual(tp().outcome, .skipped)
        XCTAssertTrue(tp().isEligible())
    }

    func testFirstRunCompletedAllRecordsCompleted() {
        let e = engine()
        e.savePicks([.prayer]); e.startIfPending()
        complete(.prayer, on: e); complete(.friend, on: e)
        e.finishRecap()
        XCTAssertEqual(tp().outcome, .completed)
        XCTAssertFalse(tp().isEligible())
    }

    func testFirstRunPartialCountsAsCompleted() {
        let e = engine()
        e.savePicks([.prayer]); e.startIfPending()
        e.skipPart(); complete(.friend, on: e)
        e.finishRecap()
        XCTAssertEqual(tp().outcome, .completed)
    }

    /// Edge case, documents ACTUAL behavior: survey Skip -> picks [] -> friends-only
    /// flow. Skipping the friends part = skipped (prompted later). Completing the
    /// friends part = completed (the zero-parts rule), so such a user is NOT prompted.
    func testSurveySkipThenCompleteFriendsCountsAsCompleted_actualBehavior() {
        let done = engine()
        done.savePicks([]); done.startIfPending()
        complete(.friend, on: done)
        XCTAssertTrue(done.isRecap)
        done.finishRecap()
        XCTAssertEqual(tp().outcome, .completed)
        XCTAssertFalse(tp().isEligible())
    }

    func testSurveySkipThenSkipFriendsRecordsSkipped() {
        let e = engine()
        e.savePicks([]); e.startIfPending()
        e.skipPart()
        e.finishRecap()
        XCTAssertEqual(tp().outcome, .skipped)
    }

    func testFinishRecapOutsideRecapWritesNothing() {
        let e = engine()
        e.finishRecap()
        XCTAssertNil(tp().outcome)
        e.savePicks([.prayer]); e.startIfPending()
        e.finishRecap()   // mid-flow, not recap
        XCTAssertNil(tp().outcome)
    }

    func testReplayLeavesOutcomeAndPostTourKeysUntouched() {
        // Prior skipper, then replay all the way through (as the prompt's primary does).
        tp().recordFirstRunOutcome(completedParts: 0)
        let pt = PostTourPromptsStore(defaults: defaults, arguments: [])
        pt.armIfNeeded(onboardingCompleted: true)
        let beforePost = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("postTour") }
        let beforeTour = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("tourPrompt") }

        let e = engine()
        e.startReplay(picks: [.prayer])
        complete(.prayer, on: e); complete(.friend, on: e)
        XCTAssertTrue(e.isRecap)
        e.finishRecap()

        let afterPost = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("postTour") }
        let afterTour = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("tourPrompt") }
        XCTAssertEqual(NSDictionary(dictionary: beforePost), NSDictionary(dictionary: afterPost))
        XCTAssertEqual(NSDictionary(dictionary: beforeTour), NSDictionary(dictionary: afterTour),
                       "replay must not write or clear the tour prompt marker or cadence")
        XCTAssertNil(pt.nextPrompt())
        XCTAssertFalse(pt.defersSystemPushDialog)
    }

    func testReplayAfterSkipDoesNotRewriteMarker() {
        tp().recordFirstRunOutcome(completedParts: 0)
        let beforePost = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("postTour") }
        let e = engine()
        e.startReplay(picks: [])
        e.skipPart(); e.finishRecap()
        let afterPost = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("postTour") }
        XCTAssertEqual(NSDictionary(dictionary: beforePost), NSDictionary(dictionary: afterPost))
        XCTAssertEqual(tp().outcome, .skipped, "replay does not rewrite the first-run marker")
    }
}
