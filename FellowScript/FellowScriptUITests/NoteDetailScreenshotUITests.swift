// NoteDetailScreenshotUITests.swift — live-render screenshot coverage for
// three already-landed, already-passed fixes that never got a retained
// on-device screenshot from any gate:
//
//   1. task 20260829-note-detail-toolbar-visual-fix — NoteDetailView's
//      toolbar no longer shows a hard gray bar at the top, and Close/Edit
//      each carry a single clean outline (not the doubled system-glass +
//      app-pill stroke). frontend.json/testing.json for that task both cite
//      a live Simulator screenshot as evidence but never attached one as a
//      retained XCTAttachment.
//   2. task 20260829-notes-edit-author-gate — a group note NOT authored by
//      the signed-in mock user must show no Edit/Delete affordance, neither
//      in NotesListView's row (swipe-to-delete / long-press context menu)
//      nor in NoteDetailView's toolbar (no Edit pill). That task's testing
//      gate covered this with unit/source tests only — it explicitly never
//      got a live-render pass.
//   3. task 20260829-notes-first-reply-empty-state — a group note with zero
//      replies must render "No replies yet." plus an "Add a reply" pill in
//      NoteDetailView, instead of the pre-fix nothing-at-all. That task's
//      testing gate never got a live xcodebuild run at all (blocked on a
//      SourceKit lock held by the user's own long-running Xcode.app GUI
//      session), so this is also its first live confirmation.
//
// Drives the real running app via MockDataService's "UI-TESTING" launch
// argument, the same mechanism NoteEditorUITests / NoteDetailToolbarEdgeBlurUITests
// already use. Uses MockDataService.mockNotes["note-grp-002"] ("Wednesday
// Group Reflections") — added alongside this test specifically because the
// only pre-existing group note (note-grp-001) is authored by the current
// mock user with `username` left completely unset, which only ever exercises
// the deny-by-default "undecoded author" fallback, never the genuine
// "someone else's note" comparison branch these gates exist for. note-grp-002
// is authored by a different mock user ("Sarah") and has zero mock replies,
// covering both fixture needs (2) and (3) with the same note.
import XCTest

final class NoteDetailScreenshotUITests: XCTestCase {

    override func setUpWithError() throws {
        // Screenshot-evidence run, not a strict pass/fail regression gate —
        // one flaky long-press/context-menu interaction shouldn't cost the
        // screenshots already captured earlier in the same test.
        continueAfterFailure = true
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

    private func openNotesTab(app: XCUIApplication) {
        let notesTab = app.buttons["Notes"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 5))
        tapWhenHittable(notesTab, app: app)
    }

    // MARK: - 1. Clean toolbar (no gray bar, single outline) on a personal note

    func test_noteDetailSheet_cleanToolbar_screenshot() {
        let app = signInAndReachDashboard()
        openNotesTab(app: app)

        // note-001 ("Sunday Service 06/28") — a personal note authored by
        // the signed-in mock user, so both Close and Edit pills render.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Sunday Service 06/28")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "expected the Sunday Service 06/28 personal note row.\n\(app.debugDescription)")
        tapWhenHittable(row, app: app)

        let closeButton = app.buttons["Close"]
        let editButton  = app.buttons["Edit"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 8), "expected NoteDetailView's Close pill.\n\(app.debugDescription)")
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "expected NoteDetailView's Edit pill (note-001 is authored by the signed-in mock user)")

        RunLoop.current.run(until: Date().addingTimeInterval(0.5)) // let the sheet's presentation animation settle
        attachScreenshot(app, name: "note-detail-toolbar-visual-fix-clean-toolbar")

        XCTAssertTrue(closeButton.isHittable)
        XCTAssertTrue(editButton.isHittable)
    }

    // MARK: - 2. Group note NOT authored by the current mock user: no Edit/Delete anywhere

    func test_groupNoteNotAuthoredByCurrentUser_hidesEditDeleteAffordances() {
        let app = signInAndReachDashboard()
        openNotesTab(app: app)

        // Switch to the "Wednesday Night Study" group segment — group notes
        // (group_id "group-abc") aren't shown under the default Personal
        // filter chip.
        let groupChip = app.buttons["Wednesday Night Study"]
        XCTAssertTrue(groupChip.waitForExistence(timeout: 5), "expected the group filter chip.\n\(app.debugDescription)")
        tapWhenHittable(groupChip, app: app)

        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Wednesday Group Reflections")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "expected note-grp-002's row in the Wednesday Night Study segment.\n\(app.debugDescription)")

        // Long-press → context menu. canModify(note) is false for this note
        // (authored by "Sarah", not the signed-in "jacob"), so the
        // .contextMenu content is empty — no Edit/Delete items should appear.
        row.press(forDuration: 1.0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        attachScreenshot(app, name: "notes-list-context-menu-no-edit-delete")
        XCTAssertFalse(app.buttons["Edit"].exists, "non-author group note must not show an Edit context-menu item")
        XCTAssertFalse(app.buttons["Delete"].exists, "non-author group note must not show a Delete context-menu item")
        // Dismiss whatever (if anything) the long-press surfaced.
        app.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // Swipe-to-delete. canModify(note) false → no swipeActions content
        // registered for this row, so no Delete action should be revealed.
        if row.exists {
            row.swipeLeft()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            attachScreenshot(app, name: "notes-list-swipe-no-delete")
            XCTAssertFalse(app.buttons["Delete"].exists, "non-author group note must not reveal a swipe-to-delete action")
        }

        // Into NoteDetailView: toolbar should show only Close, never Edit.
        let freshRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Wednesday Group Reflections")
        ).firstMatch
        XCTAssertTrue(freshRow.waitForExistence(timeout: 5))
        tapWhenHittable(freshRow, app: app)

        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 8), "expected NoteDetailView's Close pill.\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        attachScreenshot(app, name: "note-detail-no-edit-pill-non-author")
        XCTAssertFalse(app.buttons["Edit"].exists, "NoteDetailView must not show an Edit pill for a note not authored by the signed-in user")
    }

    // MARK: - 3. Zero-reply group note: "No replies yet." + "Add a reply" pill

    func test_groupNoteWithZeroReplies_showsEmptyStateAndComposerPill() {
        let app = signInAndReachDashboard()
        openNotesTab(app: app)

        let groupChip = app.buttons["Wednesday Night Study"]
        XCTAssertTrue(groupChip.waitForExistence(timeout: 5))
        tapWhenHittable(groupChip, app: app)

        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Wednesday Group Reflections")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "expected note-grp-002's zero-reply row.\n\(app.debugDescription)")
        tapWhenHittable(row, app: app)

        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 8), "expected NoteDetailView to present.\n\(app.debugDescription)")

        let emptyStateLine = app.staticTexts["No replies yet."]
        let addReplyPill   = app.buttons["Add a reply"]
        XCTAssertTrue(emptyStateLine.waitForExistence(timeout: 8), "expected the zero-reply empty-state line once replies finish loading.\n\(app.debugDescription)")
        XCTAssertTrue(addReplyPill.waitForExistence(timeout: 5), "expected the Add a reply composer pill")

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        attachScreenshot(app, name: "note-detail-zero-replies-empty-state")

        XCTAssertTrue(addReplyPill.isHittable, "Add a reply pill must be genuinely tappable")
    }
}
