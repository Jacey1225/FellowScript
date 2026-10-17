// IPadBadgeScreenshotUITests.swift -- testing gate for task
// 20261016-ipad-parity-and-persistent-badges.
//
// Live-render evidence on an iPad simulator (regular width => WorkspaceView:
// left rail + header, no FloatingTabBar). Uses the "UI-TESTING" mock service
// plus the additive test-only "UI-TESTING-BADGES" launch argument (3 pending
// friend requests, 2 pending join requests in group-abc). Captures retained
// screenshots in portrait and landscape of: rail + header badges, the Account
// menu item count, Notification Settings, and the header after the requests were
// seen (badge cleared although the requests are still pending).
// Screenshot-evidence run, so continueAfterFailure stays true.
import XCTest

final class IPadBadgeScreenshotUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = true }

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists {
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
        }
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
                if element.exists && element.isHittable { element.tap(); return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func railMessages(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Messages")).firstMatch
    }
    private func accountMenu(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Account menu")).firstMatch
    }

    private func signInToWorkspace() -> XCUIApplication {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "System permission alerts") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launchArguments = ["UI-TESTING", "UI-TESTING-BADGES"]
        app.terminate()
        app.launch()

        if !railMessages(app).waitForExistence(timeout: 4) {
            // Walk the onboarding screens (iPad lays them out differently from the
            // phone, so step through whichever advance control is showing).
            let usernameProbe = app.textFields["Username field"]
            let advance: [XCUIElement] = [
                app.buttons["Get Started"],
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Skip →")).firstMatch,
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Begin the Tour →")).firstMatch,
                app.buttons["Skip"],
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign In")).firstMatch,
            ]
            let walkDeadline = Date().addingTimeInterval(60)
            while Date() < walkDeadline, !usernameProbe.exists {
                dismissSystemAlertIfPresent(app)
                for b in advance where b.exists && b.isHittable { b.tap(); break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            }
            let usernameField = app.textFields["Username field"]
            XCTAssertTrue(usernameField.waitForExistence(timeout: 8))
            waitHittableThenTap(usernameField)
            usernameField.typeText("jacob")
            let passwordField = app.secureTextFields["Password field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
            waitHittableThenTap(passwordField)
            passwordField.typeText("password")
            // On iPad the on-screen keyboard covers the submit button; the
            // keyboard's return key submits the form instead.
            passwordField.typeText("\n")
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let submit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sign in button")).firstMatch
            if submit.exists && submit.isHittable { submit.tap() }
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                dismissSystemAlertIfPresent(app)
                if railMessages(app).exists { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }
        XCTAssertTrue(railMessages(app).waitForExistence(timeout: 15), "expected the iPad workspace rail after sign-in.\n\(app.debugDescription)")
        return app
    }

    func test_ipad_railAndHeaderBadges_portraitAndLandscape_thenSeenClears() {
        XCUIDevice.shared.orientation = .portrait
        let app = signInToWorkspace()

        // Badges come from the first mock refresh; give it a moment.
        let rail = railMessages(app)
        let header = accountMenu(app)
        let badgesBy = Date().addingTimeInterval(15)
        while Date() < badgesBy, !(rail.label.contains("join request") && header.label.contains("friend request")) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(rail.label.contains("2 join request") || rail.label.contains("1 join request"),
                      "rail Messages label must carry the join-request count, got: \(rail.label)")
        XCTAssertTrue(header.label.contains("3 friend requests"),
                      "header avatar label must carry the friend-request count, got: \(header.label)")
        shot(app, "ipad-portrait-rail-header-badges")

        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        XCTAssertTrue(railMessages(app).label.contains("join request"))
        XCTAssertTrue(accountMenu(app).label.contains("3 friend requests"))
        shot(app, "ipad-landscape-rail-header-badges")

        // Messages panel (group row join-request dot in the embedded chat list).
        waitHittableThenTap(railMessages(app))
        shot(app, "ipad-landscape-messages-panel")

        // Account menu item shows the count.
        waitHittableThenTap(accountMenu(app))
        let accountItem = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Account (")).firstMatch
        XCTAssertTrue(accountItem.waitForExistence(timeout: 5), "menu item 'Account (3)' expected.\n\(app.debugDescription)")
        shot(app, "ipad-landscape-account-menu-item-count")
        waitHittableThenTap(accountItem)

        // Account sheet: viewing the loaded request list is the seen event.
        if !app.staticTexts["jacob"].waitForExistence(timeout: 10) {
            // Menu tap can be swallowed while the popover animates; reopen once.
            waitHittableThenTap(accountMenu(app))
            waitHittableThenTap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Account")).element(boundBy: 0))
        }
        XCTAssertTrue(app.staticTexts["jacob"].waitForExistence(timeout: 25), "AccountView profile header")
        shot(app, "ipad-landscape-account-sheet")

        // Notification Settings inside the sheet's NavigationStack.
        let notif = app.buttons["Notification settings"]
        var tries = 0
        while !(notif.exists && notif.isHittable) && tries < 10 {
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
                .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            tries += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        if waitHittableThenTap(notif) {
            XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 8))
            shot(app, "ipad-landscape-notification-settings")
            XCUIDevice.shared.orientation = .portrait
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            shot(app, "ipad-portrait-notification-settings")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        } else {
            XCTFail("Notification settings row never became hittable.\n\(app.debugDescription)")
        }

        // Close the sheet (swipe down) and verify the header badge is gone: the
        // friend requests were seen even though they are still pending.
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close", "Back"])).firstMatch
        if done.exists && done.isHittable { done.tap() } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot(app, "ipad-portrait-after-account-seen")
        XCTAssertFalse(accountMenu(app).label.contains("friend request"),
                       "friend-request badge must clear once the list was seen; label: \(accountMenu(app).label)")
        XCTAssertTrue(railMessages(app).label.contains("join request"),
                      "join-request badge persists until the owner opens that group's Join requests list")
    }
}
