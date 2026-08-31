// AgentChatVisualParityScreenshotUITests.swift — throwaway live-render
// screenshot coverage for task 20260830-agent-chat-visual-parity-ios.
//
// The intake spec for this task makes a live simulator confirmation a hard
// requirement ("Confirm live (simulator screenshot) before calling this
// done", acceptance criteria 1/4/5/6/7 all call out live rendering rather
// than source review alone). This is a Lightweight, single-gate (frontend)
// task, so this minimal screenshot test is the frontend gate's own
// verification, not a substitute for whatever the testing gate later adds.
//
// Drives the real running app via MockDataService's "UI-TESTING" launch
// argument (same mechanism as NoteDetailScreenshotUITests /
// BibleReaderLiveFixScreenshotUITests). MockDataService.mockAgents has one
// agent ("agent-001", role text resolves via FSAgent.displayLabel to
// "Spiritual Guide") with MockDataService.mockAgentMessages seeding both an
// incoming (agent) and outgoing (mine) message, so a single screenshot shows
// both bubble sides plus their avatar badges/sender-name rows.
//
// Sign-in/onboarding helper copied from BibleReaderLiveFixScreenshotUITests'
// established pattern (case-insensitive CONTAINS matching for onboarding's
// upper-cased Text labels, waitHittableThenTap for FloatingTabBar's
// spring-animation settle time).
import XCTest

final class AgentChatVisualParityScreenshotUITests: XCTestCase {

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
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let pngData = screenshot.pngRepresentation as Data? {
            let dir = "/tmp/agent-chat-visual-parity-screenshots"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = "\(dir)/\(name).png"
            try? pngData.write(to: URL(fileURLWithPath: path))
        }
    }

    func test_agentChatView_emberGlassParity_liveScreenshot() {
        let app = signInAndReachDashboard()

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5), "FloatingTabBar's Chat destination")
        XCTAssertTrue(waitHittableThenTap(chatTab, app: app, timeout: 20), "expected the Chat tab to become hittable")

        let agentsSegment = app.buttons["Agents"]
        XCTAssertTrue(agentsSegment.waitForExistence(timeout: 10), "expected ChatRootView's Agents segment pill")
        XCTAssertTrue(waitHittableThenTap(agentsSegment, app: app), "expected the Agents segment to become hittable")

        // MockDataService.mockAgents' single agent (role text resolves to
        // "Spiritual Guide" via FSAgent.displayLabel). AgentRow's icon/name/
        // status all inherit ChatRootView's per-row .accessibilityLabel, so
        // several XCUIElementTypeAny descendants share the same label —
        // tap the actual List row (Cell) rather than one of those inherited
        // leaf elements, which observed live to not reliably register as
        // hittable on its own.
        let agentRow = app.cells.firstMatch
        XCTAssertTrue(agentRow.waitForExistence(timeout: 10), "expected the mock agent's row.\n\(app.debugDescription)")
        XCTAssertTrue(waitHittableThenTap(agentRow, app: app), "expected the agent row to become hittable")

        // AgentChatView's ported header: back chevron + identity label, no
        // "Schedule" pill anywhere on screen (that's ChatThreadView-only).
        let backButton = app.buttons["Go back"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 10), "expected AgentChatView's ported RoundIconButton back affordance.\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Schedule"].exists, "agent chat must never show the regular chat's Schedule pill")

        // Let the message list/composer settle before capturing.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        attachScreenshot(app, name: "agent-chat-ember-glass-parity")

        // Composer placeholder copy is agent-specific and must survive the
        // visual port unchanged.
        XCTAssertTrue(
            app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] %@", "Ask about Scripture")).firstMatch.exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Ask about Scripture")).firstMatch.exists,
            "expected the \"Ask about Scripture…\" composer placeholder to be preserved"
        )
    }
}
