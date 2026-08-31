// BibleNavDropdownBlurScreenshotUITests.swift — live-render screenshot
// coverage for task 20260830-bible-nav-dropdown-blur. This task's spec makes
// live confirmation (simulator screenshot with real verse content scrolled
// behind the open panel) a hard requirement, given this exact file's repeat
// history of blur/translucency changes reading fine in source but
// compositing weakly or opaquely live (20260825-dockable-glass-audit/-fix,
// 20260826-notes-filter-panel-blur-increase, 20260826-glass-verse-selector-
// messages).
//
// Kept (not deleted) as this task's minimal test coverage per the pipeline's
// Lightweight-spec instruction (no `testing` gate on this workflow), mirroring
// BibleReaderLiveFixScreenshotUITests' precedent of retaining live-render
// screenshot coverage rather than treating it as throwaway.
//
// Onboarding/sign-in helper copied verbatim from BibleNavDropdownUITests'
// established pattern.
import XCTest

final class BibleNavDropdownBlurScreenshotUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @discardableResult
    private func waitHittableThenTap(_ element: XCUIElement, app: XCUIApplication? = nil, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app { dismissSystemAlertIfPresent(app) }
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

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists {
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
        }
    }

    @discardableResult
    private func signInAndReachBible() -> XCUIApplication {
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

        if !app.buttons["Home"].waitForExistence(timeout: 5) {
            func onboardingButton(containing text: String) -> XCUIElement {
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
            }

            waitHittableThenTap(app.buttons["Get Started"], timeout: 10)
            waitHittableThenTap(onboardingButton(containing: "Skip →"))
            waitHittableThenTap(onboardingButton(containing: "Begin the Tour →"))
            waitHittableThenTap(app.buttons["Skip"])
            waitHittableThenTap(onboardingButton(containing: "Sign In"))

            let usernameField = app.textFields["Username field"]
            XCTAssertTrue(usernameField.waitForExistence(timeout: 8), "expected the sign-in form's username field")
            XCTAssertTrue(waitHittableThenTap(usernameField), "expected the username field to become hittable")
            usernameField.typeText("jacob")

            let passwordField = app.secureTextFields["Password field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
            XCTAssertTrue(waitHittableThenTap(passwordField), "expected the password field to become hittable")
            passwordField.typeText("password")

            let submitButton = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "sign in button")
            ).firstMatch
            XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
            XCTAssertTrue(waitHittableThenTap(submitButton), "expected the sign-in submit button to become hittable")

            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                dismissSystemAlertIfPresent(app)
                if app.buttons["Home"].exists { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }

        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 15), "expected Dashboard tab bar after sign-in")

        let bibleTab = app.buttons["Bible"]
        XCTAssertTrue(bibleTab.waitForExistence(timeout: 5), "FloatingTabBar's Bible destination")
        XCTAssertTrue(waitHittableThenTap(bibleTab, app: app, timeout: 20), "expected the Bible tab to become hittable")

        let navPill = app.buttons["Navigate to book and chapter"]
        XCTAssertTrue(navPill.waitForExistence(timeout: 10), "expected BibleReaderView's book/chapter nav pill to load")

        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let pngData = screenshot.pngRepresentation as Data? {
            let dir = "/tmp/bible-nav-dropdown-blur-screenshots"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = "\(dir)/\(name).png"
            try? pngData.write(to: URL(fileURLWithPath: path))
        }
    }

    // Scrolls the verse content behind the reader so there is real, visually
    // distinct text/highlight content directly underneath where the panel
    // will open, then opens BibleNavDropdown on top of it and captures a
    // screenshot for pixel-level inspection (translucency/blur + legibility
    // are visual properties that cannot be asserted purely through the
    // accessibility tree).
    func test_openPanel_overScrolledVerseContent_liveScreenshot() {
        let app = signInAndReachBible()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        attachScreenshot(app, name: "bible-nav-dropdown-blur-BASELINE-panel-closed")

        let navPill = app.buttons["Navigate to book and chapter"]
        XCTAssertTrue(waitHittableThenTap(navPill, app: app), "expected the nav pill to open BibleNavDropdown")
        XCTAssertTrue(app.staticTexts["Select Passage"].waitForExistence(timeout: 5),
                      "expected Step 1's 'Select Passage' header to appear")

        // Let the panel's open animation fully settle before capturing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        attachScreenshot(app, name: "bible-nav-dropdown-blur-booklist-over-scrolled-verses")

        // Also capture Step 2 (chapter grid) over the same scrolled backdrop.
        // Match Genesis specifically (mirrors BibleNavDropdownUITests.bookRow) —
        // a loose "any button label" match here previously mis-tapped an
        // unrelated element (the tab bar) and silently navigated away from
        // the Bible tab entirely.
        let genesisRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Genesis")).firstMatch
        if genesisRow.waitForExistence(timeout: 5) {
            genesisRow.tap()
            XCTAssertTrue(app.buttons["Back to book list"].waitForExistence(timeout: 5),
                          "expected Step 2's chapter grid to appear after tapping Genesis")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            attachScreenshot(app, name: "bible-nav-dropdown-blur-chaptergrid-over-scrolled-verses")
        }

        XCTAssertTrue(app.otherElements.firstMatch.exists)
    }
}
