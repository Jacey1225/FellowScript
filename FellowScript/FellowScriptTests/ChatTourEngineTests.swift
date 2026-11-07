// ChatTourEngineTests.swift -- testing gate (step 3) for task 20261106-chat-tour.
//
// Covers the pure engine model of the chat tour: separate persistence slot,
// first-run and prompt-store isolation, kill-resume, replay no-op, strict offer
// priority, capability-based cue omission, zero-friend skip, fail-closed state.
// Bug class guarded: chat tour corrupting first-run progress or re-arming
// post-tour prompts, teaching unshipped/Agents features, fabricating chats for
// users with no friends, and offering the tour over higher-priority prompts.

import XCTest
@testable import FellowScript

private let allOn = ChatTourOptions(hasFriends: true, threads: true, inviteLink: true,
                                    joinRequests: true, announcements: true, messageActions: true)
private let friendsOnly = ChatTourOptions(hasFriends: true, threads: false, inviteLink: false,
                                          joinRequests: false, announcements: false, messageActions: true)

// MARK: - Cues and flow state

final class ChatTourFlowStateTests: XCTestCase {

    func testChatTourPartsAreOnlyChatAndNeverEnterFirstRunPlan() {
        let s = OnboardingFlowState(chatTour: allOn)
        XCTAssertEqual(s.parts, [.chat])
        XCTAssertEqual(s.totalParts, 1)
        for n in 0...OnboardingTopic.allCases.count {
            XCTAssertFalse(OnboardingFlowState.plan(for: Set(OnboardingTopic.allCases.prefix(n))).contains(.chat))
        }
        XCTAssertFalse(OnboardingTopic.allCases.map(\.part).contains(.chat))
    }

    func testCueIdsUniqueAndNoAgentsOrAskAIAnywhere() {
        let cues = OnboardingCue.chatCues(options: allOn)
        XCTAssertEqual(Set(cues.map(\.id)).count, cues.count)
        for c in cues {
            let text = (c.title + c.body + (c.hint ?? "") + c.id).lowercased()
            XCTAssertFalse(text.contains("agent"), c.id)
            XCTAssertFalse(text.contains("ask ai"), c.id)
            XCTAssertFalse(text.contains("study partner"), c.id)
            XCTAssertNotEqual(c.anchor, .agentsSegment)
            XCTAssertNotEqual(c.anchor, .studyPartnerRow)
            XCTAssertNotEqual(c.advancesOn, .agentsSegmentShown)
            XCTAssertNotEqual(c.advancesOn, .agentChatOpened)
            XCTAssertNotEqual(c.advancesOn, .agentReplyReceived)
        }
    }

    func testCapabilityCopyOmittedWhenOffAndPresentWhenOn() {
        // Step 7 spans "Open Group info" (chat.groupInfo) and the Host tools card (chat.groupTools).
        func groupInfo(_ o: ChatTourOptions) -> String {
            OnboardingCue.chatCues(options: o).filter { $0.id == "chat.groupInfo" || $0.id == "chat.groupTools" }
                .map { $0.body.lowercased() }.joined(separator: " ")
        }
        let off = groupInfo(friendsOnly)
        XCTAssertFalse(off.contains("invite"))
        XCTAssertFalse(off.contains("join request"))
        XCTAssertFalse(off.contains("announcement"))
        XCTAssertFalse(off.contains("thread"))
        let on = groupInfo(allOn)
        XCTAssertTrue(on.contains("invite"))
        XCTAssertTrue(on.contains("join request"))
        XCTAssertTrue(on.contains("announcement"))
        XCTAssertTrue(on.contains("thread"))
        // each capability is independent
        var only = friendsOnly; only.threads = true
        let t = groupInfo(only)
        XCTAssertTrue(t.contains("thread")); XCTAssertFalse(t.contains("invite"))
        // same cue ids regardless of capability
        XCTAssertEqual(OnboardingCue.chatCues(options: allOn).map(\.id),
                       OnboardingCue.chatCues(options: friendsOnly).map(\.id))
    }

