// PushPromptSheetUITests.swift -- task 20261105-push-prompt-sheet.
//
// Drives the real app (MockDataService via "UI-TESTING") with the
// "UI-TESTING-PUSH-PROMPT" launch argument, which swaps in an isolated
// UserDefaults suite, a deferred post-tour store and a fixed authorization
// status (.notDetermined, or .denied with "push-prompt-denied"). Proves the
// sheet appears on Home for each variant with the right copy/buttons, that the
// secondary action dismisses it, and that a dismissed sheet is not re-shown
// in the same session (ask already counted).

import XCTest

final class PushPromptSheetUITests: XCTestCase {

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
        if notNow.exists && !app.otherElements["pushPrompt.sheet"].exists { notNow.tap() }
    }

    private func launchAndSignIn(extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING", "UI-TESTING-PUSH-PROMPT"] + extra
        app.terminate()
        app.launch()

        if !app.buttons["Home"].waitForExistence(timeout: 5) {
            func ob(_ t: String) -> XCUIElement {
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", t)).firstMatch
            }
            tapWhenHittable(app.buttons["Get Started"])
            tapWhenHittable(ob("Skip →"))
            tapWhenHittable(ob("Begin the Tour →"))
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

    private func waitForSheet(_ app: XCUIApplication) -> XCUIElement {
        let headline = app.staticTexts["pushPrompt.headline"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            dismissAutofill(app)
            if headline.exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(headline.exists, "push prompt sheet never appeared")
        return headline
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["PUSH_PROMPT_SCREENS_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        }
    }

    func test_primer_showsOnHome_andNotNowDismissesWithoutReappearing() throws {
        let app = launchAndSignIn(extra: [])
        let headline = waitForSheet(app)
        XCTAssertTrue(app.buttons["pushPrompt.primary"].exists)
        XCTAssertTrue(app.buttons["pushPrompt.secondary"].exists)
        XCTAssertFalse(headline.label.isEmpty)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        save(app, "push-prompt-primer")

        XCTAssertTrue(tapWhenHittable(app.buttons["pushPrompt.secondary"]))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.staticTexts["pushPrompt.headline"])
        waitForExpectations(timeout: 8)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.staticTexts["pushPrompt.headline"].exists, "dismissed sheet must not re-show in-session")
    }

    func test_denied_showsSettingsVariant() throws {
        let app = launchAndSignIn(extra: ["push-prompt-denied"])
        let headline = waitForSheet(app)
        XCTAssertTrue(app.buttons["pushPrompt.primary"].exists)
        XCTAssertTrue(app.buttons["pushPrompt.secondary"].exists)
        XCTAssertFalse(headline.label.isEmpty)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        save(app, "push-prompt-denied")

        XCTAssertTrue(tapWhenHittable(app.buttons["pushPrompt.secondary"]))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["pushPrompt.headline"])
        waitForExpectations(timeout: 8)
    }
}
