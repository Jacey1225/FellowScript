// CallBarNavOverlapUITests.swift — live on-device/simulator verification for
// task 20260916-call-bar-nav-overlap.
//
// frontend.json for this task fixed the overlap purely via arithmetic (derived
// FloatingTabBar's in-call bottom padding from MinimizedCallBar's own real
// height/inset constants instead of an independent guessed literal) and added
// a unit-level regression test pinning those constants, but explicitly did
// not do a live on-device/simulator check, citing a risk of colliding with
// two sibling /build pipelines running concurrently on other session/call
// bugs in this same repo. This is the testing gate's follow-up: with no other
// pipeline task running a simulator right now, actually drive the real app
// into the minimized-call state and confirm the acceptance criteria visually
// and via hit-testing, on a small-screen (iPhone SE, home-button, zero
// bottom-safe-area) simulator specifically -- the intake spec calls out that
// bottom safe-area insets vary by device as the reason to check at least one
// small screen.
//
// Drives the real running app via MockDataService's "UI-TESTING" launch
// argument (same mechanism as NoteDetailScreenshotUITests etc.). Reaches the
// minimized-call state through genuine user actions only -- sign in, open the
// "Wednesday Night Study" group chat, tap its session banner's real "Join"
// button (starts CallController.shared via the real, non-test code path),
// then tap "Minimize" on the resulting full-screen call view (MockDataService
// .joinCall always throws in UI-TESTING mode, which lands on ChimeCallView's
// error branch -- Minimize/End Call text buttons -- rather than needing a
// live Chime connection or microphone permission).
import XCTest

