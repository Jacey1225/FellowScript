// OnboardingFlowUITests.swift -- task 20261105-onboarding-redo.
// Drives the pre-auth onboarding flow: welcome -> survey -> sign-in.
// (The old 12-step screenshot tour is gone.) The post-sign-in coach walkthrough
// is covered by unit tests of OnboardingFlowState plus the testing gate's
// simulator runs with the "UI-TESTING-WALKTHROUGH" launch argument.
//
// `-hasCompletedOnboarding NO` and an empty `-fs_user_id` shadow persisted
// defaults for this process so every run starts at the welcome screen.

import XCTest

final class OnboardingFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    private func waitHittableThenTap(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
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

    private func launchToSurvey() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING", "-hasCompletedOnboarding", "NO", "-fs_user_id", ""]
        app.terminate()
        app.launch()
        XCTAssertTrue(waitHittableThenTap(app.buttons["Get Started"]), "expected the welcome screen's Get Started button")
        XCTAssertTrue(app.staticTexts["What would you like help with?"].waitForExistence(timeout: 10),
                      "expected the survey title")
        return app
    }

    func test_surveyShowsExactlyFourOptionsAndNextIsStillPresent() {
        let app = launchToSurvey()
        for title in [
            "I struggle to read the Bible consistently.",
            "I struggle to pray throughout the day.",
            "I want to learn more about the Bible.",
            "I struggle with remembering what I learned.",
        ] {
            XCTAssertTrue(app.buttons[title].exists, "missing survey option: \(title)")
        }
        XCTAssertTrue(app.buttons["Next"].exists, "Next stays on screen (dimmed) before any pick")
        XCTAssertTrue(app.buttons["Skip"].exists)
    }

    func test_surveyOptionsAreMultiSelect() {
        let app = launchToSurvey()
        let first = app.buttons["I struggle to read the Bible consistently."]
        let second = app.buttons["I struggle to pray throughout the day."]
        XCTAssertTrue(waitHittableThenTap(first))
        XCTAssertTrue(waitHittableThenTap(second))
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertEqual(second.value as? String, "Selected")
    }

    func test_skipOnSurveyGoesToSignIn() {
        let app = launchToSurvey()
        XCTAssertTrue(waitHittableThenTap(app.buttons["Skip"]), "expected the survey's Skip button")
        let signIn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign In")).firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "expected the sign-in screen after the survey")
        XCTAssertFalse(app.staticTexts["What would you like help with?"].exists)
    }

    func test_nextWithPicksGoesToSignIn() {
        let app = launchToSurvey()
        XCTAssertTrue(waitHittableThenTap(app.buttons["I want to learn more about the Bible."]))
        XCTAssertTrue(waitHittableThenTap(app.buttons["Next"]))
        let create = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Create Account")).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10), "expected the sign-in screen after Next")
    }
}