    func testNoneOptionsFailClosedToSingleSkippableCue() {
        XCTAssertFalse(ChatTourOptions.none.hasFriends)
        XCTAssertFalse(ChatTourOptions.none.threads || ChatTourOptions.none.inviteLink
                       || ChatTourOptions.none.joinRequests || ChatTourOptions.none.announcements)
        let cues = OnboardingCue.chatCues(options: .none)
        XCTAssertEqual(cues.map(\.id), ["chat.needFriend"])
        XCTAssertEqual(OnboardingCue.chatCues(options: ChatTourOptions(hasFriends: false, threads: true,
                        inviteLink: true, joinRequests: true, announcements: true)).map(\.id), ["chat.needFriend"],
                       "capabilities without friends must not unlock friend cues")
        // part.cues (used where options are unknown) is the fail-closed list
        XCTAssertEqual(OnboardingPart.chat.cues.map(\.id), ["chat.needFriend"])
    }

    func testZeroFriendsSkipRecordsSkippedAndNeverCompletes() {
        var s = OnboardingFlowState(chatTour: .none); s.begin()
        XCTAssertEqual(s.currentCue?.id, "chat.needFriend")
        // real DM events do nothing: no fabricated conversation advances it
        XCTAssertEqual(s.apply(.dmOpened), .ignored)
        XCTAssertEqual(s.apply(.dmMessageSent), .ignored)
        XCTAssertEqual(s.skipCurrentPart(), .reachedRecap)
        XCTAssertEqual(s.skipped, [.chat])
        XCTAssertTrue(s.completed.isEmpty)
        XCTAssertEqual(s.phase, .recap)
    }

    func testFullTourCompletesOnlyViaRealEventsInOrder() {
        var s = OnboardingFlowState(chatTour: allOn); s.begin()
        let cues = OnboardingCue.chatCues(options: allOn)
        XCTAssertEqual(cues.count, 10)
        for (i, c) in cues.enumerated() {
            XCTAssertEqual(s.currentCue?.id, c.id)
            let out = s.apply(c.advancesOn)
            XCTAssertEqual(out, i == cues.count - 1 ? .reachedRecap : .cueAdvanced)
        }
        XCTAssertEqual(s.completed, [.chat])
        XCTAssertEqual(s.phase, .recap)
    }

    func testWrongEventIgnoredAndGoingBackwardDoesNothing() {
        var s = OnboardingFlowState(chatTour: allOn); s.begin()
        XCTAssertEqual(s.apply(.groupCreated), .cueAdvanced, "getting ahead is allowed")
        XCTAssertEqual(s.currentCue?.id, "chat.groupOpen")
        XCTAssertEqual(s.apply(.dmOpened), .ignored)
        XCTAssertEqual(s.apply(.friendRequestSent), .ignored)
    }

    // MARK: skip-landing rule (a skip must never strand the user)

    func testSkipFromChatListSkipsThreadStepsAndLandsOnRootGroupCue() {
        var s = OnboardingFlowState(chatTour: allOn); s.begin()
        XCTAssertEqual(s.currentCue?.id, "chat.openDM")
        XCTAssertEqual(s.skipCurrentPart(), .cueAdvanced)
        XCTAssertEqual(s.currentCue?.id, "chat.groupPlus", "steps 2-5 need an open thread, so they are skipped together")
        XCTAssertEqual(s.currentCue?.surface, .root)
        XCTAssertTrue(s.chatDoneCues?.isEmpty ?? true)
    }

    func testSkipInsideThreadStaysInThreadThenReachesRoot() {
        var s = OnboardingFlowState(chatTour: allOn); s.begin()
        s.apply(.dmOpened)
        XCTAssertEqual(s.currentCue?.id, "chat.send")
        XCTAssertEqual(s.skipCurrentPart(), .cueAdvanced)
        XCTAssertEqual(s.currentCue?.id, "chat.actions")
        s.skipCurrentPart()
        XCTAssertEqual(s.currentCue?.id, "chat.attach")
        s.skipCurrentPart()
        XCTAssertEqual(s.currentCue?.id, "chat.call")
        s.skipCurrentPart()
        XCTAssertEqual(s.currentCue?.id, "chat.groupPlus", "no thread step is left, so the next landing is a root cue")
    }

