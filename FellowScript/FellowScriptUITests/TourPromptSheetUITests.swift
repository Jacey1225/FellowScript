// TourPromptSheetUITests.swift -- testing gate for task 20261105-take-tour-prompt.
//
// Drives the real app (MockDataService via "UI-TESTING") with
// "UI-TESTING-TOUR-PROMPT", which seeds an isolated UserDefaults suite holding a
// skipped first-run outcome. Proves: the sheet shows on Home after sign-in,
// tapping outside dismisses it without starting the tour (and it does not
// re-show in-session), and the primary button starts the tour (survey first).

import XCTest

final class TourPromptSheetUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if element.exists && element.isHittable { element.tap(); return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func dismissAutofill(_ app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        if notNow.exists && !app.otherElements["tourPrompt.sheet"].exists { notNow.tap() }
    }

    private func launchAndSignIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING", "UI-TESTING-TOUR-PROMPT"]
        app.terminate()
        app.launch()
        // A walkthrough recap persisted by an earlier run in the simulator's real
        // defaults would (correctly) suppress the prompt for this session. Finish
        // it and relaunch so the test starts from a clean engine.
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 4), !app.staticTexts["tourPrompt.headline"].exists {
            tapWhenHittable(cont)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            app.terminate()
            app.launch()
        }

        // Phone shows a Home tab; the iPad workspace layout shows the Account menu instead.
        let signedIn = app.buttons["Home"].waitForExistence(timeout: 5) || app.buttons["Account menu"].exists
        if !signedIn {
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
            let submit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sign in button")).firstMatch
            XCTAssertTrue(submit.waitForExistence(timeout: 5))
            XCTAssertTrue(tapWhenHittable(submit))
        }
        return app
    }

    private func waitForSheet(_ app: XCUIApplication) {
        let headline = app.staticTexts["tourPrompt.headline"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            dismissAutofill(app)
            if headline.exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(headline.exists, "tour prompt sheet never appeared")
        XCTAssertTrue(app.buttons["tourPrompt.primary"].exists)
        XCTAssertTrue(app.buttons["tourPrompt.secondary"].exists)
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func test_showsOnHome_tapOutsideDismissesWithoutStartingTour() throws {
        let app = launchAndSignIn()
        waitForSheet(app)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        save(app, "tour-prompt-shown")

        // Tap the dimmed area above the sheet.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["tourPrompt.headline"])
        waitForExpectations(timeout: 8)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.staticTexts["tourPrompt.headline"].exists, "dismissed sheet must not re-show in-session")
        XCTAssertFalse(app.staticTexts["What would you like help with?"].exists, "tap-out must not start the tour")
        save(app, "tour-prompt-after-tapout")
    }

    func test_primaryStartsTour() throws {
        let app = launchAndSignIn()
        waitForSheet(app)
        XCTAssertTrue(tapWhenHittable(app.buttons["tourPrompt.primary"]))
        XCTAssertTrue(app.staticTexts["What would you like help with?"].waitForExistence(timeout: 10),
                      "primary should open the tour survey")
        save(app, "tour-prompt-primary-survey")
        XCTAssertFalse(app.staticTexts["tourPrompt.headline"].exists)
    }
}
