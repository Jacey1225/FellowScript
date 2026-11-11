// OnboardingWalkthroughTests.swift -- testing gate for task 20261105-onboarding-redo.
//
// Covers the hands-on walkthrough that replaced the screenshot tour:
//   * OnboardingFlowState: plan (picks + friends, fixed order), apply (only the
//     matching real-action event moves a cue; getting ahead is allowed; going
//     backward is not), skip, rewind, recap, Codable + resume, corrupt data.
//   * OnboardingEngine: UI-testing suppression, picks -> sign-in -> start,
//     throw-not-fabricate (failure keeps the cue), fail-closed subscription gate
//     for devotion + learn, replay isolation from PostTourPromptsStore, and the
//     ordering invariant: recap BEFORE the push and subscribe prompts.
//
// Bug class guarded: a cue advancing without a real success, a free user being
// walked into a paid feature, replay re-arming first-run prompts, or the push
// deferral being lifted by the walkthrough.

import XCTest
@testable import FellowScript

// MARK: - Pure flow state

final class OnboardingFlowStateTests: XCTestCase {

    private func complete(_ part: OnboardingPart, in s: inout OnboardingFlowState) {
        for cue in part.cues { s.apply(cue.advancesOn) }
    }

    func testPlanIsPicksInFixedOrderThenFriendsAlways() {
        XCTAssertEqual(OnboardingFlowState.plan(for: []), [.friend])
        XCTAssertEqual(OnboardingFlowState.plan(for: [.remember, .prayer]), [.prayer, .remember, .friend])
        XCTAssertEqual(OnboardingFlowState.plan(for: Set(OnboardingTopic.allCases)),
                       [.devotion, .prayer, .learn, .remember, .friend])
    }

    func testTotalPartsIsPicksPlusOne() {
        for n in 0...OnboardingTopic.allCases.count {
            let picks = Set(OnboardingTopic.allCases.prefix(n))
            XCTAssertEqual(OnboardingFlowState(mode: .firstRun, picks: picks).totalParts, n + 1)
        }
    }

    func testEveryPartHasUniqueCueIdsAndOnlyFriendsAreUnpicked() {
        var ids = Set<String>()
        for part in OnboardingPart.allCases {
            XCTAssertFalse(part.cues.isEmpty)
            for c in part.cues { XCTAssertTrue(ids.insert(c.id).inserted, "duplicate cue id \(c.id)") }
        }
        XCTAssertEqual(OnboardingTopic.allCases.map(\.part), [.devotion, .prayer, .learn, .remember])
    }

    func testPendingHasNoCurrentCueUntilBegin() {
        var s = OnboardingFlowState(mode: .firstRun, picks: [.prayer])
        XCTAssertNil(s.currentCue)
        XCTAssertEqual(s.apply(.notificationSettingsOpened), .ignored, "pending must not advance")
        s.begin()
        XCTAssertEqual(s.currentPart, .prayer)
        XCTAssertEqual(s.currentCue?.id, "prayer.open")
    }

