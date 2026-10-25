// FormsRestyleBatchCCaptureUITests.swift
// Task 20261023-forms-restyle: live-render capture of the migrated form screens
// against MockDataService (the "UI-TESTING" launch argument), so no real account
// or backend is involved. Writes PNGs to FORMS_SHOT_DIR (default
// /private/tmp/claude-501/forms-shots/ios-c) and also attaches them to the result.

import XCTest

final class FormsRestyleBatchCCaptureUITests: XCTestCase {
    private let outDir = ProcessInfo.processInfo.environment["FORMS_SHOT_DIR"] ?? "/private/tmp/claude-501/forms-shots/ios-c"

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let s = app.screenshot()
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func dismissSystemAlert(_ app: XCUIApplication) {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.exists { for l in ["Allow", "OK", "Allow While Using App"] where alert.buttons[l].exists { alert.buttons[l].tap(); return } }
        if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
    }

    @discardableResult
    private func tap(_ e: XCUIElement, _ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            dismissSystemAlert(app)
            if e.exists && e.isHittable { RunLoop.current.run(until: Date().addingTimeInterval(0.3)); if e.exists && e.isHittable { e.tap(); return true } }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func scrollTo(_ e: XCUIElement, _ app: XCUIApplication) {
        let end = Date().addingTimeInterval(25)
        while Date() < end {
            if e.exists && e.isHittable { return }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    private func onboardingButton(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func signedIn(_ app: XCUIApplication) {
        if app.buttons["Home"].waitForExistence(timeout: 6) { return }
        if app.buttons["Get Started"].waitForExistence(timeout: 8) {
            tap(app.buttons["Get Started"], app)
            tap(onboardingButton(app, "Skip →"), app)
            tap(onboardingButton(app, "Begin the Tour →"), app)
            tap(app.buttons["Skip"], app)
        }
        tap(onboardingButton(app, "Sign In"), app)
        let u = app.textFields["Username field"]; _ = u.waitForExistence(timeout: 10)
        tap(u, app); u.typeText("jacob")
        let p = app.secureTextFields["Password field"]
        tap(p, app); p.typeText("password")
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sign in button")).firstMatch, app)
        let end = Date().addingTimeInterval(20)
        while Date() < end { dismissSystemAlert(app); if app.buttons["Home"].exists { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
    }

    func test_captureBatchCAndAdScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING"]
        app.terminate(); app.launch()
        signedIn(app)

        tap(app.buttons["Chat"], app)
        let groupsSeg = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Groups")).firstMatch
        if !tap(groupsSeg, app, timeout: 4) { app.staticTexts["Groups"].tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        shot(app, "c00-groups-list")
        let row = app.staticTexts["Wednesday Night Study"]
        var opened = false
        _ = row.waitForExistence(timeout: 6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.37)).tap(); opened = true
        if opened {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            shot(app, "c01-group-conversation")
            // Send one long mock message so a long bubble is on screen.
            let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
            if field.waitForExistence(timeout: 4), tap(field, app) {
                field.typeText("Reading Psalm 23 together last night reminded me how much I need to slow down and actually listen instead of just reading. Could we spend a few minutes on verse 2 on Wednesday and talk about what rest looks like for each of us this week?")
                shot(app, "c02-composer-long-message")
                let send = app.buttons["Send message"].exists ? app.buttons["Send message"] : app.buttons["Send"]
                if send.exists { send.tap() }
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                shot(app, "c03-conversation-after-send")
            }
            app.swipeDown() // dismiss keyboard if present
            // Session creator (batch C, stepper)
            let sched = app.buttons["Schedule a new session"]
            if !sched.exists { tap(app.buttons["Sessions"], app) }
            if tap(app.buttons["Schedule a new session"], app) {
                _ = app.staticTexts["Schedule"].waitForExistence(timeout: 6)
                shot(app, "c04-session-creator-basics")
                let t = app.textFields["Session title"]
                if tap(t, app) { t.typeText("Evening Study") }
                shot(app, "c05-session-creator-typed")
                tap(app.buttons["Next"], app); shot(app, "c06-session-creator-study")
                tap(app.buttons["Next"], app); shot(app, "c07-session-creator-options")
            }
        }
        shot(app, "c99-final-state")
        print(app.debugDescription.prefix(6000))
    }
}
