// BibleReaderLiveFixScreenshotUITests.swift — throwaway live-render screenshot
// coverage for task 20260830-bible-reader-live-fix. This task's spec makes
// live confirmation (simulator screenshot minimum) a hard requirement, given
// the prior task (20260830-bible-reader-consistency) closed on static/source
// review alone and both issues it claimed to fix were still visibly present
// on-device. This test captures the Bible reader's live rendered state after
// applying `.sharedBackgroundVisibility(.hidden)` to both the leading
// book/chapter ToolbarItem and the trailing font-size/bookmark
// ToolbarItemGroup, and after adding the warm dual-RadialGradient bloom
// background.
//
// The onboarding-traversal helper below is copied from
// AccountUITests.signInAndReachAccount's established, already-fixed pattern
// (task 20260810-note-editor-tests-signin-not-hittable) rather than
// NoteDetailScreenshotUITests' older exact-string-match version: OBSurvey's
// "Skip →", OBBridge's "Begin the Tour →", and OBCta's "Sign In" are plain
// `Text` labels styled with `.textCase(.uppercase)` and no
// `.accessibilityLabel` override, so their real accessibility label is the
// rendered upper-cased string ("SKIP →", etc.) — confirmed live here again:
// an exact-string `app.buttons["Skip →"]` lookup silently never matches,
// stranding the flow on the survey screen indefinitely. Case-insensitive
// `CONTAINS[c]` matching (as AccountUITests already does) is required.
import XCTest

final class BibleReaderLiveFixScreenshotUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
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

    // Mirrors BibleNavDropdownUITests.waitHittableThenTap (the established
    // pattern for reaching BibleReaderView specifically) — takes an optional
    // `app` so it can dismiss a stray system alert mid-poll, and uses a
    // longer default ceiling than AccountUITests' generic onboarding-only
    // version since the Bible tab in particular was observed live to need
    // more settle time after the FloatingTabBar's selection-change spring
    // animation before becoming hittable.
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

        if !app.buttons["Home"].waitForExistence(timeout: 5) {
            func onboardingButton(containing text: String) -> XCUIElement {
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
            }

            // ── Onboarding (welcome -> survey -> bridge -> tour -> cta) ────
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

        // Also drop a copy to disk so it can be inspected directly without
        // pulling it out of the .xcresult bundle.
        if let pngData = screenshot.pngRepresentation as Data? {
            let dir = "/tmp/bible-reader-live-fix-screenshots"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = "\(dir)/\(name).png"
            try? pngData.write(to: URL(fileURLWithPath: path))
        }
    }

    func test_bibleReader_toolbarAndBackground_liveScreenshot() {
        // signInAndReachDashboard already lands on BibleReaderView (taps the
        // Bible tab and confirms the nav pill loaded).
        let app = signInAndReachDashboard()

        // Let the reader fully load and settle.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attachScreenshot(app, name: "bible-reader-live-fix-full")

        XCTAssertTrue(app.otherElements.firstMatch.exists)
    }

    // Confirms `.sharedBackgroundVisibility(.hidden)` on the trailing
    // ToolbarItemGroup (applied to the group as a whole, not split into two
    // ToolbarItems -- see BibleReaderView.swift's toolbar comment) didn't
    // regress either child's real behavior: font-size cycling and the
    // bookmark Menu's tap/presentation.
    func test_bibleReader_trailingToolbarGroup_fontSizeAndBookmarkMenu_stillFunctional() {
        let app = signInAndReachDashboard()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        // Font size cycle: tapping should advance past the initial label.
        let fontSizeButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Change font size")
        ).firstMatch
        XCTAssertTrue(fontSizeButton.waitForExistence(timeout: 8), "expected the font-size cycle button to still exist post-fix")
        let initialLabel = fontSizeButton.label
        XCTAssertTrue(waitHittableThenTap(fontSizeButton, app: app), "expected the font-size button to remain tappable after .sharedBackgroundVisibility(.hidden)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let afterTapLabel = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Change font size")
        ).firstMatch.label
        XCTAssertNotEqual(initialLabel, afterTapLabel, "expected the font-size cycle action to actually fire (label advances to the next size)")

        // Bookmark menu: tapping should present the menu (Add/Remove Bookmark item appears).
        let bookmarkButton = app.buttons["Bookmark options"]
        XCTAssertTrue(bookmarkButton.waitForExistence(timeout: 5), "expected the bookmark menu button to still exist post-fix")
        XCTAssertTrue(waitHittableThenTap(bookmarkButton, app: app), "expected the bookmark Menu to remain tappable after .sharedBackgroundVisibility(.hidden)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let bookmarkMenuItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Add Bookmark", "Remove Bookmark")
        ).firstMatch
        XCTAssertTrue(bookmarkMenuItem.waitForExistence(timeout: 5), "expected the bookmark Menu to actually present its Add/Remove Bookmark item")
        attachScreenshot(app, name: "bible-reader-live-fix-bookmark-menu-open")

        // Dismiss the menu so teardown doesn't leave a stray presentation.
        if bookmarkMenuItem.exists {
            app.tap()
        }
    }
}
