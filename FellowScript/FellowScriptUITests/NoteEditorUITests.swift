// NoteEditorUITests.swift — end-to-end regression coverage for the warm-bloom
// / glass-card / Option-C header-controls redesign of NoteEditorView.swift
// (task: 20260806-note-editor-implementation).
//
// The redesign was explicitly appearance-only: Cancel → dismiss(), Save →
// handleSave()'s existing async flow, and the $isPublic binding all had to
// keep working exactly as before — only their visual shape/position (ghost
// chip, icon-badge pill, bottom-right FAB) changed. NoteEditorView keeps all
// of that as private @State with no ViewInspector dependency in this project,
// so these tests drive the real, running app through the same accessibility
// labels VoiceOver uses (several of which the spec calls out by name as
// "preserved verbatim") rather than reaching into private state.
//
// The app defaults AppState to MockDataService (see AppState.swift's
// `service: DataServiceProtocol = MockDataService.shared`), which accepts
// username "jacob" / password "password" and always succeeds on saveNote(),
// so these tests run fully offline against the same mock the rest of the
// app already runs on in this environment.
//
// Known gap: isReadOnly:true (Done chip / hidden FAB+Public+toolbar) has no
// reachable call site anywhere in the current app (DashboardView.swift and
// NotesListView.swift both only ever construct NoteEditorView with
// isReadOnly: false) — that is pre-existing and unrelated to this task's
// diff, so there is no live UI path to exercise it end-to-end here.

import XCTest

