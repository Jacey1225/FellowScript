// OnboardingWalkthroughScreenshotUITests.swift -- task 20261105-onboarding-redo (testing gate).
// Drives survey -> sign-in -> coach walkthrough -> recap on the MockDataService and
// attaches a screenshot at each stage. Works on iPhone and iPad destinations.
// "UI-TESTING-WALKTHROUGH" opts the engine back in (it is suppressed under UI-TESTING).

import XCTest

final class OnboardingWalkthroughScreenshotUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    private func tapWhenHittable(_ e: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if e.exists && e.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if e.exists && e.isHittable { e.tap(); return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    func test_surveyWalkthroughRecap_screenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING", "UI-TESTING-WALKTHROUGH", "-hasCompletedOnboarding", "NO", "-fs_user_id", ""]
        app.terminate(); app.launch()

        XCTAssertTrue(tapWhenHittable(app.buttons["Get Started"]))
        XCTAssertTrue(app.staticTexts["What would you like help with?"].waitForExistence(timeout: 10))
        shot(app, "01-survey-empty")
        XCTAssertTrue(tapWhenHittable(app.buttons["I struggle to pray throughout the day."]))
        XCTAssertTrue(tapWhenHittable(app.buttons["I struggle with remembering what I learned."]))
        shot(app, "02-survey-two-picks")
        XCTAssertTrue(tapWhenHittable(app.buttons["Next"]))

        let usernameField = app.textFields["Username field"]
        if !usernameField.waitForExistence(timeout: 5) {
            let signIn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign In")).firstMatch
            XCTAssertTrue(tapWhenHittable(signIn))
        }
        XCTAssertTrue(usernameField.waitForExistence(timeout: 8))
        shot(app, "03-sign-in")
        usernameField.tap(); usernameField.typeText("jacob")
        let pw = app.secureTextFields["Password field"]
        XCTAssertTrue(pw.waitForExistence(timeout: 5))
        pw.tap(); pw.typeText("password")
        let submit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sign in button")).firstMatch
        XCTAssertTrue(tapWhenHittable(submit))

        // Walkthrough coach card appears over the real dashboard.
        let skip = app.buttons["Skip this step"]
        XCTAssertTrue(skip.waitForExistence(timeout: 25), "expected the coach card after sign-in")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        shot(app, "04-walkthrough-first-card")

        // Skip every part until the recap shows (picks + friends = 3 parts).
        var n = 0
        let recapTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "set up")).firstMatch
        for iteration in 0..<8 {
            if recapTitle.exists { break }
            shot(app, "05-loop-\(iteration)")
            if skip.exists { skip.tap(); n += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        XCTAssertTrue(recapTitle.waitForExistence(timeout: 10), "expected the recap after skipping every part")
        shot(app, "06-recap-all-skipped")
        XCTAssertTrue(app.buttons["Continue"].exists)
    }
}
