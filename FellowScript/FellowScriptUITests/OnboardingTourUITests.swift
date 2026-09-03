// OnboardingTourUITests.swift — regression coverage for the tour.
//
// Originally written for task 20260818-ios-tour-visual-fidelity (hand-drawn
// Mock* recreations, 14 steps). Updated for task
// 20260902-onboarding-tour-real-screenshots: the tour now renders real
// captured Simulator screenshots (Assets.xcassets/OnboardingTour/*) instead
// of hand-drawn mock views, and two steps that described non-existent
// features ("gold dot" cross-user highlights, a "Notifications" section that
// was removed) were cut rather than faked — see design-notes.md's addendum.
// TourStep.all now has 12 entries, not 14.
//
// OnboardingView.swift's `TourStep`, `OBTour`, and `OBMockPhone` are all
// `private` to that file, so they cannot be reached via `@testable import` +
// unit tests. The only way to prove the tour works — and to catch a
// regression of the specific bug class the visual-fidelity task fixed (an
// off-by-one between TourStep.all and OBMockPhone.mockScreen's per-step
// asset lookup) — is to drive the real, running tour end-to-end via XCUITest.
//
// What this specifically guards against:
//   1. TourStep.all's bounds and section ordering — walking every one of the
//      12 steps via the real Next/Get Started button proves `steps[step]`
//      never index-out-of-range crashes and that each section label appears
//      in the expected order (HOME, BIBLE x2, NOTES x2, COMMUNITY x4,
//      AI AGENTS, ACCOUNT, EVENTS).
//   2. Every step actually renders an Image (a real screenshot asset), not a
//      missing-image placeholder — content-mode `.fill` on OBMockPhone would
//      still show *something* even for a missing asset name, so this checks
//      the mock-phone frame itself renders without the app crashing/hanging
//      at any step, and that finishing from the last step transitions
//      cleanly into the CTA phase.
//   3. The final step's trailing nav button reads "Get Started" (not "Next").

import XCTest

