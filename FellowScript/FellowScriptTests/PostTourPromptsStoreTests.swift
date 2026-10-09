// PostTourPromptsStoreTests.swift -- task 20261008-post-tour-prompts.
// Covers the once-only first-run gating, existing-user exclusion, push-dialog
// deferral and UI-TESTING suppression in PostTourPromptsStore.

import XCTest
@testable import FellowScript

final class PostTourPromptsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PostTourPromptsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(arguments: [String] = []) -> PostTourPromptsStore {
        PostTourPromptsStore(defaults: defaults, arguments: arguments)
    }

    func testNothingOwedBeforeArming() {
        let store = makeStore()
        XCTAssertNil(store.nextPrompt())
        XCTAssertFalse(store.defersSystemPushDialog)
    }

    func testExistingUserWithCompletedOnboardingNeverArmed() {
        let store = makeStore()
        store.armIfNeeded(onboardingCompleted: true)
        XCTAssertNil(store.nextPrompt())
        XCTAssertFalse(store.defersSystemPushDialog)
    }

    func testNewInstallArmedShowsNotificationsThenSubscribeThenNothing() {
        let store = makeStore()
        store.armIfNeeded(onboardingCompleted: false)
        XCTAssertTrue(store.defersSystemPushDialog)
        XCTAssertEqual(store.nextPrompt(), .notifications)

        store.markNotificationsDone(enabled: true)
        XCTAssertEqual(store.nextPrompt(), .subscribe)

        store.markSubscribeDone()
        XCTAssertNil(store.nextPrompt())
    }

    func testEachPromptShownOnceAcrossRelaunch() {
        makeStore().armIfNeeded(onboardingCompleted: false)
        makeStore().markNotificationsDone(enabled: false)
        // "Relaunch": fresh store over the same defaults resumes at subscribe.
        XCTAssertEqual(makeStore().nextPrompt(), .subscribe)
        makeStore().markSubscribeDone()
        XCTAssertNil(makeStore().nextPrompt())
        // Re-arming after completion (e.g. reinstall-less relaunch while the
        // onboarding flag is still false) must not restart the flow.
        makeStore().armIfNeeded(onboardingCompleted: false)
        XCTAssertNil(makeStore().nextPrompt())
    }

    func testRearmAfterPartialProgressKeepsProgress() {
        let store = makeStore()
        store.armIfNeeded(onboardingCompleted: false)
        store.markNotificationsDone(enabled: true)
        makeStore().armIfNeeded(onboardingCompleted: false)
        XCTAssertEqual(makeStore().nextPrompt(), .subscribe)
    }

    func testMaybeLaterKeepsPushDeferralSoNoSystemDialogOnItsOwn() {
        let store = makeStore()
        store.armIfNeeded(onboardingCompleted: false)
        store.markNotificationsDone(enabled: false)
        XCTAssertTrue(store.defersSystemPushDialog)
    }

    func testEnableNotificationsLiftsPushDeferral() {
        let store = makeStore()
        store.armIfNeeded(onboardingCompleted: false)
        store.markNotificationsDone(enabled: true)
        XCTAssertFalse(store.defersSystemPushDialog)
    }

    func testExplicitClearPushDeferral() {
        let store = makeStore()
        store.armIfNeeded(onboardingCompleted: false)
        store.clearPushDeferral()
        XCTAssertFalse(store.defersSystemPushDialog)
    }

    func testUITestingArgumentSuppressesEverything() {
        let store = makeStore(arguments: ["UI-TESTING"])
        store.armIfNeeded(onboardingCompleted: false)
        XCTAssertNil(store.nextPrompt())
        XCTAssertFalse(store.defersSystemPushDialog)
        XCTAssertFalse(defaults.bool(forKey: PostTourPromptsStore.pendingKey))
    }

    func testUITestingPostTourArgumentReenablesFlow() {
        let store = makeStore(arguments: ["UI-TESTING", PostTourPromptsStore.uiTestEnableArgument])
        store.armIfNeeded(onboardingCompleted: false)
        XCTAssertEqual(store.nextPrompt(), .notifications)
        XCTAssertTrue(store.defersSystemPushDialog)
    }

    func testSubscribeDoneAloneStillOwesNotificationsOnlyUntilBothDone() {
        let store = makeStore()
        store.armIfNeeded(onboardingCompleted: false)
        store.markSubscribeDone()
        XCTAssertEqual(store.nextPrompt(), .notifications)
        store.markNotificationsDone(enabled: false)
        XCTAssertNil(store.nextPrompt())
        XCTAssertFalse(defaults.bool(forKey: PostTourPromptsStore.pendingKey))
    }
}