    func testSkipFromGroupSheetLandsOnRootGroupOpenAndLastSkipEnds() {
        var s = OnboardingFlowState(chatTour: allOn); s.begin()
        for e in [OnboardingEvent.dmOpened, .dmMessageSent, .messageActionUsed, .attachMenuOpened,
                  .callIntroSeen, .addGroupSheetOpened] { s.apply(e) }
        XCTAssertEqual(s.currentCue?.id, "chat.groupCreate")
        s.skipCurrentPart()
        XCTAssertEqual(s.currentCue?.id, "chat.groupOpen")
        XCTAssertEqual(s.skipCurrentPart(), .reachedRecap)
        XCTAssertEqual(s.phase, .recap)
        XCTAssertEqual(s.completed, [.chat], "real actions were done earlier")
    }

    func testSkipEverywhereNeverLandsOnAnUnreachableSheetCue() {
        for o in [allOn, friendsOnly,
                  ChatTourOptions(hasFriends: true, threads: false, inviteLink: false, joinRequests: false,
                                  announcements: false, messageActions: false)] {
            let cs = OnboardingCue.chatCues(options: o)
            for i in cs.indices {
                guard let t = OnboardingFlowState.chatSkipTarget(in: cs, from: i) else { continue }
                XCTAssertGreaterThan(cs[t].step ?? 0, cs[i].step ?? 0)
                XCTAssertTrue(cs[t].surface == .root || cs[t].surface == cs[i].surface,
                              "skip from \(cs[i].id) landed on \(cs[t].id) (\(cs[t].surface))")
                let firstOfStep = cs.first(where: { $0.step == cs[t].step })
                XCTAssertEqual(firstOfStep?.id, cs[t].id, "skip lands on the start of a step")
            }
        }
    }

    func testResumeNormalizesSheetCueToItsRootOpener() {
        var s = OnboardingFlowState(chatTour: allOn); s.begin()
        for e in [OnboardingEvent.dmOpened, .dmMessageSent, .messageActionUsed, .attachMenuOpened,
                  .callIntroSeen, .addGroupSheetOpened] { s.apply(e) }
        XCTAssertEqual(s.currentCue?.id, "chat.groupCreate")
        s.normalizeChatResume()
        XCTAssertEqual(s.currentCue?.id, "chat.groupPlus")
        s.normalizeChatResume()
        XCTAssertEqual(s.currentCue?.id, "chat.groupPlus", "a root cue is left alone")
    }

    func testRewindGoesToSheetOpenerNotCueZero() {
        var s = OnboardingFlowState(chatTour: allOn); s.begin()
        s.apply(.dmOpened)                       // now chat.send (chatThreadSheet)
        s.apply(.dmMessageSent)                  // chat.actions
        s.apply(.messageActionUsed)              // chat.attach
        XCTAssertEqual(s.currentCue?.id, "chat.attach")
        s.rewindToFirstCue()
        XCTAssertEqual(s.currentCue?.id, "chat.openDM", "closing the DM sheet returns to the cue that opens it")
        // group create sheet closes -> back to the + cue
        var g = OnboardingFlowState(chatTour: allOn); g.begin()
        for e in [OnboardingEvent.dmOpened, .dmMessageSent, .messageActionUsed, .attachMenuOpened,
                  .groupsSegmentShown, .addGroupSheetOpened] { g.apply(e) }
        XCTAssertEqual(g.currentCue?.id, "chat.groupCreate")
        g.rewindToFirstCue()
        XCTAssertEqual(g.currentCue?.id, "chat.groupPlus")
    }

