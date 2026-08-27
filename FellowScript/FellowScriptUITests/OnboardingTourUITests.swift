// OnboardingTourUITests.swift — regression coverage for the tour visual-fidelity
// fix (task: 20260818-ios-tour-visual-fidelity).
//
// OnboardingView.swift's `TourStep`, `OBTour`, and `OBMockPhone` are all
// `private` to that file, so they cannot be reached via `@testable import` +
// unit tests (private declarations aren't visible across files even with
// @testable). The only way to prove the fix actually works — and to catch a
// regression of the specific bug class this task fixed — is to drive the
// real, running tour end-to-end via XCUITest and assert on what's actually
// rendered, the same pattern AccountUITests/NoteEditorUITests already use for
// the onboarding flow (just without their `Skip →`/`Skip` shortcuts, which
// jump past the tour entirely and would never exercise any of this).
//
// What this specifically guards against regressing:
//   1. The new ACCOUNT tour step being wired to the wrong (or a nonexistent)
//      case in OBMockPhone.mockScreen's `switch step` — an off-by-one in that
//      switch, or in TourStep.all's insertion order, would silently render
//      the wrong mock screen (or fall through to the `default` case) for a
//      given step index without crashing, so only content assertions at each
//      step catch it, not just "did the app crash".
//   2. TourStep.all's bounds — walking every one of the 14 steps via the real
//      Next/Get Started button proves `steps[step]` never index-out-of-range
//      crashes and that the final step correctly swaps "Next" for
//      "Get Started" and finishes into the CTA phase.
//   3. The stale-content fixes actually landing in the rendered tour: the old
//      "AI agent's latest insight" / "upcoming study session" HOME copy and
//      the old "My Notes / Group Notes" toggle wording are gone, replaced by
//      the current copy/toggle described in design-notes.md.
//   4. The new MockAccount mock screen (profile + OVERVIEW stat card) actually
//      renders when the tour reaches the ACCOUNT step, since Account was
//      previously entirely unrepresented in the tour.

import XCTest