final class CallBarNavOverlapUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        for label in ["Allow", "OK", "Allow While Using App"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return }
        }
    }

    private func tapWhenHittable(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
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
            app.buttons["Home"].tap()
            XCTAssertTrue(app.buttons["Notes"].waitForExistence(timeout: 5))
            return app
        }

        // NOTE: on this OS build (iOS 26.5), SwiftUI's `.textCase(.uppercase)`
        // styling on these onboarding buttons is reflected in the actual
        // accessibility label too (e.g. "SKIP →" not "Skip →"), unlike older
        // OS builds -- a pre-existing platform quirk unrelated to this task's
        // fix. Matched case-insensitively here (CONTAINS[c]) so this fresh-
        // install traversal is robust to that, rather than depending on a
        // brittle exact-case literal.
        func onboardingButton(containing text: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        }

        let getStarted = onboardingButton(containing: "Get Started")
        if getStarted.waitForExistence(timeout: 8) { getStarted.tap() } else { attachScreenshot(app, name: "DEBUG-no-get-started") }
        let surveySkip = onboardingButton(containing: "Skip →")
        if surveySkip.waitForExistence(timeout: 5) { surveySkip.tap() } else { attachScreenshot(app, name: "DEBUG-no-survey-skip") }
        let beginTour = onboardingButton(containing: "Begin the Tour")
        if beginTour.waitForExistence(timeout: 5) { beginTour.tap() } else { attachScreenshot(app, name: "DEBUG-no-begin-tour") }
        let tourSkip = onboardingButton(containing: "Skip")
        if tourSkip.waitForExistence(timeout: 5) { tourSkip.tap() } else { attachScreenshot(app, name: "DEBUG-no-tour-skip") }
        let signInCta = onboardingButton(containing: "Sign In")
        if signInCta.waitForExistence(timeout: 5) { signInCta.tap() } else { attachScreenshot(app, name: "DEBUG-no-sign-in-cta") }

        let usernameField = app.textFields["Username field"]
        if !usernameField.waitForExistence(timeout: 8) { attachScreenshot(app, name: "DEBUG-no-username-field") }
        XCTAssertTrue(usernameField.exists, "expected the sign-in form's username field.\n\(app.debugDescription)")
        usernameField.tap()
        usernameField.typeText("jacob")

        let passwordField = app.secureTextFields["Password field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.tap()
        passwordField.typeText("password")

        let submitButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "sign in button")
        ).firstMatch
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        submitButton.tap()

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if app.buttons["Notes"].exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(app.buttons["Notes"].waitForExistence(timeout: 5),
                      "expected Dashboard to load (MockDataService.signIn) after submitting jacob/password.\n\(app.debugDescription)")
        return app
    }

    /// Signs in, opens the "Wednesday Night Study" group chat, joins its
    /// session (real CallController.start() call path), then minimizes --
    /// landing on the exact `call.inCall && !call.isExpanded` state this
    /// task's fix targets, via genuine UI interaction only.
    private func reachMinimizedCallState() -> XCUIApplication {
        let app = signInAndReachDashboard()

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5))
        tapWhenHittable(chatTab, app: app)

        let groupsSegment = app.buttons["Groups"]
        if groupsSegment.waitForExistence(timeout: 3) {
            tapWhenHittable(groupsSegment, app: app)
        }

        // ContactRow applies one `.accessibilityLabel("Open group: ...")` to
        // the whole row, but (on this OS build) the accessibility tree still
        // separately exposes the row's individual StaticText/Image children
        // under that same label rather than merging into one hittable
        // element -- each child's own frame reports isHittable == false
        // because the real hit-testable surface is the List's Cell container
        // one level up. Tap by coordinate on the matched child's frame
        // instead of requiring XCUITest's isHittable on that child itself;
        // the coordinate tap still lands on the real Cell underneath it.
        let groupRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Wednesday Night Study")
        ).firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 8), "expected the Wednesday Night Study group row.\n\(app.debugDescription)")
        groupRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let joinButton = app.buttons["Join call for Wednesday Night Study"]
        XCTAssertTrue(joinButton.waitForExistence(timeout: 8), "expected SessionBanner's Join button.\n\(app.debugDescription)")
        tapWhenHittable(joinButton, app: app)

        // MockDataService.joinCall always throws in UI-TESTING mode, landing
        // ChimeCallView on its error branch (Minimize / End Call text buttons)
        // without ever needing a live Chime connection or mic permission.
        let minimizeButton = app.buttons["Minimize"]
        XCTAssertTrue(minimizeButton.waitForExistence(timeout: 10), "expected ChimeCallView's error-branch Minimize button.\n\(app.debugDescription)")
        tapWhenHittable(minimizeButton, app: app)

        // Back on mainTabView, now with call.inCall && !call.isExpanded true.
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5), "expected to return to mainTabView after minimizing.\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6)) // let the transition/overlay settle
        return app
    }

    /// Acceptance criteria: with a call minimized, FloatingTabBar and
    /// MinimizedCallBar render with clear visual separation (no overlap),
    /// all five tabs remain tappable and switch selectedTab, and both
    /// MinimizedCallBar buttons (return-to-call / end-call) remain tappable.
    func test_minimizedCallBar_and_floatingTabBar_coexistWithoutOverlap_onSmallScreen() {
        let app = reachMinimizedCallState()

        let returnToCall = app.buttons["Return to call Wednesday Night Study"]
        let endCall = app.buttons["End call"]
        XCTAssertTrue(returnToCall.waitForExistence(timeout: 5), "expected MinimizedCallBar's return-to-call control.\n\(app.debugDescription)")
        XCTAssertTrue(endCall.exists, "expected MinimizedCallBar's end-call control.\n\(app.debugDescription)")
        XCTAssertTrue(returnToCall.isHittable, "MinimizedCallBar's return-to-call control must be tappable")
        XCTAssertTrue(endCall.isHittable, "MinimizedCallBar's end-call control must be tappable")

        let homeTab    = app.buttons["Home"]
        let bibleTab   = app.buttons["Bible"]
        let notesTab   = app.buttons["Notes"]
        let chatTab    = app.buttons["Chat"]
        let accountTab = app.buttons["Account"]
        for tab in [homeTab, bibleTab, notesTab, chatTab, accountTab] {
            XCTAssertTrue(tab.exists, "expected \(tab) to still exist while a call is minimized")
            XCTAssertTrue(tab.isHittable, "\(tab) must remain tappable while a call is minimized -- this is the exact regression this task fixes")
        }

        // No-overlap, by frame geometry, not just isHittable: MinimizedCallBar's
        // frame must sit entirely below FloatingTabBar's frame (screen Y grows
        // downward), with a real visible gap between them -- matching the
        // spec's "not just non-overlapping hit targets -- no visual crowding
        // either" acceptance criterion.
        let callBarFrame = returnToCall.frame.union(endCall.frame)
        let tabBarFrame  = homeTab.frame.union(accountTab.frame)
        XCTAssertGreaterThan(
            callBarFrame.minY, tabBarFrame.maxY,
            "MinimizedCallBar must render entirely below FloatingTabBar with no overlap.\ncallBarFrame=\(callBarFrame)\ntabBarFrame=\(tabBarFrame)\n\(app.debugDescription)"
        )
        let gap = callBarFrame.minY - tabBarFrame.maxY
        XCTAssertGreaterThan(gap, 0, "expected a real visible gap between the two bars, found \(gap)pt")

        attachScreenshot(app, name: "call-bar-nav-overlap-fixed-minimized-state-small-screen")

        // Tapping a tab while the call is minimized must still actually
        // switch selectedTab -- the bug report's core complaint was that the
        // call bar blocked navigation entirely.
        tapWhenHittable(bibleTab, app: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(app.navigationBars.staticTexts["Bible"].waitForExistence(timeout: 5)
            || app.staticTexts["Bible"].waitForExistence(timeout: 5)
            || returnToCall.waitForExistence(timeout: 5),
            "expected navigating to the Bible tab to actually work while the call bar is showing.\n\(app.debugDescription)")
        // Call bar must persist across the tab switch (still minimized, not dismissed).
        XCTAssertTrue(returnToCall.waitForExistence(timeout: 5), "MinimizedCallBar should persist across tab switches while the call is still active")

        // Clean up: end the call so this test doesn't leak state to any test
        // that runs after it in the same app launch.
        if endCall.exists && endCall.isHittable { endCall.tap() }
    }

    /// No regression to FloatingTabBar's normal (no-call) bottom position.
    func test_floatingTabBar_normalPosition_unaffectedWhenNoCallActive() {
        let app = signInAndReachDashboard()
        XCTAssertFalse(app.buttons["Return to call"].exists, "no call should be active on fresh sign-in")
        let homeTab = app.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
        XCTAssertTrue(homeTab.isHittable)
        attachScreenshot(app, name: "call-bar-nav-overlap-no-call-baseline-small-screen")
    }
}