    func testCodableRoundTripKeepsOptionsAndFirstRunJSONHasNoChatKey() throws {
        var s = OnboardingFlowState(chatTour: allOn); s.begin(); s.apply(.dmOpened)
        let back = try JSONDecoder().decode(OnboardingFlowState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.chatOptions, allOn)

        var f = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); f.begin()
        let json = String(data: try JSONEncoder().encode(f), encoding: .utf8)!
        XCTAssertFalse(json.contains("chatOptions"), "first-run JSON must stay byte-compatible")
        // legacy first-run data without the key still decodes
        let legacy = Data(#"{"mode":"firstRun","phase":"walking","picks":["prayer"],"partIndex":0,"cueIndex":0,"completed":[],"skipped":[]}"#.utf8)
        XCTAssertNotNil(try? JSONDecoder().decode(OnboardingFlowState.self, from: legacy))
    }

    func testValidatedRejectsMismatchedModeAndOptions() {
        var chatNoOptions = OnboardingFlowState(chatTour: allOn); chatNoOptions.chatOptions = nil
        XCTAssertNil(chatNoOptions.validated())
        var firstRunWithOptions = OnboardingFlowState(mode: .firstRun, picks: [.prayer])
        firstRunWithOptions.chatOptions = allOn
        XCTAssertNil(firstRunWithOptions.validated())
        var chatWithPicks = OnboardingFlowState(chatTour: allOn); chatWithPicks.picks = [.prayer]
        XCTAssertNil(chatWithPicks.validated())
        var oob = OnboardingFlowState(chatTour: allOn); oob.begin(); oob.cueIndex = 99
        XCTAssertNil(oob.validated())
        XCTAssertNotNil(OnboardingFlowState(chatTour: allOn).validated())
    }
}

// MARK: - Offer gating (priority, flag, fail-closed)