final class NoteEditorUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tap helper (tolerates the system push-notification permission
    // alert still settling/dismissing right after sign-in)

    private func tapWhenHittable(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            // Dashboard's quick actions can sit below the fold on shorter
            // simulators — scroll them into view rather than waiting forever.
            if element.exists {
                app.scrollViews.firstMatch.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("\(element) never became hittable within \(timeout)s\n\(app.debugDescription)")
    }

    /// Directly dismisses the push-notification permission alert if it's on
    /// screen, without blindly tapping the app (a blind center-tap can land
    /// on real Dashboard content — e.g. the Community Activity widget — and
    /// silently navigate away, which is not what we want from a "nudge").
    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        for label in ["Allow", "OK", "Allow While Using App"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return }
        }
    }

    // MARK: - Shared flow: onboarding + sign-in (idempotent — no-ops once already signed in)

    @discardableResult
    private func signInAndReachDashboard() -> XCUIApplication {
        let app = XCUIApplication()

        // Auto-accept the "Would you like to send you notifications?" system
        // prompt that requestPushNotifications() triggers right after login.
        addUIInterruptionMonitor(withDescription: "System permission alerts") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        // Route the app at MockDataService instead of the live backend (see
        // FellowScriptApp.swift) so this test is deterministic and offline.
        // terminate() first so every test gets a real cold launch rather than
        // resuming whatever tab a previous test left the app on.
        app.launchArguments = ["UI-TESTING"]
        app.terminate()
        app.launch()

        // Already onboarded + signed in from a prior test in this run — jump
        // back to the Home tab (a previous test may have left another tab
        // selected) where Dashboard's "New note" quick action lives.
        if app.buttons["Home"].waitForExistence(timeout: 3) {
            app.buttons["Home"].tap()
            XCTAssertTrue(app.buttons["New note"].waitForExistence(timeout: 5))
            return app
        }

        // ── Onboarding (welcome → survey → bridge → tour → cta) ────────────
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

        // ── Sign in with the MockDataService stub credentials ──────────────
        let usernameField = app.textFields["Username field"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 8), "expected the sign-in form's username field")
        usernameField.tap()
        usernameField.typeText("jacob")

        let passwordField = app.secureTextFields["Password field"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.tap()
        passwordField.typeText("password")

        // NOTE: the accessibilityLabel is set verbatim to "Sign In button" in
        // AuthView.swift, but the ambient .textCase(.uppercase) styling on the
        // button's Text sibling causes iOS to report it to XCUITest in all
        // caps — match case-insensitively rather than relying on exact case.
        let submitButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "sign in button")
        ).firstMatch
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        submitButton.tap()

        // Poll for Dashboard, directly dismissing the push-notification
        // permission alert if/when it appears (see dismissSystemAlertIfPresent —
        // deliberately not a blind app.tap(), which can land on real Dashboard
        // content like the Community Activity widget and navigate away).
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if app.buttons["New note"].exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        if !app.buttons["New note"].waitForExistence(timeout: 5) {
            XCTFail("expected Dashboard to load (MockDataService.signIn) after submitting jacob/password.\n\(app.debugDescription)")
        }
        return app
    }

    // MARK: - Cancel → dismiss() (ghost-chip, Option C)

    func test_cancelChip_dismissesNoteEditorWithoutSaving() {
        let app = signInAndReachDashboard()

        tapWhenHittable(app.buttons["New note"], app: app)

        let cancelChip = app.buttons["Cancel and discard changes"]
        XCTAssertTrue(cancelChip.waitForExistence(timeout: 5),
                     "the ghost-chip Cancel control's accessibilityLabel must be preserved verbatim")
        cancelChip.tap()

        // Sheet dismissed — Dashboard's own controls are reachable again.
        XCTAssertTrue(app.buttons["New note"].waitForExistence(timeout: 5),
                      "tapping Cancel must still call dismiss() and close the editor")
    }

    // MARK: - Public toggle (icon-badge pill, Option C) still drives $isPublic

    func test_publicBadge_tapTogglesPrivatePublicState() {
        let app = signInAndReachDashboard()

        tapWhenHittable(app.buttons["New note"], app: app)

        let privateBadge = app.buttons["This note is private. Tap to make it public."]
        XCTAssertTrue(privateBadge.waitForExistence(timeout: 5),
                      "a brand-new note must default to private, shown via the icon-badge Public pill")
        privateBadge.tap()

        let publicBadge = app.buttons["This note is public. Tap to make it private."]
        XCTAssertTrue(publicBadge.waitForExistence(timeout: 3),
                      "tapping the icon-badge Public pill must still flip the underlying $isPublic binding")

        // Tapping again must flip it back — proves it's a real toggle, not one-shot.
        publicBadge.tap()
        XCTAssertTrue(app.buttons["This note is private. Tap to make it public."].waitForExistence(timeout: 3))

        app.buttons["Cancel and discard changes"].tap()
    }

    // MARK: - Save FAB → handleSave() → onSave → dismiss (success path, end-to-end)

    func test_saveFAB_success_dismissesEditorAndPersistsThroughMockDataService() {
        let app = signInAndReachDashboard()

        // Notes tab wires a real onSave closure through to MockDataService.saveNote
        // (Dashboard's "New note" shortcut does not supply onSave, so use the
        // Notes tab's "Create new note" entry point to exercise the full,
        // real save round-trip handleSave() drives).
        let notesTab = app.buttons["Notes"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 5), "FloatingTabBar's Notes destination")
        tapWhenHittable(notesTab, app: app)

        let createNote = app.buttons["Create new note"]
        XCTAssertTrue(createNote.waitForExistence(timeout: 5))
        createNote.tap()

        let titleField = app.textFields["Note title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        let uniqueTitle = "UI Test Note \(Int(Date().timeIntervalSince1970))"
        titleField.typeText(uniqueTitle)

        // Dismiss the keyboard first (it can otherwise cover the bottom-right FAB) —
        // the writing area has .scrollDismissesKeyboard(.interactively), so a
        // downward swipe on it closes the keyboard without touching any control.
        app.scrollViews.firstMatch.swipeDown()

        let saveFAB = app.buttons["Save note"]
        XCTAssertTrue(saveFAB.waitForExistence(timeout: 5), "the relocated bottom-right gradient Save FAB must still expose the preserved 'Save note' accessibilityLabel")
        tapWhenHittable(saveFAB, app: app)

        // Success dismisses the editor sheet and the new note shows up in the list —
        // proves handleSave()'s async onSave/dismiss flow is unchanged end-to-end,
        // not just that a button with the right label exists. NoteRow's
        // accessibilityLabel is "Note: <title>. <preview>" (NotesListView.swift).
        let savedNote = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", uniqueTitle)
        ).firstMatch
        XCTAssertTrue(savedNote.waitForExistence(timeout: 8),
                      "after a successful save the new note must appear back in the Notes list")
    }
}