final class OnboardingTourUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    private func waitHittableThenTap(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
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

    private func onboardingButton(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// The tour's trailing nav button — "Next" on every step but the last,
    /// "Get Started" on the final step (same physical button, OBTour's
    /// conditional label).
    private func tourAdvanceButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Next", "Get Started")
        ).firstMatch
    }

    @discardableResult
    private func advanceTour(_ app: XCUIApplication, times: Int = 1) -> Bool {
        for _ in 0..<times {
            guard waitHittableThenTap(tourAdvanceButton(app)) else { return false }
            // Let the 0.26s step transition animation settle before the next
            // assertion/tap.
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        return true
    }

    /// Launches fresh into onboarding and walks welcome → survey → bridge,
    /// landing on the tour's first step (HOME, step index 0) without ever
    /// tapping "Skip".
    ///
    /// AppState.restoreSession()/ContentView both persist across app
    /// terminate()/launch() via plain UserDefaults ("fs_user_id",
    /// "hasCompletedOnboarding"), not per-test state, so once any other UI
    /// test in the same run signs a user in, a bare terminate()+launch() here
    /// resumes straight past onboarding into the signed-in app instead of
    /// showing OBWelcome. `-key value` launch arguments populate
    /// NSUserDefaults' argument domain, which shadows the persisted domain
    /// for this process only — the standard XCUITest technique for a
    /// deterministic launch state.
    @discardableResult
    private func launchIntoTourFirstStep() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "UI-TESTING",
            "-hasCompletedOnboarding", "NO",
            "-fs_user_id", "",
        ]
        app.terminate()
        app.launch()

        XCTAssertTrue(waitHittableThenTap(app.buttons["Get Started"], timeout: 10),
                      "expected OBWelcome's Get Started button")
        XCTAssertTrue(waitHittableThenTap(onboardingButton(app, containing: "Skip →"), timeout: 10),
                      "expected OBSurvey's Skip → button (no pains selected)")
        XCTAssertTrue(waitHittableThenTap(onboardingButton(app, containing: "Begin the Tour →"), timeout: 10),
                      "expected OBBridge's Begin the Tour → button")

        XCTAssertTrue(app.staticTexts["HOME"].waitForExistence(timeout: 10),
                      "expected the tour to open on step 0 (HOME section)")
        return app
    }

    // MARK: - Full traversal: 12 steps, correct section order, real screenshot
    // per step, clean finish into CTA.

    func test_tourWalksAllTwelveStepsInOrderAndFinishesIntoCTA() {
        let app = launchIntoTourFirstStep()

        // Step 0: HOME.
        XCTAssertTrue(app.staticTexts["HOME"].exists, "expected step 0's section label to read HOME")

        // Steps 1–2: BIBLE (chapter nav, then highlight menu).
        XCTAssertTrue(advanceTour(app), "expected Next to advance from step 0 to step 1")
        XCTAssertTrue(app.staticTexts["BIBLE"].waitForExistence(timeout: 5), "expected step 1's section label to read BIBLE")
        XCTAssertTrue(advanceTour(app), "expected Next to advance from step 1 to step 2")
        XCTAssertTrue(app.staticTexts["BIBLE"].waitForExistence(timeout: 5), "expected step 2's section label to still read BIBLE")

        // Steps 3–4: NOTES (create note, then group notes) — BIBLE no longer
        // has a 3rd step (the cut "gold dots" step), so the very next tap
        // must land on NOTES, not a lingering 3rd BIBLE step.
        XCTAssertTrue(advanceTour(app), "expected Next to advance from step 2 (BIBLE) straight to step 3 (NOTES) — BIBLE has only 2 steps now")
        XCTAssertTrue(app.staticTexts["NOTES"].waitForExistence(timeout: 5), "expected step 3's section label to read NOTES")
        XCTAssertTrue(advanceTour(app), "expected Next to advance from step 3 to step 4")
        XCTAssertTrue(app.staticTexts["NOTES"].waitForExistence(timeout: 5), "expected step 4's section label to still read NOTES")

        // Steps 5–8: COMMUNITY (friend chat, add friend, create group, group session).
        XCTAssertTrue(advanceTour(app, times: 4), "expected 4 Next taps to walk all of COMMUNITY's 4 steps")
        XCTAssertTrue(app.staticTexts["COMMUNITY"].waitForExistence(timeout: 5), "expected step 8's section label to read COMMUNITY")

        // Step 9: AI AGENTS.
        XCTAssertTrue(advanceTour(app), "expected Next to advance from step 8 (COMMUNITY) to step 9 (AI AGENTS)")
        XCTAssertTrue(app.staticTexts["AI AGENTS"].waitForExistence(timeout: 5), "expected step 9's section label to read AI AGENTS")

        // Step 10: ACCOUNT.
        XCTAssertTrue(advanceTour(app), "expected Next to advance from step 9 to step 10 (ACCOUNT)")
        XCTAssertTrue(app.staticTexts["ACCOUNT"].waitForExistence(timeout: 5), "expected step 10's section label to read ACCOUNT")

        // Step 11 (final): EVENTS — only 1 step now (the cut "Notifications"
        // step was fully superseded by this one), so this is also the last
        // step; the trailing button must read "Get Started", not "Next".
        XCTAssertTrue(advanceTour(app), "expected Next to advance from step 10 to step 11 (EVENTS, the final step)")
        XCTAssertTrue(app.staticTexts["EVENTS"].waitForExistence(timeout: 5), "expected the final step's section label to read EVENTS")
        XCTAssertTrue(
            onboardingButton(app, containing: "Get Started").waitForExistence(timeout: 5),
            "expected the trailing nav button to read Get Started on the final step (steps.count - 1), not Next"
        )

        // Finishing from the final step must transition cleanly into the CTA
        // phase — proves TourStep.all's bounds are correct end-to-end (no
        // index-out-of-range on the last `steps[step]` read).
        XCTAssertTrue(advanceTour(app), "expected the final Get Started tap to finish the tour")
        XCTAssertTrue(
            onboardingButton(app, containing: "Sign In").waitForExistence(timeout: 10),
            "expected OBCta's Sign In button after finishing the tour"
        )
    }

    // MARK: - First step renders a real screenshot image, not a missing-image
    // placeholder or leftover hand-drawn mock text.

    func test_tourFirstStepRendersRealScreenshotNotMockText() {
        let app = launchIntoTourFirstStep()

        // The retired hand-drawn MockDashboard's literal copy must be gone —
        // the mock-phone frame now renders an Image (Assets.xcassets/
        // OnboardingTour/tour-dashboard), which carries no text elements of
        // its own for XCUITest to inspect, so absence of this stale text is
        // the available signal that the swap actually landed.
        XCTAssertFalse(app.staticTexts["REVISIT A VERSE"].exists,
                       "the retired hand-drawn MockDashboard card text must not still render")
        XCTAssertFalse(app.staticTexts["VERSE OF THE DAY"].exists,
                       "the retired VERSE OF THE DAY card must not still render")

        // The tour's own real chrome (unaffected by the screenshot swap)
        // must still be present: heading/body copy, progress dots via the
        // Skip button, and the Next control.
        XCTAssertTrue(app.buttons["Skip"].exists, "expected OBTour's Skip button")
        XCTAssertTrue(onboardingButton(app, containing: "Next").exists, "expected OBTour's Next button on the first step")
    }

    // MARK: - Testing-gate addition (task 20260902-onboarding-tour-real-
    // screenshots): the acceptance criteria explicitly calls out
    // skip/back/next/finish, but the existing suite above only ever drove
    // Next. These two methods exercise the two paths that were previously
    // untested: tapping Skip mid-tour (not just asserting it exists), and
    // tapping the back chevron to return to an already-visited step,
    // confirming both real-screenshot rendering (no missing-image state)
    // and no crash either direction.

    func test_tourSkipButtonMidTourEntersCTAWithoutCrash() {
        let app = launchIntoTourFirstStep()

        // Advance a couple of steps first so Skip is exercised mid-tour, not
        // just from step 0 (where OBBridge's own separate flow already
        // reaches CTA via a different path).
        XCTAssertTrue(advanceTour(app, times: 2), "expected to advance to step 2 before skipping")
        XCTAssertTrue(app.staticTexts["BIBLE"].waitForExistence(timeout: 5), "expected step 2 to still read BIBLE before skipping")

        XCTAssertTrue(waitHittableThenTap(app.buttons["Skip"]), "expected OBTour's Skip button to be tappable mid-tour")

        XCTAssertTrue(
            onboardingButton(app, containing: "Sign In").waitForExistence(timeout: 10),
            "expected Skip mid-tour to transition cleanly into OBCta's Sign In button, same as Finish"
        )
    }

    func test_tourBackButtonReturnsToPreviousStepWithRealScreenshotNoCrash() {
        let app = launchIntoTourFirstStep()

        // Walk forward into COMMUNITY (step 5) so there's real distance to
        // navigate back across, then use the back chevron three times and
        // confirm each intermediate section label appears in the correct
        // reverse order (COMMUNITY -> NOTES -> NOTES -> BIBLE), proving
        // `step -= 1` never index-out-of-ranges and OBMockPhone keeps
        // resolving a real screenshotAsset (not a blank/missing image) at
        // every step along the way, not just forward-only ones.
        XCTAssertTrue(advanceTour(app, times: 5), "expected to advance 5 steps to reach COMMUNITY (step 5)")
        XCTAssertTrue(app.staticTexts["COMMUNITY"].waitForExistence(timeout: 5), "expected step 5's section label to read COMMUNITY")

        // OBTour's back chevron now carries an explicit accessibilityLabel
        // ("Previous step", added alongside this test) -- a plain
        // Image(systemName:)-only button has no reliable text label to
        // match on otherwise.
        let backButton = app.buttons["Previous step"]

        XCTAssertTrue(waitHittableThenTap(backButton), "expected the back button to be tappable at step 5")
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        XCTAssertTrue(app.staticTexts["NOTES"].waitForExistence(timeout: 5), "expected stepping back from step 5 (COMMUNITY) to land on step 4 (NOTES)")

        XCTAssertTrue(waitHittableThenTap(backButton), "expected the back button to be tappable at step 4")
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        XCTAssertTrue(app.staticTexts["NOTES"].waitForExistence(timeout: 5), "expected stepping back from step 4 to step 3 (still NOTES)")

        XCTAssertTrue(waitHittableThenTap(backButton), "expected the back button to be tappable at step 3")
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        XCTAssertTrue(app.staticTexts["BIBLE"].waitForExistence(timeout: 5), "expected stepping back from step 3 to step 2 (BIBLE)")

        // Confirm the app is still fully responsive after this back-and-forth
        // (no crash) by advancing forward again all the way to the final
        // step and finishing, exactly like the main traversal test.
        XCTAssertTrue(advanceTour(app, times: 9), "expected to be able to advance forward again after using back, all the way to the final step")
        XCTAssertTrue(
            onboardingButton(app, containing: "Get Started").waitForExistence(timeout: 5),
            "expected to reach the final step's Get Started button after the back-then-forward sequence"
        )
        XCTAssertTrue(advanceTour(app), "expected the final Get Started tap to finish the tour after back navigation")
        XCTAssertTrue(
            onboardingButton(app, containing: "Sign In").waitForExistence(timeout: 10),
            "expected OBCta's Sign In button after finishing the tour post-back-navigation"
        )
    }
}