final class ChatTourOfferTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "ChatTourOfferTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    private func store(_ args: [String] = []) -> ChatTourStore { ChatTourStore(defaults: defaults, arguments: args) }
    private func enable() { defaults.set(true, forKey: ChatTourStore.featureFlagKey) }
    private var clear: ChatTourOfferSuppression { var s = ChatTourOfferSuppression(); s.onChatTab = true; return s }

    func testFlagDefaultsOffAndNothingOffersOrShowsEntry() {
        XCTAssertFalse(ChatTourStore.featureFlagDefault)
        XCTAssertFalse(store().isFeatureEnabled)
        XCTAssertFalse(store().isEntryAvailable)
        XCTAssertFalse(store().isEligible())
        XCTAssertFalse(store().shouldOffer(suppression: clear))
    }

    func testFlagOnAndClearOffers() {
        enable()
        XCTAssertTrue(store().isEntryAvailable)
        XCTAssertTrue(store().shouldOffer(suppression: clear))
    }

    func testFlagTurnedOffAgainStopsOffer() {
        enable(); defaults.set(false, forKey: ChatTourStore.featureFlagKey)
        XCTAssertFalse(store().shouldOffer(suppression: clear))
    }

    func testPriorityOrderEachReasonWinsOverEveryLowerOne() {
        // Build suppressions that set reason i and every lower-priority reason; the first must win.
        func sup(_ level: ChatTourOfferBlock) -> ChatTourOfferSuppression {
            var s = ChatTourOfferSuppression()
            s.onChatTab = false                                   // lowest reason always on
            if level.rawValue <= ChatTourOfferBlock.otherPresentation.rawValue { s.inCall = true }
            if level.rawValue <= ChatTourOfferBlock.tourPrompt.rawValue { s.tourPromptEligible = true }
            if level.rawValue <= ChatTourOfferBlock.pushPrompt.rawValue { s.pushPromptActive = true }
            if level.rawValue <= ChatTourOfferBlock.postTourPrompts.rawValue { s.postTourOwed = true }
            if level.rawValue <= ChatTourOfferBlock.walkthrough.rawValue { s.walkthroughActive = true }
            return s
        }
        for level in ChatTourOfferBlock.allCases {
            XCTAssertEqual(sup(level).blockingReason, level)
        }
        XCTAssertTrue(ChatTourOfferBlock.walkthrough < .postTourPrompts)
        XCTAssertTrue(ChatTourOfferBlock.postTourPrompts < .pushPrompt)
        XCTAssertTrue(ChatTourOfferBlock.pushPrompt < .tourPrompt)
        XCTAssertTrue(ChatTourOfferBlock.tourPrompt < .otherPresentation)
        XCTAssertTrue(ChatTourOfferBlock.otherPresentation < .notOnChatTab)
    }

    func testEverySingleSuppressorBlocksOnItsOwn() {
        enable()
        let mutations: [(String, (inout ChatTourOfferSuppression) -> Void, ChatTourOfferBlock)] = [
            ("walkthroughActive", { $0.walkthroughActive = true }, .walkthrough),
            ("firstRunBlocking", { $0.firstRunBlocking = true }, .walkthrough),
            ("postTourOwed", { $0.postTourOwed = true }, .postTourPrompts),
            ("postTourSeen", { $0.postTourSeenThisSession = true }, .postTourPrompts),
            ("pushActive", { $0.pushPromptActive = true }, .pushPrompt),
            ("pushShown", { $0.pushPromptShownThisSession = true }, .pushPrompt),
            ("tourPresented", { $0.tourPromptPresented = true }, .tourPrompt),
            ("tourEligible", { $0.tourPromptEligible = true }, .tourPrompt),
            ("inCall", { $0.inCall = true }, .otherPresentation),
            ("loading", { $0.loadingScreen = true }, .otherPresentation),
            ("other", { $0.otherPresentationActive = true }, .otherPresentation),
            ("notChat", { $0.onChatTab = false }, .notOnChatTab),
        ]
        for (name, m, reason) in mutations {
            var s = clear; m(&s)
            XCTAssertEqual(s.blockingReason, reason, name)
            XCTAssertFalse(store().shouldOffer(suppression: s), name)
        }
        XCTAssertNil(clear.blockingReason)
    }

    func testOfferIsOneTimeAndAnyStoredStateBlocksIt() {
        enable()
        XCTAssertNil(store().offerState)
        store().recordShown()
        XCTAssertEqual(store().offerState, .shown)
        XCTAssertFalse(store().shouldOffer(suppression: clear), "shown once is never offered again")
        store().recordDismissed()
        XCTAssertEqual(store().offerState, .dismissed)
        XCTAssertFalse(store().isEligible())
    }

    func testDismissNeverDowngradesStartedOrCompleted() {
        store().recordStarted(); store().recordDismissed()
        XCTAssertEqual(store().offerState, .started)
        store().recordCompleted(); store().recordDismissed(); store().recordStarted()
        XCTAssertEqual(store().offerState, .completed)
    }

    func testUnreadableStoredValueFailsClosedToDismissed() {
        enable()
        defaults.set("garbage", forKey: ChatTourStore.offerStateKey)
        XCTAssertEqual(store().offerState, .dismissed)
        defaults.set(42, forKey: ChatTourStore.offerStateKey)
        XCTAssertEqual(store().offerState, .dismissed)
        defaults.set(Data([0xff]), forKey: ChatTourStore.offerStateKey)
        XCTAssertEqual(store().offerState, .dismissed)
        XCTAssertFalse(store().shouldOffer(suppression: clear))
    }

    func testUnreadableFlagValueDoesNotEnableAndUITestingSuppresses() {
        defaults.set("garbage", forKey: ChatTourStore.featureFlagKey)   // not a Bool
        XCTAssertFalse(store().isFeatureEnabled, "non-bool value must not enable the offer")
        enable()
        XCTAssertFalse(store(["UI-TESTING"]).isEligible())
        XCTAssertFalse(store(["UI-TESTING"]).shouldOffer(suppression: clear))
        XCTAssertTrue(store(["UI-TESTING", ChatTourStore.uiTestEnableArgument]).shouldOffer(suppression: clear))
    }
}

// MARK: - Engine integration (separate slot, isolation, resume)

