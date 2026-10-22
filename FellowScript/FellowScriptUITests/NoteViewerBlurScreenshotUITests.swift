// NoteViewerBlurScreenshotUITests.swift -- live-render evidence for the iPad inline
// note viewer backdrop (Notes list blurred under the open note). Screenshot run.
import XCTest

final class NoteViewerBlurScreenshotUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = true }

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists {
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
        }
        let notNow = app.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
    }

    @discardableResult
    private func waitHittableThenTap(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(XCUIApplication())
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if element.exists && element.isHittable { element.tap(); return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func railMessages(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Messages")).firstMatch
    }
    private func accountMenu(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Account menu")).firstMatch
    }

    private func signInToWorkspace() -> XCUIApplication {
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

        if !railMessages(app).waitForExistence(timeout: 4) {
            // Walk the onboarding screens (iPad lays them out differently from the
            // phone, so step through whichever advance control is showing).
            let usernameProbe = app.textFields["Username field"]
            let advance: [XCUIElement] = [
                app.buttons["Get Started"],
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Skip →")).firstMatch,
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Begin the Tour →")).firstMatch,
                app.buttons["Skip"],
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign In")).firstMatch,
            ]
            let walkDeadline = Date().addingTimeInterval(60)
            while Date() < walkDeadline, !usernameProbe.exists {
                dismissSystemAlertIfPresent(app)
                for b in advance where b.exists && b.isHittable { b.tap(); break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            }
            let usernameField = app.textFields["Username field"]
            XCTAssertTrue(usernameField.waitForExistence(timeout: 8))
            waitHittableThenTap(usernameField)
            usernameField.typeText("jacob")
            let passwordField = app.secureTextFields["Password field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
            waitHittableThenTap(passwordField)
            passwordField.typeText("password")
            // On iPad the on-screen keyboard covers the submit button; the
            // keyboard's return key submits the form instead.
            passwordField.typeText("\n")
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let submit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sign in button")).firstMatch
            if submit.exists && submit.isHittable { submit.tap() }
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                dismissSystemAlertIfPresent(app)
                if railMessages(app).exists { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }
        XCTAssertTrue(railMessages(app).waitForExistence(timeout: 15), "expected the iPad workspace rail after sign-in.\n\(app.debugDescription)")
        return app
    }

    func test_ipad_inlineNoteViewer_backdrop() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = signInToWorkspace()
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        let notesRail = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Notes")).firstMatch
        waitHittableThenTap(notesRail)
        shot(app, "notes-panel-list")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Reflections")).firstMatch
        if !waitHittableThenTap(note) {
            let anyNote = app.scrollViews.descendants(matching: .staticText).element(boundBy: 2)
            waitHittableThenTap(anyNote)
        }
        shot(app, "note-viewer-open")
    }
}