    func testWrongEventIsIgnoredAndMatchingEventAdvances() {
        var s = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); s.begin()
        XCTAssertEqual(s.apply(.devotionSaved), .ignored)
        XCTAssertEqual(s.cueIndex, 0)
        XCTAssertEqual(s.apply(.notificationSettingsOpened), .cueAdvanced)
        XCTAssertEqual(s.currentCue?.id, "prayer.toggle")
    }

    func testGettingAheadOfTheCardStillCountsButGoingBackDoesNot() {
        var s = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); s.begin()
        // User flips the switch before opening settings was reported: jumps to cue 2.
        XCTAssertEqual(s.apply(.prayerReminderEnabled), .cueAdvanced)
        XCTAssertEqual(s.currentCue?.id, "prayer.time")
        // An earlier cue's event can no longer move it.
        XCTAssertEqual(s.apply(.notificationSettingsOpened), .ignored)
        XCTAssertEqual(s.currentCue?.id, "prayer.time")
    }

    func testLastCueEventCompletesPartThenReachesRecapAfterFriends() {
        var s = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); s.begin()
        complete(.prayer, in: &s)
        XCTAssertEqual(s.completed, [.prayer])
        XCTAssertEqual(s.phase, .walking)
        XCTAssertEqual(s.currentPart, .friend)
        XCTAssertEqual(s.partNumber, 2)
        var outcome = OnboardingFlowState.Outcome.ignored
        for cue in OnboardingPart.friend.cues { outcome = s.apply(cue.advancesOn) }
        XCTAssertEqual(outcome, .reachedRecap)
        XCTAssertEqual(s.phase, .recap)
        XCTAssertNil(s.currentCue)
        XCTAssertEqual(s.status(of: .prayer), .done)
        XCTAssertEqual(s.status(of: .friend), .done)
    }

    func testSkipLeavesWholePartOpenAndRecordsItSkipped() {
        var s = OnboardingFlowState(mode: .firstRun, picks: [.remember]); s.begin()
        s.apply(.noteEditorOpened)
        XCTAssertEqual(s.skipCurrentPart(), .partCompleted)
        XCTAssertEqual(s.status(of: .remember), .skipped)
        XCTAssertEqual(s.currentPart, .friend)
        XCTAssertEqual(s.cueIndex, 0)
        XCTAssertEqual(s.skipCurrentPart(), .reachedRecap)
        XCTAssertEqual(s.status(of: .friend), .skipped)
        XCTAssertEqual(s.skipCurrentPart(), .ignored, "nothing to skip in recap")
    }

    func testAllFourPartsPlusFriendsEachCompleteViaRealEvents() {
        var s = OnboardingFlowState(mode: .firstRun, picks: Set(OnboardingTopic.allCases)); s.begin()
        for part in s.parts { complete(part, in: &s) }
        XCTAssertEqual(s.phase, .recap)
        XCTAssertEqual(s.completed, [.devotion, .prayer, .learn, .remember, .friend])
        XCTAssertTrue(s.skipped.isEmpty)
    }

    func testRewindGoesBackToTheOpeningCue() {
        var s = OnboardingFlowState(mode: .firstRun, picks: [.devotion]); s.begin()
        s.apply(.devotionSheetOpened); s.apply(.devotionPromptStepReached)
        XCTAssertEqual(s.cueIndex, 2)
        s.rewindToFirstCue()
        XCTAssertEqual(s.currentCue?.id, "devotion.open")
    }

    func testCodableRoundTripKeepsEverything() throws {
        var s = OnboardingFlowState(mode: .replay, picks: [.learn, .prayer]); s.begin()
        s.apply(.notificationSettingsOpened)
        let back = try JSONDecoder().decode(OnboardingFlowState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.mode, .replay)
    }

    func testValidatedRejectsOutOfRangeIndexes() {
        var s = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); s.begin()
        XCTAssertNotNil(s.validated())
        s.cueIndex = 99
        XCTAssertNil(s.validated(), "walking with a cue past the end must be rejected")
        s.cueIndex = 0; s.partIndex = 99
        XCTAssertNil(s.validated())
        s.partIndex = -1
        XCTAssertNil(s.validated())
    }
}

// MARK: - Store + engine