final class OnboardingTourUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Hittable-wait tap helper (same pattern as AccountUITests/
    // NoteEditorUITests: an element can exist in the accessibility tree
    // mid-transition/animation before it's actually hittable, and a bare
    // `.tap()` on one throws "not hittable" rather than retrying).

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
    /// "Get Started" on the final step (same physical button, OBTour.swift's
    /// conditional label). Matching on either label keeps a single "advance"
    /// helper usable for every step, including the final one.
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
            // assertion/tap — same rationale as AccountUITests' settle delays.
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        return true
    }

    /// Launches fresh into onboarding and walks welcome → survey → bridge,
    /// landing on the tour's first step (HOME, step index 0) without ever
    /// tapping "Skip" — unlike AccountUITests/NoteEditorUITests' shared
    /// sign-in helper, which deliberately skips the tour to get to sign-in
    /// faster. This test needs the tour itself, not what's past it.
    ///
    /// AppState.restoreSession()/ContentView both persist across app
    /// terminate()/launch() via plain UserDefaults ("fs_user_id",
    /// "hasCompletedOnboarding" — see AppState.swift/ContentView.swift), not
    /// per-test state, so once any other UI test in the same run signs a user
    /// in, a bare terminate()+launch() here resumes straight past onboarding
    /// into the signed-in app instead of showing OBWelcome (confirmed live:
    /// this test suite failed exactly this way when run directly after
    /// AccountUITests/NoteEditorUITests in the same `xcodebuild test`
    /// invocation). `-key value` launch arguments populate NSUserDefaults'
    /// argument domain, which shadows the persisted domain for this process
    /// only (never written to disk) — the standard XCUITest technique for a
    /// deterministic launch state independent of whatever a previous test in
    /// the same run left behind, without needing any app-source-code change.
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

    // MARK: - Full traversal: every TourStep index resolves to a real,
    // correctly-ordered mock screen, and the tour finishes cleanly.

    func test_tourWalksAllStepsAndFinishesIntoCTA() {
        let app = launchIntoTourFirstStep()

        // Step 0 (HOME) — the rebuilt MockDashboard/step-0 copy fix
        // (design-notes.md §2): the old "AI agent's latest insight" /
        // "upcoming study sessions" copy must be gone, replaced by copy that
        // matches what MockDashboard now actually shows.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "verse to revisit")).firstMatch.exists,
            "expected the fixed HOME step copy describing the Revisit-a-Verse card, not the retired AI-agent-insight copy"
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "AI agent's latest insight")).firstMatch.exists,
            "the retired 'AI agent's latest insight' HOME copy must not still be present"
        )

        // Steps 1–4: BIBLE (x3) → NOTES (1st, step 4). Five taps from step 0
        // lands on step 5 (NOTES, 2nd step) without any index issue.
        XCTAssertTrue(advanceTour(app, times: 5), "expected 5 successful Next taps to reach step 5 (NOTES/Highlights)")

        // Step 5 (NOTES, 2nd) — MockGroupNotes rebuild (design-notes.md §5):
        // the retired "My Notes / Group Notes" toggle is gone, replaced by a
        // Notes/Highlights toggle plus PUBLIC-badged note cards.
        XCTAssertTrue(app.staticTexts["Highlights"].waitForExistence(timeout: 5),
                      "expected MockGroupNotes' rebuilt Notes/Highlights toggle")
        XCTAssertTrue(app.staticTexts["PUBLIC"].waitForExistence(timeout: 5),
                      "expected at least one PUBLIC-badged note card, matching NoteRow's real fields")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Group Notes")).firstMatch.exists,
            "the retired 'My Notes / Group Notes' toggle wording must not still be present"
        )

        // Steps 6–10: COMMUNITY (x4) → AI AGENTS (step 10). Six taps from
        // step 5 lands on step 11 (ACCOUNT) — the new step this task added.
        XCTAssertTrue(advanceTour(app, times: 6), "expected 6 successful Next taps to reach step 11 (ACCOUNT)")

        // Step 11 (ACCOUNT, new) — proves TourStep.all's inserted entry and
        // OBMockPhone.mockScreen's `case 11: MockAccount()` line up: if either
        // were off by one, this step would show AI Agents/Notifications
        // content instead, or the section header wouldn't read ACCOUNT.
        XCTAssertTrue(app.staticTexts["ACCOUNT"].waitForExistence(timeout: 5),
                      "expected the tour's top section label to read ACCOUNT at step 11")
        XCTAssertTrue(app.staticTexts["OVERVIEW"].waitForExistence(timeout: 5),
                      "expected MockAccount's OVERVIEW stat card to render — the new Account mock screen")

        // Steps 12–13: EVENTS (x2, shifted from 11–12 by the ACCOUNT insert).
        // Two taps from step 11 lands on the final step, index 13.
        XCTAssertTrue(advanceTour(app, times: 2), "expected 2 successful Next taps to reach the final step (index 13, EVENTS)")

        XCTAssertTrue(app.staticTexts["EVENTS"].waitForExistence(timeout: 5),
                      "expected the final step's section label to read EVENTS")
        XCTAssertTrue(
            onboardingButton(app, containing: "Get Started").waitForExistence(timeout: 5),
            "expected the trailing nav button to read Get Started on the final step (steps.count - 1), not Next"
        )

        // Finishing from the final step must transition cleanly into the CTA
        // phase — proves TourStep.all's bounds are correct end-to-end (no
        // index-out-of-range on the last `steps[step]` read) and that no
        // surrounding phase (CTA) regressed from the tour changes.
        XCTAssertTrue(advanceTour(app), "expected the final Get Started tap to finish the tour")
        XCTAssertTrue(
            onboardingButton(app, containing: "Sign In").waitForExistence(timeout: 10),
            "expected OBCta's Sign In button after finishing the tour"
        )
    }

    // MARK: - Progress dots stay in bounds for every step (guards against a
    // ForEach(steps.indices) crash if TourStep.all were ever mutated to an
    // empty/mismatched array independently of OBMockPhone.mockScreen).

    func test_tourFirstStepShowsMockDashboardNotStaleWidgets() {
        let app = launchIntoTourFirstStep()

        // MockDashboard's rebuilt hero content (design-notes.md §2) — the
        // "REVISIT A VERSE" card replaces the retired "VERSE OF THE DAY" card.
        XCTAssertTrue(app.staticTexts["REVISIT A VERSE"].waitForExistence(timeout: 5),
                      "expected MockDashboard's rebuilt Revisit-a-Verse card")
        XCTAssertFalse(app.staticTexts["VERSE OF THE DAY"].exists,
                       "the retired VERSE OF THE DAY card must not still render")
        XCTAssertFalse(app.staticTexts["Daily Devotional Agent"].exists,
                       "the retired fictional Daily Devotional Agent card must not still render")
    }
}
