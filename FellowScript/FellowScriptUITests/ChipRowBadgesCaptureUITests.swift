// ChipRowBadgesCaptureUITests.swift -- screenshots of the group chat chip row with unseen
// badges (UI-TESTING-BADGES seam, mock data only) and the Sessions / Announcements submenus.

import XCTest

final class ChipRowBadgesCaptureUITests: XCTestCase {
    private let outDir = ProcessInfo.processInfo.environment["FORMS_SHOT_DIR"] ?? "/private/tmp/claude-501/forms-shots/chiprow"

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

    func test_captureChipRow() {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING", "UI-TESTING-BADGES"]
        app.terminate(); app.launch()
        signedIn(app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Chat")).firstMatch, app)
        let groupsSeg = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Groups")).firstMatch
        if !tap(groupsSeg, app, timeout: 4) { app.staticTexts["Groups"].tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        _ = app.staticTexts["Wednesday Night Study"].waitForExistence(timeout: 6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.37)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        shot(app, "chip-01-row-with-badges")
        if tap(app.buttons["Sessions"], app, timeout: 6) { RunLoop.current.run(until: Date().addingTimeInterval(1.0)); shot(app, "chip-02-sessions-panel") }
        if tap(app.buttons["Announcements"], app, timeout: 6) { RunLoop.current.run(until: Date().addingTimeInterval(1.0)); shot(app, "chip-03-announcements-panel") }
    }
}