@MainActor
final class OnboardingEngineTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingEngineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeEngine(arguments: [String] = []) -> OnboardingEngine {
        OnboardingEngine(store: OnboardingProgressStore(defaults: defaults), arguments: arguments)
    }

    private func postTour(_ args: [String] = []) -> PostTourPromptsStore {
        PostTourPromptsStore(defaults: defaults, arguments: args)
    }

    private func waitForGate(_ engine: OnboardingEngine, _ expected: OnboardingEngine.Gate,
                             file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 where engine.gate != expected { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(engine.gate, expected, file: file, line: line)
    }

    private func complete(_ part: OnboardingPart, on engine: OnboardingEngine) {
        for cue in part.cues { engine.report(cue.advancesOn) }
    }

    private func service(subscribed: Bool?) -> ThrowingTestDataService {
        let svc = ThrowingTestDataService()
        switch subscribed {
        case .some(true):  svc.fetchUsageOverride = .success(FSUsage(subscribed: true))
        case .some(false): svc.fetchUsageOverride = .success(FSUsage(subscribed: false))
        case .none:        svc.fetchUsageOverride = .failure(URLError(.notConnectedToInternet))
        }
        return svc
    }

    // MARK: Store

    func testProgressStoreRoundTripAndCorruptDataIsDropped() {
        let store = OnboardingProgressStore(defaults: defaults)
        XCTAssertNil(store.load())
        var s = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); s.begin()
        store.save(s)
        XCTAssertEqual(store.load(), s)
        defaults.set(Data("not json".utf8), forKey: OnboardingProgressStore.key)
        XCTAssertNil(store.load())
        store.save(s); store.save(nil)
        XCTAssertNil(store.load(), "saving nil clears")
    }

    func testKillMidWalkthroughResumesAtTheSameCue() {
        let a = makeEngine()
        a.savePicks([.prayer]); a.startIfPending()
        a.report(.notificationSettingsOpened)
        XCTAssertEqual(a.currentCue?.id, "prayer.toggle")
        let b = makeEngine()   // "relaunch"
        XCTAssertEqual(b.currentCue?.id, "prayer.toggle")
        XCTAssertTrue(b.isActive)
    }

    // MARK: Start / suppression

    func testSavePicksIsPendingAndBlocksPromptsButIsNotYetActive() {
        let e = makeEngine()
        e.savePicks([.learn])
        XCTAssertFalse(e.isActive, "no coach card before sign-in")
        XCTAssertTrue(e.blocksPostTourPrompts)
        XCTAssertNil(e.currentCue)
        e.report(.agentsSegmentShown)
        XCTAssertEqual(e.state?.phase, .pending, "events before start are ignored")
    }

    func testStartIfPendingBeginsFirstPartAndIsIdempotent() {
        let e = makeEngine()
        e.savePicks([.prayer])
        e.startIfPending(); e.startIfPending()
        XCTAssertEqual(e.currentCue?.id, "prayer.open")
        e.report(.notificationSettingsOpened)
        e.startIfPending()
        XCTAssertEqual(e.currentCue?.id, "prayer.toggle", "second start must not reset progress")
    }

    func testUITestingSuppressesWalkthroughUnlessOptedIn() {
        let suppressed = makeEngine(arguments: ["UI-TESTING"])
        suppressed.savePicks([.prayer]); suppressed.startIfPending()
        XCTAssertNil(suppressed.state, "UI-TESTING alone must leave no coach card, recap, or blocked prompts")
        XCTAssertFalse(suppressed.blocksPostTourPrompts)

        let optedIn = makeEngine(arguments: ["UI-TESTING", "UI-TESTING-WALKTHROUGH"])
        optedIn.savePicks([.prayer]); optedIn.startIfPending()
        XCTAssertTrue(optedIn.isActive)
    }

    // MARK: Events: throw-not-fabricate

    func testFailureKeepsTheCueAndNextRealEventClearsTheMessage() {
        let e = makeEngine()
        e.savePicks([]); e.startIfPending()          // friends only
        e.report(.addFriendSheetOpened)
        XCTAssertEqual(e.currentCue?.id, "friend.send")
        e.reportFailure(.friendRequestSent, message: "Could not send")
        XCTAssertEqual(e.errorMessage, "Could not send")
        XCTAssertEqual(e.currentCue?.id, "friend.send", "a failed send must not advance")
        XCTAssertFalse(e.isRecap)
        e.report(.friendRequestSent)
        XCTAssertNil(e.errorMessage)
        XCTAssertTrue(e.isRecap)
    }

    func testFailureForAnUnrelatedEventIsIgnored() {
        let e = makeEngine()
        e.savePicks([]); e.startIfPending()
        e.reportFailure(.devotionSaved, message: "nope")
        XCTAssertNil(e.errorMessage)
    }

    func testSurfaceDismissedRewindsButLateSuccessStillLands() {
        let e = makeEngine()
        e.savePicks([]); e.startIfPending()
        e.report(.addFriendSheetOpened)
        e.surfaceDismissed(.addFriendSheet)
        XCTAssertEqual(e.currentCue?.id, "friend.open", "sheet closed: card returns to the opening cue")
        e.report(.friendRequestSent)      // late success from the dismissed sheet
        XCTAssertTrue(e.isRecap)
    }

    func testSkipPartThenFinishRecapEndsFlow() {
        let e = makeEngine()
        e.savePicks([.prayer]); e.startIfPending()
        e.skipPart(); e.skipPart()
        XCTAssertTrue(e.isRecap)
        XCTAssertEqual(e.state?.skipped, [.prayer, .friend])
        e.finishRecap()
        XCTAssertNil(e.state)
        XCTAssertFalse(e.blocksPostTourPrompts)
        XCTAssertNil(makeEngine().state, "ended flow does not resume")
    }

    func testAnchorsOnlyTrackedWhileActive() {
        let e = makeEngine()
        e.updateAnchor(.prayerToggle, frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        XCTAssertTrue(e.anchorFrames.isEmpty)
        e.savePicks([.prayer]); e.startIfPending()
        e.updateAnchor(.prayerToggle, frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        e.updateAnchor(.prayerTime, frame: CGRect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertEqual(Set(e.anchorFrames.keys), [.prayerToggle])
        e.updateAnchor(.prayerToggle, frame: nil)
        XCTAssertTrue(e.anchorFrames.isEmpty)
    }

    // MARK: Subscription gate (fail closed)

    func testDevotionAndLearnFailClosedUntilConfigured() {
        for pick in [OnboardingTopic.devotion, .learn] {
            let e = makeEngine()
            e.savePicks([pick]); e.startIfPending()
            XCTAssertEqual(e.gate, .needsSubscription, "\(pick) with no entitlement lookup must be closed")
            let first = e.currentCue!.advancesOn
            e.report(first)
            XCTAssertEqual(e.currentCue?.id, pick.part.cues[0].id, "gated part must not advance")
            XCTAssertNil(e.starterPromptIfActive)
        }
    }

    func testPrayerAndRememberNeverGated() {
        for pick in [OnboardingTopic.prayer, .remember] {
            let e = makeEngine()
            e.savePicks([pick]); e.startIfPending()
            XCTAssertEqual(e.gate, .open)
        }
    }

    func testFreeUserStaysClosedAndSkipReopensForNextPart() async {
        let e = makeEngine()
        e.configure(service: service(subscribed: false), userId: "u1")
        e.savePicks([.devotion]); e.startIfPending()
        await waitForGate(e, .needsSubscription)
        e.report(.devotionSheetOpened)
        XCTAssertEqual(e.currentCue?.id, "devotion.open")
        e.skipPart()
        XCTAssertEqual(e.currentPart, .friend)
        XCTAssertEqual(e.gate, .open, "friends is never gated")
    }

    func testLookupFailureFailsClosed() async {
        let e = makeEngine()
        e.configure(service: service(subscribed: nil), userId: "u1")
        e.savePicks([.learn]); e.startIfPending()
        await waitForGate(e, .needsSubscription)
    }

    func testEmptyUserIdFailsClosed() async {
        let e = makeEngine()
        e.configure(service: service(subscribed: true), userId: "")
        e.savePicks([.devotion]); e.startIfPending()
        await waitForGate(e, .needsSubscription)
    }

    func testSubscribedUserOpensGateAndDevotionCompletes() async {
        let e = makeEngine()
        e.configure(service: service(subscribed: true), userId: "u1")
        e.savePicks([.devotion]); e.startIfPending()
        await waitForGate(e, .open)
        XCTAssertNotNil(e.starterPromptIfActive, "starter prompt is prefilled while the devotion part runs")
        complete(.devotion, on: e)
        XCTAssertEqual(e.currentPart, .friend)
        XCTAssertNil(e.starterPromptIfActive)
    }

    // MARK: Replay isolation + ordering vs PostTourPromptsStore

    func testReplayNeverTouchesPostTourKeysOrBlocksPrompts() {
        // A user who already finished first run: nothing armed.
        let pt = postTour()
        pt.armIfNeeded(onboardingCompleted: true)
        let before = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("postTour") }

        let e = makeEngine()
        e.startReplay(picks: [.prayer])
        XCTAssertTrue(e.isReplay)
        XCTAssertTrue(e.isActive)
        XCTAssertFalse(e.blocksPostTourPrompts, "replay must not hold back (or re-arm) first-run prompts")
        complete(.prayer, on: e); complete(.friend, on: e)
        XCTAssertTrue(e.isRecap)
        e.finishRecap()

        let after = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("postTour") }
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
        XCTAssertNil(pt.nextPrompt())
        XCTAssertFalse(pt.defersSystemPushDialog)
    }

    func testReplayDoesNotClobberRunningFirstRunFlow() {
        let e = makeEngine()
        e.savePicks([.prayer]); e.startIfPending()
        e.startReplay(picks: [.remember])
        XCTAssertEqual(e.state?.mode, .firstRun)
        XCTAssertEqual(e.currentPart, .prayer)
    }

    func testRecapComesBeforePushAndSubscribePrompts() {
        // Launch: ContentView.onAppear arms while onboarding is not yet completed.
        let pt = postTour()
        pt.armIfNeeded(onboardingCompleted: false)
        XCTAssertTrue(pt.defersSystemPushDialog)

        let e = makeEngine()
        e.savePicks([.prayer]); e.startIfPending()
        // Sign-in flips hasCompletedOnboarding; a second arm attempt is a no-op and
        // the walkthrough must still hold the prompts back.
        pt.armIfNeeded(onboardingCompleted: true)
        XCTAssertTrue(e.blocksPostTourPrompts)
        complete(.prayer, on: e)
        XCTAssertTrue(e.blocksPostTourPrompts, "friend step still ahead")
        complete(.friend, on: e)
        XCTAssertTrue(e.isRecap)
        XCTAssertTrue(e.blocksPostTourPrompts, "recap is still before the prompts")
        XCTAssertTrue(pt.defersSystemPushDialog, "walkthrough must not lift the push deferral")

        e.finishRecap()   // "Continue"
        XCTAssertFalse(e.blocksPostTourPrompts)
        XCTAssertEqual(pt.nextPrompt(), .notifications, "push prompt is the next thing owed")
        pt.markNotificationsDone(enabled: false)
        XCTAssertEqual(pt.nextPrompt(), .subscribe)
        pt.markSubscribeDone()
        XCTAssertNil(pt.nextPrompt())
    }

    func testSkippingEverythingStillRunsRecapBeforePrompts() {
        let pt = postTour(); pt.armIfNeeded(onboardingCompleted: false)
        let e = makeEngine()
        e.savePicks([]); e.startIfPending()
        e.skipPart()
        XCTAssertTrue(e.isRecap)
        XCTAssertTrue(e.blocksPostTourPrompts)
        e.finishRecap()
        XCTAssertEqual(pt.nextPrompt(), .notifications)
    }

    func testExistingUserWithNoSavedFlowIsNeverBlocked() {
        let e = makeEngine()
        XCTAssertFalse(e.blocksPostTourPrompts)
        XCTAssertFalse(e.isActive)
    }
}
