// ChatReactionsLiveUITests.swift -- task 20261022-reactions-live.
// Bug: a reaction chip only appeared after leaving and reopening the chat.
// Root cause: ChatThreadView renders cached message groups that recompute on
// count/ack/older/thread changes only; a reaction mutates a message in place,
// so the groups kept stale copies without the chip. This drives the real view
// in the simulator (MockDataService, UI-TESTING-REACTIONS: reactions capability
// on, in-memory add/remove): long-press a message, tap Thumbs up, and require
// the chip to render in the open chat with no reload. Fails without the
// .onChange(of: vm.reactionRevision) recompute in ChatThreadView.
import XCTest

final class ChatReactionsLiveUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    private func waitHittableThenTap(_ element: XCUIElement, timeout: TimeInterval = 10, scrollContainer app: XCUIApplication? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if element.exists && element.isHittable {
                    element.tap()
                    return true
                }
            }
            // Row exists but is off-screen (e.g. below the fold in the chat
            // list) rather than genuinely un-hittable -- nudge it into view,
            // matching the working idiom in NotesMessagesListScrollBlurUITests.
            if element.exists, let app {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        // Last resort: the element exists and is visually on-screen (has a
        // real frame) but XCUITest's isHittable heuristic never flips true --
        // this happens for a StaticText matched via `.any` whose parent List
        // row/cell is the actual interactive element. A raw coordinate tap
        // bypasses the hittability check and hits whatever is really at that
        // point on screen (the row), same as a real finger tap would.
        if element.exists, element.frame.width > 0, element.frame.height > 0 {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }
        return false
    }

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists {
            for label in ["Allow", "OK", "Allow While Using App", "Allow Full Access", "Select Photos..."] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
        }
        let notNow = app.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
    }

    /// Mirrors AccountUITests.signInAndReachAccount, routed to the Chat tab
    /// -> "Chat with Sarah" DM thread instead of Account.
    private func signInAndReachChatThreadWithSarah() -> XCUIApplication {
        let app = XCUIApplication()

        addUIInterruptionMonitor(withDescription: "System permission alerts") { alert in
            for label in ["Allow", "OK", "Allow While Using App", "Allow Full Access", "Select Photos..."] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        app.launchArguments = ["UI-TESTING", "UI-TESTING-REACTIONS"]
        app.terminate()
        app.launch()

        if !app.buttons["Home"].waitForExistence(timeout: 5) {
            func onboardingButton(containing text: String) -> XCUIElement {
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
            }
            waitHittableThenTap(app.buttons["Get Started"], timeout: 10)
            waitHittableThenTap(onboardingButton(containing: "Skip →"))
            waitHittableThenTap(onboardingButton(containing: "Begin the Tour →"))
            waitHittableThenTap(app.buttons["Skip"])
            waitHittableThenTap(onboardingButton(containing: "Sign In"))

            let usernameField = app.textFields["Username field"]
            XCTAssertTrue(usernameField.waitForExistence(timeout: 8))
            XCTAssertTrue(waitHittableThenTap(usernameField))
            usernameField.typeText("jacob")

            let passwordField = app.secureTextFields["Password field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
            XCTAssertTrue(waitHittableThenTap(passwordField))
            passwordField.typeText("password")

            let submitButton = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "sign in button")
            ).firstMatch
            XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
            XCTAssertTrue(waitHittableThenTap(submitButton))

            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                dismissSystemAlertIfPresent(app)
                if app.buttons["Home"].exists { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }

        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 15), "expected Dashboard tab bar after sign-in")

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5), "FloatingTabBar's Chat destination")
        var chatTabTapped = false
        let chatTabDeadline = Date().addingTimeInterval(20)
        while Date() < chatTabDeadline && !chatTabTapped {
            dismissSystemAlertIfPresent(app)
            if waitHittableThenTap(chatTab, timeout: 3) {
                chatTabTapped = true
            }
        }
        XCTAssertTrue(chatTabTapped, "expected the Chat tab to become hittable\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let target = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Chat with Sarah")
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 15), "expected \"Chat with Sarah\" row on the Chat tab\n\(app.debugDescription)")
        XCTAssertTrue(waitHittableThenTap(target, scrollContainer: app), "expected \"Chat with Sarah\" row to be tappable")

        let composerField = app.textViews["Message input field"].exists
            ? app.textViews["Message input field"] : app.textFields["Message input field"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 15), "expected ChatThreadView's composer to load\n\(app.debugDescription)")

        return app
    }

    func test_tappingReaction_showsChipImmediately_withoutReload() {
        let app = signInAndReachChatThreadWithSarah()

        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Did everyone finish the Psalm 23 reading?")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 15), "expected the seeded message\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Thumbs up, 1 reaction, you reacted"].exists, "no chip before reacting")

        message.press(forDuration: 1.2)
        let thumbs = app.buttons["Thumbs up"]
        XCTAssertTrue(thumbs.waitForExistence(timeout: 8), "expected the reaction row in the context menu\n\(app.debugDescription)")
        thumbs.tap()

        let chip = app.buttons["Thumbs up, 1 reaction, you reacted"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8),
                      "reaction chip must render immediately under the message, no reload\n\(app.debugDescription)")
    }
}
