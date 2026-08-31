// NoteDetailToolbarEdgeBlurUITests.swift — live-render regression coverage,
// originally for task 20260829-note-detail-toolbar-edge-blur, retargeted by
// task 20260830-note-detail-scroll-fade-toolbar-bg to the corrected
// mechanism: the prior task fed the "blur the hard cutoff" ask into the
// TOOLBAR's own background (a top-opaque/bottom-clear tint), which the user
// then clarified was the wrong target -- they meant the note body's own
// scrolling content hard-cutting off under the nav bar. That's now fixed
// via a `.mask` feather on the ScrollView content itself (see
// NoteReplySectionTests.test_source_scrollViewContent_hasTopEdgeFeatherMask
// for the source-pin ViewInspector/XCUITest can't reach), and the toolbar's
// visible background/tint band behind Close/Edit has been removed entirely
// (test_source_toolbarBackgroundIsHidden_noVisibleTintBandBehindPills) per
// the user's separate ask -- there is deliberately no tint band left to
// visually confirm the feather edge of anymore.
//
// The intake spec's acceptance criteria are still explicitly about *visual*
// confirmation that code-level/source-pinning tests cannot provide on their
// own:
//
//   1. Note body title/text now fades out smoothly as it scrolls up toward
//      the nav bar -- no hard, ruler-straight cutoff line.
//   2. No distinct visible background/tint band remains behind Close/Edit --
//      they read as sitting directly on the bloom background.
//   3. A long note body scrolled to the top still does not visibly collide
//      with the Close/Edit pills -- the anti-scroll-collision duty the
//      retired toolbar tint used to carry now lives in the content-edge
//      mask instead (see NotesListView.swift's own comments on both).
//   4. Both Close and Edit toolbar pills show a single, clean outline --
//      specifically re-confirm Close, since a real on-device screenshot
//      (IMG_3037.png, attached to this task's request) showed a doubled/
//      haloed ring there despite `.sharedBackgroundVisibility(.hidden)`
//      already being present in source identically on both pills.
//
// This test drives the real running app (MockDataService, via the
// "UI-TESTING" launch argument -- same mechanism NoteEditorUITests already
// uses) to MockDataService.mockNotes["note-long-001"] (added for the prior
// task specifically because none of the pre-existing mock notes had a body
// long enough to reach the top of NoteDetailView's ScrollView under the
// toolbar) and attaches permanent screenshots to the test result for visual
// confirmation of both the content feather and the Close/Edit pill outlines
// (including a dedicated Close-pill-focused attachment for criterion 4
// above), in addition to asserting the Close/Edit pills stay genuinely
// tappable (a hittability check is the closest XCUITest assertion gets to
// "not obstructed") both at first render and after scrolling away and back
// to the top.
//
// Live-verification gap (testing gate, task
// 20260830-note-detail-scroll-fade-toolbar-bg): this file could not actually
// be *run* in this environment as of this pass. Confirmed directly:
// `DevToolsSecurity -status` reports Developer Mode disabled, and attempting
// `xcodebuild test` against this suite fails at app-under-test launch with
// `FBSOpenApplicationServiceErrorDomain` / "RequestDenied" (SBMainWorkspace
// denies the launch) -- this is specific to XCUITest, which must launch and
// debugger-attach to a separate app-under-test process; plain XCTest unit
// tests (NoteReplySectionTests, NoteDetailViewDirectionBTests,
// NotesAuthorOnlyEditGateTests) run in-process and were unaffected, and did
// run live for this pass. So criteria 1, 3, and 4 above (all needing an
// actual rendered screen) remain unconfirmed live pending Developer Mode
// being re-enabled on this host -- this file's assertions/comments are kept
// current for the corrected mechanism so the next run that CAN execute it
// verifies the real thing, but no live pass/fail for this suite should be
// assumed from this testing-gate pass.
import XCTest

final class NoteDetailToolbarEdgeBlurUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func tapWhenHittable(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            if element.exists {
                app.scrollViews.firstMatch.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("\(element) never became hittable within \(timeout)s\n\(app.debugDescription)")
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

        let getStarted = app.buttons["Get Started"]
        if getStarted.waitForExistence(timeout: 8) {
            getStarted.tap()
        }
        let surveySkip = app.buttons["Skip →"]
        if surveySkip.waitForExistence(timeout: 5) {
            surveySkip.tap()
        }
        let beginTour = app.buttons["Begin the Tour →"]
        if beginTour.waitForExistence(timeout: 5) {
            beginTour.tap()
        }
        let tourSkip = app.buttons["Skip"]
        if tourSkip.waitForExistence(timeout: 5) {
            tourSkip.tap()
        }
        let signInCta = app.buttons["Sign In"]
        if signInCta.waitForExistence(timeout: 5) {
            signInCta.tap()
        }

        let usernameField = app.textFields["Username field"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 8), "expected the sign-in form's username field")
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

        if !app.buttons["Notes"].waitForExistence(timeout: 5) {
            XCTFail("expected Dashboard to load (MockDataService.signIn) after submitting jacob/password.\n\(app.debugDescription)")
        }
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens MockDataService's dedicated long-body note ("note-long-001",
    /// "Long-Form Study Notes" -- added alongside this test specifically
    /// because it's the only mock note long enough to reach the top of the
    /// ScrollView underneath the toolbar) via the Notes tab.
    private func openLongNote(app: XCUIApplication) {
        let notesTab = app.buttons["Notes"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 5))
        tapWhenHittable(notesTab, app: app)

        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Long-Form Study Notes")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "expected MockDataService's long-body note row in the Notes list.\n\(app.debugDescription)")
        tapWhenHittable(row, app: app)
    }

    // MARK: - Content-edge feather + no toolbar tint + anti-scroll-collision
    // + single-clean-pill-outline, live render (task
    // 20260830-note-detail-scroll-fade-toolbar-bg)

    func test_longNote_contentEdgeIsFeathered_toolbarHasNoTintBand_closeEditPillsStayReachableWithCleanOutlines() {
        let app = signInAndReachDashboard()
        openLongNote(app: app)

        // NoteDetailView is a `.sheet` -- its own Close/Edit toolbar pills
        // are the confirmation this view actually presented (rather than
        // matching stale Notes-list content behind it).
        let closeButton = app.buttons["Close"]
        let editButton  = app.buttons["Edit"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 8), "expected NoteDetailView's Close pill.\n\(app.debugDescription)")
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "expected NoteDetailView's Edit pill (note-long-001 is authored by the signed-in mock user)")

        // Rest state: freshly opened, body content at the very top of the
        // ScrollView, directly underneath where the toolbar's now-removed
        // tint band used to sit -- exactly the state the pre-fix hard-cutoff
        // seam, any lingering visible tint band, and any real scroll-
        // collision would all show up in. Screenshot attached (kept
        // permanently in the test result bundle) for visual confirmation of
        // (a) the content feathering out (not flat-cut) as it nears the nav
        // bar and (b) no distinct background band behind Close/Edit.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5)) // let the sheet's presentation animation settle
        attachScreenshot(app, name: "note-detail-content-feather-and-no-toolbar-tint-rest-state")
        // Dedicated Close-pill-focused attachment: re-verifying acceptance
        // criterion 4 (IMG_3037.png showed a doubled/haloed ring on Close
        // specifically, despite .sharedBackgroundVisibility(.hidden) already
        // being present identically on both pills in source) is this file's
        // own name for this screenshot -- same full-screen capture as above,
        // named separately so a reviewer knows exactly which acceptance
        // criterion to check it against without re-deriving it.
        attachScreenshot(app, name: "note-detail-close-pill-outline-check")
        XCTAssertTrue(closeButton.isHittable, "Close pill must remain genuinely tappable with a long note body scrolled to the top -- not visually/hit-testably obstructed by body content")
        XCTAssertTrue(editButton.isHittable,  "Edit pill must remain genuinely tappable with a long note body scrolled to the top")

        // Scroll down into the body, then back up to the top -- the exact
        // motion the pre-R1 bug and this task's mandatory constraint are
        // both about (body text scrolling back up under the pills), not
        // just a freshly-rendered rest state.
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        scrollView.swipeUp()
        scrollView.swipeUp()
        scrollView.swipeDown()
        scrollView.swipeDown()
        scrollView.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        attachScreenshot(app, name: "note-detail-toolbar-top-after-scroll-round-trip")
        XCTAssertTrue(closeButton.isHittable, "Close pill must stay reachable after scrolling the long body away and back to the top")
        XCTAssertTrue(editButton.isHittable,  "Edit pill must stay reachable after scrolling the long body away and back to the top")

        // Regression: Close still dismisses the sheet.
        tapWhenHittable(closeButton, app: app)
        XCTAssertTrue(app.buttons["Create new note"].waitForExistence(timeout: 5),
                      "Close must still call dismiss() and close NoteDetailView")
    }
}