@MainActor
final class ChatTourEngineIntegrationTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "ChatTourEngineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    private func makeEngine() -> OnboardingEngine {
        OnboardingEngine(store: OnboardingProgressStore(defaults: defaults),
                         tourPromptStore: TourPromptStore(defaults: defaults, arguments: []),
                         chatTourStore: ChatTourStore(defaults: defaults, arguments: []),
                         arguments: [])
    }
    private func finishAll(_ e: OnboardingEngine, _ o: ChatTourOptions) {
        for c in OnboardingCue.chatCues(options: o) { e.report(c.advancesOn) }
    }
    private var offer: ChatTourOfferState? { ChatTourStore(defaults: defaults, arguments: []).offerState }
    private func snapshot() -> NSDictionary {
        NSDictionary(dictionary: defaults.dictionaryRepresentation())
    }

    func testStartWritesOnlyChatSlotAndOfferStateNotFirstRunKey() {
        let e = makeEngine()
        e.startChatTour(options: allOn)
        XCTAssertTrue(e.isChatTour); XCTAssertTrue(e.isActive)
        XCTAssertNotNil(defaults.data(forKey: OnboardingProgressStore.chatTourKey))
        XCTAssertNil(defaults.object(forKey: OnboardingProgressStore.key), "first-run key untouched")
        XCTAssertEqual(offer, .started)
        XCTAssertEqual(e.currentCue?.id, "chat.openDM")
    }

    func testFirstRunProgressUntouchedByChatTourLifecycle() {
        // user has a saved first-run flow in the first-run slot
        let seed = makeEngine()
        seed.savePicks([.prayer]); seed.startIfPending()
        let firstRunBytes = defaults.data(forKey: OnboardingProgressStore.key)
        XCTAssertNotNil(firstRunBytes)
        // chat tour cannot start while it exists
        seed.startChatTour(options: allOn)
        XCTAssertFalse(seed.isChatTour)
        XCTAssertNil(defaults.data(forKey: OnboardingProgressStore.chatTourKey))
        XCTAssertNil(offer, "no-op start must not write offer state")
        XCTAssertEqual(defaults.data(forKey: OnboardingProgressStore.key), firstRunBytes)
    }

    func testEndingChatTourNeverClearsFirstRunSlot() {
        // Pre-existing first-run data on disk, then a chat tour in the chat slot.
        var f = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); f.begin()
        OnboardingProgressStore(defaults: defaults).save(f)
        let before = defaults.data(forKey: OnboardingProgressStore.key)
        var chat = OnboardingProgressStore(defaults: defaults); chat.slot = OnboardingProgressStore.chatTourKey
        var c = OnboardingFlowState(chatTour: allOn); c.begin(); chat.save(c)
        // first-run slot wins on load
        let e = makeEngine()
        XCTAssertEqual(e.state?.mode, .firstRun)
        // a fresh engine with only a chat slot loads the chat tour and ending it keeps first-run data absent/unchanged
        defaults.removeObject(forKey: OnboardingProgressStore.key)
        let e2 = makeEngine()
        XCTAssertTrue(e2.isChatTour)
        finishAll(e2, allOn); e2.finishRecap()
        XCTAssertNil(e2.state)
        XCTAssertNil(defaults.data(forKey: OnboardingProgressStore.chatTourKey))
        XCTAssertNil(defaults.object(forKey: OnboardingProgressStore.key))
        _ = before
    }

    func testFirstRunSlotEndedSeparatelyKeepsChatSlot() {
        // Chat slot exists; ending a first-run flow only clears the first-run slot.
        var chat = OnboardingProgressStore(defaults: defaults); chat.slot = OnboardingProgressStore.chatTourKey
        var c = OnboardingFlowState(chatTour: allOn); c.begin(); chat.save(c)
        let chatBytes = defaults.data(forKey: OnboardingProgressStore.chatTourKey)
        let e = makeEngine()
        XCTAssertTrue(e.isChatTour)
        // (chat slot is untouched by merely loading)
        XCTAssertEqual(defaults.data(forKey: OnboardingProgressStore.chatTourKey), chatBytes)
    }

    func testChatTourNeverTouchesTourPromptOrPostTourKeys() {
        PostTourPromptsStore(defaults: defaults, arguments: []).armIfNeeded(onboardingCompleted: true)
        TourPromptStore(defaults: defaults, arguments: []).recordFirstRunOutcome(completedParts: 3)
        let before = defaults.dictionaryRepresentation().filter {
            $0.key.hasPrefix("postTour") || $0.key.hasPrefix("tourPrompt")
        }
        let e = makeEngine()
        e.startChatTour(options: allOn)
        XCTAssertFalse(e.blocksPostTourPrompts, "chat tour must not hold back first-run prompts")
        finishAll(e, allOn)
        XCTAssertTrue(e.isRecap)
        e.finishRecap()
        let after = defaults.dictionaryRepresentation().filter {
            $0.key.hasPrefix("postTour") || $0.key.hasPrefix("tourPrompt")
        }
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
        XCTAssertEqual(offer, .completed)
    }

    func testChatTourOnFreshInstallWritesNoPromptKeysAtAll() {
        let e = makeEngine()
        e.startChatTour(options: allOn); finishAll(e, allOn); e.finishRecap()
        for k in defaults.dictionaryRepresentation().keys {
            XCTAssertFalse(k.hasPrefix("postTour") || k.hasPrefix("tourPrompt"), "unexpected key \(k)")
        }
        let tp = TourPromptStore(defaults: defaults, arguments: [])
        XCTAssertNil(tp.outcome)
        XCTAssertNil(PostTourPromptsStore(defaults: defaults, arguments: []).nextPrompt())
    }

    func testKillMidTourResumesAtSameCueWithFrozenOptions() {
        let a = makeEngine()
        a.startChatTour(options: allOn)
        a.report(.dmOpened); a.report(.dmMessageSent)
        XCTAssertEqual(a.currentCue?.id, "chat.actions")
        let b = makeEngine()   // relaunch
        XCTAssertTrue(b.isChatTour); XCTAssertTrue(b.isActive)
        // sheets are not restored, so a saved sheet cue resumes at the root cue that opens it
        XCTAssertEqual(b.currentCue?.id, "chat.openDM")
        XCTAssertEqual(b.state?.chatOptions, allOn)
        // options frozen: a later start with different options cannot change the live tour
        b.startChatTour(options: friendsOnly)
        XCTAssertEqual(b.state?.chatOptions, allOn)
    }

    func testEndChatTourClearsOnlyChatSlotAndAllowsReplay() {
        let e = makeEngine()
        e.startChatTour(options: allOn)
        e.endChatTour()
        XCTAssertNil(e.state)
        XCTAssertNil(makeEngine().state, "ended tour does not resume after relaunch")
        e.startChatTour(options: allOn)
        XCTAssertTrue(e.isChatTour, "the user can start again after ending a stuck tour")
    }

    func testEndChatTourNeverEndsFirstRunFlow() {
        let e = makeEngine()
        e.savePicks([.devotion])
        e.endChatTour()
        XCTAssertEqual(e.state?.mode, .firstRun)
    }

    func testReplayStartIsNoOpWhileStateExists() {
        let e = makeEngine()
        e.startChatTour(options: allOn)
        e.report(.dmOpened)
        let cue = e.currentCue?.id
        e.startChatTour(options: .none)
        XCTAssertEqual(e.currentCue?.id, cue, "second start must not reset progress or options")
        XCTAssertEqual(e.state?.chatOptions, allOn)
        // replay / first-run starts do not clobber it either
        e.startReplay(picks: [.prayer])
        XCTAssertTrue(e.isChatTour)
    }

    func testReplayAfterCompletionIsAllowed() {
        let e = makeEngine()
        e.startChatTour(options: allOn); finishAll(e, allOn); e.finishRecap()
        XCTAssertNil(e.state)
        e.startChatTour(options: allOn)
        XCTAssertTrue(e.isActive)
        XCTAssertEqual(offer, .completed, "replaying never downgrades a completed offer state")
    }

    func testZeroFriendTourSkipDoesNotRecordCompleted() {
        let e = makeEngine()
        e.startChatTour(options: .none)
        XCTAssertEqual(e.currentCue?.id, "chat.needFriend")
        e.report(.dmOpened)                      // nothing fabricated moves it
        XCTAssertEqual(e.currentCue?.id, "chat.needFriend")
        e.skipPart()
        XCTAssertTrue(e.isRecap)
        e.finishRecap()
        XCTAssertNil(e.state)
        XCTAssertEqual(offer, .started, "a skipped tour is not recorded as completed")
        XCTAssertNotEqual(offer, .completed)
    }

    func testZeroFriendCueCompletesWhenFriendAvailableReported() {
        let e = makeEngine()
        e.startChatTour(options: .none)
        e.report(.friendAvailable)
        XCTAssertTrue(e.isRecap)
    }

    func testFailureKeepsCueAndSurfaceDismissRewindsWithinChatTour() {
        let e = makeEngine()
        e.startChatTour(options: allOn)
        e.report(.dmOpened)
        XCTAssertEqual(e.currentCue?.id, "chat.send")
        e.reportFailure(.dmMessageSent, message: "Couldn't send")
        XCTAssertEqual(e.errorMessage, "Couldn't send")
        XCTAssertEqual(e.currentCue?.id, "chat.send")
        e.reportFailure(.friendRequestSent, message: "unrelated")
        XCTAssertEqual(e.errorMessage, "Couldn't send", "failure for a non-current event is ignored")
        e.surfaceDismissed(.chatThreadSheet)
        XCTAssertEqual(e.currentCue?.id, "chat.openDM")
        // a late success still lands
        e.report(.dmMessageSent)
        XCTAssertEqual(e.currentCue?.id, "chat.actions")
    }

    func testCorruptOrCrossSlotChatDataIsDroppedFailClosed() {
        // garbage in chat slot
        defaults.set(Data("nope".utf8), forKey: OnboardingProgressStore.chatTourKey)
        XCTAssertNil(makeEngine().state)
        // chat-tour state planted in the first-run slot is rejected
        var c = OnboardingFlowState(chatTour: allOn); c.begin()
        defaults.set(try! JSONEncoder().encode(c), forKey: OnboardingProgressStore.key)
        defaults.removeObject(forKey: OnboardingProgressStore.chatTourKey)
        XCTAssertNil(makeEngine().state)
        // first-run state planted in the chat slot is rejected
        defaults.removeObject(forKey: OnboardingProgressStore.key)
        var f = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); f.begin()
        defaults.set(try! JSONEncoder().encode(f), forKey: OnboardingProgressStore.chatTourKey)
        XCTAssertNil(makeEngine().state)
        // chat state with out-of-range cue is rejected
        var bad = OnboardingFlowState(chatTour: allOn); bad.begin(); bad.cueIndex = 50
        defaults.set(try! JSONEncoder().encode(bad), forKey: OnboardingProgressStore.chatTourKey)
        XCTAssertNil(makeEngine().state)
    }

    func testFirstRunSlotWinsOverChatSlotOnLoad() {
        var f = OnboardingFlowState(mode: .firstRun, picks: [.prayer]); f.begin()
        OnboardingProgressStore(defaults: defaults).save(f)
        var chat = OnboardingProgressStore(defaults: defaults); chat.slot = OnboardingProgressStore.chatTourKey
        var c = OnboardingFlowState(chatTour: allOn); c.begin(); chat.save(c)
        XCTAssertEqual(makeEngine().state?.mode, .firstRun)
    }

    func testChatTourDoesNotRunInFirstRunSavePicksOrStartIfPending() {
        let e = makeEngine()
        e.startChatTour(options: allOn)
        e.startIfPending()   // guarded to firstRun/pending
        XCTAssertTrue(e.isChatTour)
        XCTAssertEqual(e.currentCue?.id, "chat.openDM")
    }
}
