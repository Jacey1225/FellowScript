// ChatTourUITests.swift -- testing gate for task 20261106-chat-tour (step 5).
//
// Drives the real app on MockDataService ("UI-TESTING") with the chat tour flag
// forced on via launch arguments ("-chatTourEnabled YES" shadows the stored
// default for the process; the shipped default stays OFF) and the opt-in
// "UI-TESTING-CHAT-TOUR" (the offer is otherwise suppressed under UI-TESTING).
// "UI-TESTING-NO-FRIENDS" empties the mock friends/groups for the zero-friend path.
//
// Runs unchanged on iPhone and iPad (the helpers find Chat/Account either way).
// Tests that need a never-offered store run after `simctl uninstall`, see
// the runner notes in testing-step5.json.

import XCTest

final class ChatTourUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private static let flagOn = ["UI-TESTING", "UI-TESTING-CHAT-TOUR", "-chatTourEnabled", "YES"]

    @discardableResult
    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlerts(XCUIApplication())
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if element.exists && element.isHittable { element.tap(); return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func label(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func dismissSystemAlerts(_ app: XCUIApplication) {
        // Password AutoFill "Save Password?" sheet after sign-in (its button is "Not Now";
        // the tour's own dismiss is labelled "Not now" with a different id).
        let save = app.staticTexts["Save Password?"]
        let notNow = app.buttons["Not Now"]
        if save.exists && notNow.exists && notNow.isHittable { notNow.tap() }
    }

    private func isIPad(_ app: XCUIApplication) -> Bool { app.buttons["Chat"].exists == false && accountMenu(app).exists }
    private func accountMenu(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Account menu")).firstMatch
    }
    private func railMessages(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Messages")).firstMatch
    }

    private func signedIn(_ app: XCUIApplication) -> Bool {
        app.buttons["Home"].exists || accountMenu(app).exists
    }

    /// Launch, walk welcome/sign-in only if needed, and return once the main UI is up.
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.terminate()
        app.launch()
        var signedInThisLaunch = false
        if !(app.buttons["Home"].waitForExistence(timeout: 5) || accountMenu(app).exists) {
            signedInThisLaunch = true
            func ob(_ t: String) -> XCUIElement {
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", t)).firstMatch
            }
            tapWhenHittable(app.buttons["Get Started"])
            tapWhenHittable(app.buttons["Skip"])
            tapWhenHittable(ob("Sign In"))
            let user = app.textFields["Username field"]
            XCTAssertTrue(user.waitForExistence(timeout: 8))
            XCTAssertTrue(tapWhenHittable(user))
            user.typeText("jacob")
            let pw = app.secureTextFields["Password field"]
            XCTAssertTrue(pw.waitForExistence(timeout: 5))
            XCTAssertTrue(tapWhenHittable(pw))
            pw.typeText("password")
            let submit = ob("sign in button")
            XCTAssertTrue(submit.waitForExistence(timeout: 5))
            XCTAssertTrue(tapWhenHittable(submit))
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline && !signedIn(app) {
                dismissSystemAlerts(app)
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            }
        }
        XCTAssertTrue(signedIn(app), "never reached the signed-in UI\n\(app.debugDescription)")
        if signedInThisLaunch {
            // Signing in through the survey marks the first-run flow as seen for the whole
            // session, which (by design) suppresses the offer. A relaunch is a new session.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 15) || accountMenu(app).waitForExistence(timeout: 5),
                          "relaunch should land signed in\n\(app.debugDescription)")
        }
        return app
    }

    private func goToChat(_ app: XCUIApplication) {
        if app.buttons["Chat"].waitForExistence(timeout: 3) {
            XCTAssertTrue(tapWhenHittable(app.buttons["Chat"]), "Chat tab not tappable")
        } else {
            XCTAssertTrue(tapWhenHittable(railMessages(app)), "iPad Messages rail item not tappable\n\(app.debugDescription)")
        }
    }

    private func goToAccount(_ app: XCUIApplication) throws {
        shot(app, "before-goToAccount")
        if app.buttons["Account"].waitForExistence(timeout: 3) {
            XCTAssertTrue(tapWhenHittable(app.buttons["Account"]), "Account tab not hittable\n\(app.debugDescription)")
        } else {
            // The iPad header Menu reports isHittable == false (nested button at the same frame),
            // so tap its centre by coordinate once it exists.
            XCTAssertTrue(accountMenu(app).waitForExistence(timeout: 8), "iPad Account menu\n\(app.debugDescription)")
            let hasItem = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Reset layout", "Account (")).firstMatch
            for _ in 0..<3 where !hasItem.exists {
                if accountMenu(app).isHittable { accountMenu(app).tap() }
                else { accountMenu(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                _ = hasItem.waitForExistence(timeout: 3)
            }
            shot(app, "ipad-account-menu-open")
            let named = NSPredicate(format: "label BEGINSWITH %@ AND NOT label BEGINSWITH %@", "Account", "Account menu")
            let menuItem = app.menuItems.matching(named).firstMatch
            let button = app.buttons.matching(named).firstMatch
            let deadline = Date().addingTimeInterval(8)
            var tapped = false
            while Date() < deadline && !tapped {
                if menuItem.exists && menuItem.isHittable { menuItem.tap(); tapped = true }
                else if button.exists && button.isHittable { button.tap(); tapped = true }
                else { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
            }
            // iOS renders the header Menu out of process on iPad: the menu opens but XCUITest
            // cannot see its items in this simulator, so Account is unreachable there.
            if !tapped { throw XCTSkip("iPad header Menu items are not exposed to XCUITest; Account unreachable on iPad") }
        }
    }

    private func scrollTo(_ element: XCUIElement, _ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if element.exists && element.isHittable { return }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("\(element) never became hittable\n\(app.debugDescription)")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func coach(_ app: XCUIApplication, step: String) -> Bool {
        label(app, "CHAT TOUR").waitForExistence(timeout: 10) && label(app, step).waitForExistence(timeout: 5)
    }

    // MARK: Flag off (the shipped state)

    func test_flagOff_noOfferAndNoAccountRow() throws {
        let app = launch(["UI-TESTING", "UI-TESTING-CHAT-TOUR"])   // opt-in arg but NO flag
        goToChat(app)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.buttons["chatTour.offer.start"].exists, "offer must not show with the flag off")
        XCTAssertFalse(label(app, "New to Chat?").exists)
        try goToAccount(app)
        let replay = app.buttons["Replay onboarding"]
        scrollTo(replay, app)
        XCTAssertFalse(app.buttons["chatTour.account.row"].exists, "Account row must be hidden with the flag off")
        XCTAssertFalse(label(app, "Replay chat tour").exists)
    }

    // MARK: Offer on Chat tab -> start -> skip

    func test_offer_start_showsStepOfSeven_andSkipMovesOn() {
        let app = launch(Self.flagOn)
        goToChat(app)
        let start = app.buttons["chatTour.offer.start"]
        _ = start.waitForExistence(timeout: 15)
        shot(app, "offer-state")
        XCTAssertTrue(start.exists, "offer card never appeared\n\(app.debugDescription)")
        shot(app, "chat-tour-offer")
        XCTAssertTrue(tapWhenHittable(start))
        XCTAssertFalse(app.buttons["chatTour.offer.start"].waitForExistence(timeout: 2), "offer must close once started")
        RunLoop.current.run(until: Date().addingTimeInterval(2)); shot(app, "after-start")
        XCTAssertTrue(coach(app, step: "1 of "), "first coach card (1 of 7)\n\(app.debugDescription)")
        XCTAssertTrue(label(app, "Message a friend").exists)
        shot(app, "chat-tour-step1")

        let skip = app.buttons["Skip this step"]
        XCTAssertTrue(tapWhenHittable(skip))
        RunLoop.current.run(until: Date().addingTimeInterval(2)); shot(app, "after-skip")
        // Skip from the chat list skips the thread steps together and lands on the next
        // root cue (the group cue); it must never land on a sheet cue with no card host.
        XCTAssertTrue(label(app, "Start a group").waitForExistence(timeout: 8), "skip should land on the group cue\n\(app.debugDescription)")
        XCTAssertTrue(label(app, "CHAT TOUR").exists, "a coach card must still be on screen after skip")
        XCTAssertFalse(label(app, "Say hello").exists, "skip must not land on the thread-sheet cue")
        XCTAssertTrue(app.buttons["Skip this step"].exists, "the landed cue keeps a Skip")
        shot(app, "chat-tour-group-cue-after-skip")
    }

    // MARK: Dismiss is permanent; Account replay still works

    func test_offer_notNow_isPermanent_andAccountReplayStartsTour() throws {
        let app = launch(Self.flagOn)
        goToChat(app)
        XCTAssertTrue(tapWhenHittable(app.buttons["chatTour.offer.dismiss"], timeout: 15), "offer dismiss")
        XCTAssertFalse(app.buttons["chatTour.offer.start"].waitForExistence(timeout: 2))

        // Relaunch: dismissed offer never returns.
        let app2 = launch(Self.flagOn)
        goToChat(app2)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app2.buttons["chatTour.offer.start"].exists, "dismissed offer must not re-show after relaunch")

        // Account replay.
        try goToAccount(app2)
        let row = app2.buttons["chatTour.account.row"]
        scrollTo(row, app2)
        shot(app2, "chat-tour-account-row")
        XCTAssertTrue(tapWhenHittable(row))
        XCTAssertTrue(coach(app2, step: "1 of "), "replay from Account should start the tour\n\(app2.debugDescription)")
        shot(app2, "chat-tour-replay-started")
    }

    // MARK: Real action advances; kill mid-tour resumes at the same step

    func test_openDM_advancesToStep2_killResumesAtStep1_noSecondOffer() {
        let app = launch(Self.flagOn)
        goToChat(app)
        XCTAssertTrue(tapWhenHittable(app.buttons["chatTour.offer.start"], timeout: 15), "offer start\n\(app.debugDescription)")
        XCTAssertTrue(coach(app, step: "1 of "))
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // let the progress write land
        app.terminate()

        let app2 = XCUIApplication()
        app2.launchArguments = Self.flagOn
        app2.launch()
        XCTAssertTrue(app2.buttons["Home"].waitForExistence(timeout: 15) || accountMenu(app2).waitForExistence(timeout: 5))
        XCTAssertTrue(label(app2, "CHAT TOUR").waitForExistence(timeout: 15), "tour must resume after a kill\n\(app2.debugDescription)")
        XCTAssertTrue(label(app2, "1 of ").exists, "must resume at step 1, not restart or vanish")
        XCTAssertFalse(app2.buttons["chatTour.offer.start"].exists, "offer never shows over a running tour")
        shot(app2, "chat-tour-resumed")

        // Real action: opening a friend's conversation completes step 1.
        // The row exposes avatar, name and subtitle as separate "Chat with Sarah" texts plus a
        // trailing menu button. Tap the name text (2nd text): the avatar opens a profile instead.
        // iPad does not persist the open Messages panel across a kill: the resumed card shows over
        // the default layout, so the user opens Messages from the rail (no-op on iPhone).
        if railMessages(app2).exists && !app2.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Chat with Sarah")).firstMatch.waitForExistence(timeout: 3) {
            XCTAssertTrue(tapWhenHittable(railMessages(app2)), "iPad Messages rail")
        }
        let texts = app2.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Chat with Sarah"))
        // iPad's embedded list exposes the whole row as one "Chat with Sarah" button instead.
        let rowButton = app2.buttons.matching(NSPredicate(format: "label == %@", "Chat with Sarah")).firstMatch
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 10) || rowButton.exists, "friend row\n\(app2.debugDescription)")
        let name = texts.count > 1 ? texts.element(boundBy: 1) : (texts.count == 1 && !rowButton.exists ? texts.firstMatch : rowButton)
        XCTAssertTrue(tapWhenHittable(name), "friend row name tap")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot(app2, "chat-tour-step2-after-open-dm")
        XCTAssertTrue(label(app2, "2 of ").waitForExistence(timeout: 8), "opening a DM should move to step 2\n\(app2.debugDescription)")
    }

    func test_accountRowHidden_whileTourRuns() throws {
        let app = launch(Self.flagOn)
        goToChat(app)
        XCTAssertTrue(tapWhenHittable(app.buttons["chatTour.offer.start"], timeout: 15))
        XCTAssertTrue(coach(app, step: "1 of "))
        try goToAccount(app)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(app.buttons["chatTour.account.row"].exists, "replay row hidden while a flow is active")
        XCTAssertTrue(app.buttons["chatTour.account.end"].waitForExistence(timeout: 5), "End chat tour recovery row must show while the tour runs")
    }

    // MARK: Recovery: End chat tour from Account, then replay works

    func test_endChatTourRow_endsTour_thenReplayRowReturns() throws {
        let app = launch(Self.flagOn)
        goToChat(app)
        XCTAssertTrue(tapWhenHittable(app.buttons["chatTour.offer.start"], timeout: 15))
        XCTAssertTrue(coach(app, step: "1 of "))
        try goToAccount(app)
        let end = app.buttons["chatTour.account.end"]
        scrollTo(end, app)
        shot(app, "chat-tour-end-row")
        XCTAssertTrue(label(app, "End chat tour").exists)
        XCTAssertTrue(tapWhenHittable(end))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: end)
        waitForExpectations(timeout: 8)
        // The chat slot is clear: the replay row is back and the tour is not running.
        let replay = app.buttons["chatTour.account.row"]
        scrollTo(replay, app)
        shot(app, "chat-tour-after-end")
        XCTAssertFalse(label(app, "CHAT TOUR IN PROGRESS").exists)
        // Replay restarts at step 1.
        XCTAssertTrue(tapWhenHittable(replay))
        XCTAssertTrue(coach(app, step: "1 of "), "replay after End should start a fresh tour\n\(app.debugDescription)")
    }

    // MARK: Zero friends

    func test_zeroFriends_showsAddFriendCard_andSkipEndsWithoutFabricating() {
        let app = launch(Self.flagOn + ["UI-TESTING-NO-FRIENDS"])
        goToChat(app)
        XCTAssertTrue(tapWhenHittable(app.buttons["chatTour.offer.start"], timeout: 15), "offer start\n\(app.debugDescription)")
        XCTAssertTrue(label(app, "Add a friend to start chatting").waitForExistence(timeout: 10), "zero-friend card\n\(app.debugDescription)")
        XCTAssertFalse(label(app, "Message a friend").exists, "no DM step may be shown without friends")
        shot(app, "chat-tour-zero-friends")
        XCTAssertTrue(tapWhenHittable(app.buttons["Skip this step"]))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: label(app, "Add a friend to start chatting"))
        waitForExpectations(timeout: 8)
        // Skipping ends in the recap; with zero friends it must show nothing as done.
        if label(app, "You know your way around Chat").waitForExistence(timeout: 5) {
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", ", done")).firstMatch.exists,
                           "a skipped zero-friend tour must not claim progress")
        }
        shot(app, "chat-tour-zero-friends-after-skip")
    }
}
