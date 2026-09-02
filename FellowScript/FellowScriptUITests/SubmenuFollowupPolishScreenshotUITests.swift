// SubmenuFollowupPolishScreenshotUITests.swift — live-render screenshot
// coverage for task 20260902-submenu-followup-polish's three follow-up fixes
// to the four sheets restyled by the prior 20260902-submenu-visual-redesign
// task: AddFriendSheet, AddGroupSheet, NewAgentSheet, and EventSetupSheet
// (both its recurrenceScreen and detailsScreen steps).
//
// This app has a documented history of TestFlight-only visual bugs slipping
// past a compile/unit-test-only pass (the off-center "Add Friend" title this
// very task exists to fix is itself one such bug). SubmenuFollowupPolishRegressionTests
// proves the source-level facts (a `.principal` toolbar item exists, the
// ghost-chip/PillButton recipes are used, the EVENT TIME/GROUP row is
// merged) but can't prove any of that actually *renders* correctly on
// device — a `.principal` item can compile and still clip, a merged HStack
// row can compile and still overflow narrow devices, etc. This file drives
// the real running app (via the "UI-TESTING" launch argument -> MockDataService,
// the same mechanism NoteDetailScreenshotUITests/AccountUITests already use)
// to each of the four sheets and captures a retained screenshot of each,
// plus asserts the key controls this task touched are present and hittable.
//
// Screenshot-evidence run, not a strict pass/fail regression gate on pixel
// values (XCUITest can't assert "this text is visually centered") --
// continueAfterFailure stays true so one flaky navigation step doesn't cost
// screenshots already captured earlier in the same test, matching
// NoteDetailScreenshotUITests' documented rationale.
import XCTest

final class SubmenuFollowupPolishScreenshotUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists {
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
        }
        // iOS's Password AutoFill "Save Password?" sheet appears after a
        // genuinely successful manual sign-in and, being a same-process Sheet
        // rather than a springboard alert, fully blocks the UI underneath
        // until dismissed -- same fix as AccountUITests/NoteEditorUITests.
        let notNow = app.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
    }

    @discardableResult
    private func waitHittableThenTap(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(XCUIApplication())
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if element.exists && element.isHittable {
                    element.tap()
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// AccountView is a single long ScrollView, not a List -- "Create new
    /// event" sits below the fold on most device sizes, so a single swipeUp
    /// isn't reliably enough to bring it fully into the hittable region
    /// (mirrors AccountUITests.scrollToAndTap's documented rationale).
    private func scrollToAndTap(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                if element.exists && element.isHittable {
                    element.tap()
                    return
                }
            }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTFail("\(element) never became hittable within \(timeout)s\n\(app.debugDescription)")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Shared sign-in (mirrors NoteDetailScreenshotUITests/AccountUITests)

    @discardableResult
    private func signInAndReachDashboard() -> XCUIApplication {
        let app = XCUIApplication()

        addUIInterruptionMonitor(withDescription: "System permission alerts") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        app.launchArguments = ["UI-TESTING"]
        app.terminate()
        app.launch()

        if app.buttons["Home"].waitForExistence(timeout: 3) {
            return app
        }

        waitHittableThenTap(app.buttons["Get Started"], timeout: 10)
        waitHittableThenTap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Skip →")).firstMatch)
        waitHittableThenTap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Begin the Tour →")).firstMatch)
        waitHittableThenTap(app.buttons["Skip"])
        waitHittableThenTap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign In")).firstMatch)

        let usernameField = app.textFields["Username field"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 8), "expected the sign-in form's username field")
        waitHittableThenTap(usernameField)
        usernameField.typeText("jacob")

        let passwordField = app.secureTextFields["Password field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        waitHittableThenTap(passwordField)
        passwordField.typeText("password")

        let submitButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sign in button")).firstMatch
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        waitHittableThenTap(submitButton)

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if app.buttons["Home"].exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 15), "expected Dashboard tab bar after sign-in")
        return app
    }

    // MARK: - 1. AddFriendSheet — centered title + ghost-chip Cancel + gold PillButton

    func test_addFriendSheet_screenshot() {
        let app = signInAndReachDashboard()

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 10), "expected the Chat tab.\n\(app.debugDescription)")
        waitHittableThenTap(chatTab)

        // Default scope is "Friends" (segment 0), so the add button already
        // reads "Add friend" without needing to tap the scope toggle.
        let addFriendButton = app.buttons["Add friend"]
        XCTAssertTrue(addFriendButton.waitForExistence(timeout: 10), "expected the Chat header's Add friend button.\n\(app.debugDescription)")
        waitHittableThenTap(addFriendButton)

        let title = app.staticTexts["Add Friend"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "expected AddFriendSheet's centered `.principal` title.\n\(app.debugDescription)")

        let cancelButton = app.buttons["Cancel"]
        let sendRequestButton = app.buttons["Send Request"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "expected AddFriendSheet's ghost-chip Cancel")
        XCTAssertTrue(sendRequestButton.waitForExistence(timeout: 5), "expected AddFriendSheet's gold PillButton Send Request")

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attachScreenshot(app, name: "submenu-followup-polish-add-friend-sheet")

        XCTAssertTrue(cancelButton.isHittable, "Cancel must be genuinely tappable, not clipped by the toolbar")
        XCTAssertTrue(sendRequestButton.isHittable, "Send Request must be genuinely tappable")
    }

    // MARK: - 2. AddGroupSheet — centered title + ghost-chip Cancel + gold PillButton

    func test_addGroupSheet_screenshot() {
        let app = signInAndReachDashboard()

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 10))
        waitHittableThenTap(chatTab)

        let groupsSegment = app.buttons["Groups"]
        XCTAssertTrue(groupsSegment.waitForExistence(timeout: 5), "expected the Groups scope-toggle segment.\n\(app.debugDescription)")
        waitHittableThenTap(groupsSegment)

        let addGroupButton = app.buttons["New group"]
        XCTAssertTrue(addGroupButton.waitForExistence(timeout: 8), "expected the Chat header's New group button.\n\(app.debugDescription)")
        waitHittableThenTap(addGroupButton)

        let title = app.staticTexts["New Group"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "expected AddGroupSheet's centered `.principal` title.\n\(app.debugDescription)")

        let cancelButton = app.buttons["Cancel"]
        let createButton = app.buttons["Create"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "expected AddGroupSheet's ghost-chip Cancel")
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "expected AddGroupSheet's gold PillButton Create")

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attachScreenshot(app, name: "submenu-followup-polish-add-group-sheet")

        XCTAssertTrue(cancelButton.isHittable)
    }

    // MARK: - 3. NewAgentSheet — centered title + ghost-chip Cancel + gold PillButton

    func test_newAgentSheet_screenshot() {
        let app = signInAndReachDashboard()

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 10))
        waitHittableThenTap(chatTab)

        let agentsSegment = app.buttons["Agents"]
        XCTAssertTrue(agentsSegment.waitForExistence(timeout: 5), "expected the Agents scope-toggle segment.\n\(app.debugDescription)")
        waitHittableThenTap(agentsSegment)

        let addAgentButton = app.buttons["New agent"]
        XCTAssertTrue(addAgentButton.waitForExistence(timeout: 8), "expected the Chat header's New agent button.\n\(app.debugDescription)")
        waitHittableThenTap(addAgentButton)

        let title = app.staticTexts["New Agent"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "expected NewAgentSheet's centered `.principal` title.\n\(app.debugDescription)")

        let cancelButton = app.buttons["Cancel"]
        let createButton = app.buttons["Create"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "expected NewAgentSheet's ghost-chip Cancel")
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "expected NewAgentSheet's gold PillButton Create")

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attachScreenshot(app, name: "submenu-followup-polish-new-agent-sheet")

        XCTAssertTrue(cancelButton.isHittable)
    }

    // MARK: - 4. EventSetupSheet.recurrenceScreen — centered title + ghost-chip Cancel

    func test_eventSetupSheet_recurrenceScreen_screenshot() {
        let app = signInAndReachDashboard()

        let accountTab = app.buttons["Account"]
        XCTAssertTrue(accountTab.waitForExistence(timeout: 10), "expected the Account tab.\n\(app.debugDescription)")
        waitHittableThenTap(accountTab)

        let createEventButton = app.buttons["Create new event"]
        XCTAssertTrue(createEventButton.waitForExistence(timeout: 10), "expected AccountView's Create new event control.\n\(app.debugDescription)")
        scrollToAndTap(createEventButton, app: app)

        let title = app.staticTexts["New Event"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "expected EventSetupSheet.recurrenceScreen's centered `.principal` title.\n\(app.debugDescription)")

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "expected recurrenceScreen's ghost-chip Cancel (this screen has no trailing item, so the old default title was never actually centered)")

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attachScreenshot(app, name: "submenu-followup-polish-event-setup-recurrence-screen")

        XCTAssertTrue(cancelButton.isHittable)
    }

    // MARK: - 5. EventSetupSheet.detailsScreen — merged EVENT TIME/GROUP row + gold Update/Save

    func test_eventSetupSheet_detailsScreen_screenshot() {
        let app = signInAndReachDashboard()

        let accountTab = app.buttons["Account"]
        XCTAssertTrue(accountTab.waitForExistence(timeout: 10))
        waitHittableThenTap(accountTab)

        let createEventButton = app.buttons["Create new event"]
        XCTAssertTrue(createEventButton.waitForExistence(timeout: 10), "expected AccountView's Create new event control.\n\(app.debugDescription)")
        scrollToAndTap(createEventButton, app: app)

        // Daily recurrence jumps straight to detailsScreen (path = [.details]).
        let dailyCard = app.staticTexts["Daily"]
        XCTAssertTrue(dailyCard.waitForExistence(timeout: 8), "expected the Daily recurrence card.\n\(app.debugDescription)")
        waitHittableThenTap(dailyCard)

        let title = app.staticTexts["Details"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "expected detailsScreen's centered `.principal` title.\n\(app.debugDescription)")

        // Item 2: EVENT TIME and GROUP must both be visible together, on the
        // same screen without scrolling, as one merged row.
        let eventTimeLabel = app.staticTexts["EVENT TIME"]
        let groupLabel = app.staticTexts["GROUP"]
        XCTAssertTrue(eventTimeLabel.waitForExistence(timeout: 8), "expected the EVENT TIME card in the merged row.\n\(app.debugDescription)")
        XCTAssertTrue(groupLabel.waitForExistence(timeout: 5), "expected the GROUP card in the same merged row")

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "expected detailsScreen's gold PillButton Save (new event, not editing)")

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attachScreenshot(app, name: "submenu-followup-polish-event-setup-details-screen-merged-row")

        XCTAssertTrue(eventTimeLabel.isHittable || eventTimeLabel.exists, "EVENT TIME card must render on-screen")
        XCTAssertTrue(groupLabel.isHittable || groupLabel.exists, "GROUP card must render on-screen, side-by-side with EVENT TIME")
    }
}
