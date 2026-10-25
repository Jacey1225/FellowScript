// FormsRestyleScreenshotUITests.swift
// Task 20261023-forms-restyle: live-render capture of the migrated form screens
// against MockDataService (the "UI-TESTING" launch argument), so no real account
// or backend is involved. Writes PNGs to FORMS_SHOT_DIR (default
// /private/tmp/claude-501/forms-shots/ios) and also attaches them to the result.

import XCTest

final class FormsRestyleScreenshotUITests: XCTestCase {
    private let outDir = ProcessInfo.processInfo.environment["FORMS_SHOT_DIR"] ?? "/private/tmp/claude-501/forms-shots/ios"

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

    func test_captureAll() {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING"]
        app.terminate(); app.launch()

        func goToSignInForm() {
            if app.textFields["Username field"].exists { return }
            if app.buttons["Get Started"].waitForExistence(timeout: 8) {
                tap(app.buttons["Get Started"], app)
                tap(onboardingButton(app, "Skip →"), app)
                tap(onboardingButton(app, "Begin the Tour →"), app)
                tap(app.buttons["Skip"], app)
            }
            tap(onboardingButton(app, "Sign In"), app)
            _ = app.textFields["Username field"].waitForExistence(timeout: 10)
        }

        // ── Make sure we are signed in with the mock account ─────────────
        if !app.buttons["Home"].waitForExistence(timeout: 6) {
            goToSignInForm()
            let u = app.textFields["Username field"]
            tap(u, app); u.typeText("jacob")
            let p = app.secureTextFields["Password field"]
            tap(p, app); p.typeText("password")
            tap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "sign in button")).firstMatch, app)
            let end = Date().addingTimeInterval(20)
            while Date() < end { dismissSystemAlert(app); if app.buttons["Home"].exists { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        }
        shot(app, "00-home")

        // ── Chat sheets ──────────────────────────────────────────────────
        tap(app.buttons["Chat"], app)
        if tap(app.buttons["Add friend"], app) { _ = app.staticTexts["Add Friend"].waitForExistence(timeout: 6); shot(app, "04-add-friend"); tap(app.buttons["Cancel"], app) }
        if tap(app.buttons["Agents"], app) , tap(app.buttons["New agent"], app) { shot(app, "05-new-agent"); tap(app.buttons["Cancel"], app) }

        // ── Account ──────────────────────────────────────────────────────
        tap(app.buttons["Account"], app)
        _ = app.staticTexts["jacob"].waitForExistence(timeout: 15)
        shot(app, "06-account-top")
        let edit = app.buttons["Save profile changes"]
        scrollTo(edit, app); shot(app, "07-edit-profile")
        let tz = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Timezone:")).firstMatch
        if tap(tz, app) { shot(app, "08-timezone-picker"); tap(app.buttons["Done"], app) }
        let del = app.buttons["Delete account button"]
        scrollTo(del, app); shot(app, "09-danger-zone")
        if tap(del, app) {
            _ = app.staticTexts["Delete account"].waitForExistence(timeout: 6)
            shot(app, "10-delete-sheet-empty")
            let f = app.textFields["Type your username to confirm deletion"]
            if tap(f, app) { f.typeText("jacob") }
            shot(app, "11-delete-sheet-typed")
            tap(app.buttons["Delete my account"], app)
            _ = app.staticTexts["Confirm it's you"].waitForExistence(timeout: 6)
            shot(app, "12-delete-reauth")
        }

        // ── Sign out, then capture the auth screens ──────────────────────
        for _ in 0..<2 {
            if app.buttons["Close"].exists { tap(app.buttons["Close"], app); if app.buttons["Discard"].waitForExistence(timeout: 2) { tap(app.buttons["Discard"], app) } }
        }
        let out = app.buttons["Sign out of your account"]
        scrollTo(out, app)
        tap(out, app)
        goToSignInForm()
        shot(app, "13-signin")
        tap(app.buttons["Create Account"], app)
        shot(app, "14-create-account")
        tap(app.buttons["Sign In"], app)
        if tap(app.buttons["Forgot password"], app) {
            _ = app.staticTexts["Forgot password"].waitForExistence(timeout: 5)
            shot(app, "15-forgot-password")
        }
    }
}
