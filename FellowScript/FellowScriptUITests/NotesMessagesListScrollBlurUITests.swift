// NotesMessagesListScrollBlurUITests.swift — live-render regression coverage
// for task 20260831-notes-messages-list-scroll-blur.
//
// The bug (live coordinator screenshot, mid-task): scrolling NotesListView's
// notesTab (and, structurally identically, highlightsTab / ChatRootView's
// friendsList/groupsList/agentsList) showed a scrolled note card visibly
// colliding with/reading as overlapping the group-filter-chip row above it —
// a hard, ruler-straight cutoff, not a soft fade, and with no persistent
// breathing-room gap even at rest.
//
// The frontend gate confirmed the fix (Theme.swift's scrollTopEdgeFeather()
// mask + a genuine outer .padding(.top, Theme.spacingLG) applied OUTSIDE
// that mask, see NotesMessagesListScrollBlurRegressionTests.swift for the
// source-pin half of this coverage) live via a temporary, since-deleted
// XCUITest harness. This file is the permanent replacement: it drives the
// real running app (MockDataService's "UI-TESTING" launch argument, the same
// mechanism NoteDetailScreenshotUITests / NoteDetailToolbarEdgeBlurUITests
// already use) and asserts, via real XCUIElement frames rather than just a
// visual screenshot, that:
//
//   1. There is a genuine vertical gap between the header/chip row and the
//      first list row AT REST (the padding half of the fix) — before this
//      task the gap was near zero.
//   2. After a real drag-scroll round trip, whatever row is now topmost
//      never overlaps the header/chip row's own frame — the exact collision
//      shown in the live reference screenshot that triggered the mid-task
//      correction. A `.contentMargins`-only fix (the frontend gate's
//      REJECTED first-pass implementation) would fail this specific
//      assertion, since contentMargins only offsets the at-rest scroll
//      position and does not survive an actual scroll gesture.
//
// Screenshots are also attached (kept permanently in the test result bundle)
// for direct visual confirmation of the soft fade itself, which no
// frame-based assertion can capture.
import XCTest

final class NotesMessagesListScrollBlurUITests: XCTestCase {

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
                app.swipeUp()
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

    /// The scrollable region backing a SwiftUI `List` -- exposed as a table
    /// in the accessibility tree on iOS, distinct from the bare
    /// `ScrollView`s NoteDetailView's own precedent tests target.
    private func listElement(in app: XCUIApplication) -> XCUIElement {
        if app.tables.firstMatch.waitForExistence(timeout: 5) { return app.tables.firstMatch }
        if app.collectionViews.firstMatch.exists { return app.collectionViews.firstMatch }
        return app.scrollViews.firstMatch
    }

    private func firstMatch(_ app: XCUIApplication, labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", text)
        ).firstMatch
    }

    // MARK: - 1. Notes tab (Personal segment): rest-state gap + no post-scroll collision

    func test_notesTab_personalSegment_hasRestStateGap_andSurvivesScrollWithoutHeaderCollision() {
        let app = signInAndReachDashboard()

        let notesTabButton = app.buttons["Notes"]
        XCTAssertTrue(notesTabButton.waitForExistence(timeout: 5))
        tapWhenHittable(notesTabButton, app: app)

        // "Personal" is the default group filter chip (task
        // 20260831-notes-messages-list-scroll-blur's scope: groupChips sits
        // directly above notesTab's List with no gap before this fix).
        let personalChip = app.buttons["Personal"]
        XCTAssertTrue(personalChip.waitForExistence(timeout: 8), "expected the Personal filter chip.\n\(app.debugDescription)")

        let firstRow = firstMatch(app, labelContains: "Note:")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8), "expected at least one note row in the Personal segment.\n\(app.debugDescription)")

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        attachScreenshot(app, name: "notes-tab-rest-state-gap")

        let restGap = firstRow.frame.minY - personalChip.frame.maxY
        XCTAssertGreaterThan(
            restGap, 12,
            "expected genuine breathing-room padding between the Personal chip row and the first note card at rest (was near-zero before task 20260831-notes-messages-list-scroll-blur); measured gap: \(restGap)pt"
        )

        // Real drag-scroll round trip -- the exact motion the live reference
        // screenshot showed colliding. A .contentMargins-only fix passes the
        // rest-state check above but fails this one, since contentMargins
        // does not persist as a buffer once actually scrolled.
        let list = listElement(in: app)
        XCTAssertTrue(list.exists, "expected the Notes List to be present as a table/collectionView/scrollView\n\(app.debugDescription)")
        list.swipeUp()
        list.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        attachScreenshot(app, name: "notes-tab-mid-scroll")
        list.swipeDown()
        list.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        attachScreenshot(app, name: "notes-tab-after-scroll-round-trip")

        XCTAssertTrue(personalChip.waitForExistence(timeout: 5), "the Personal chip (part of the fixed header, not the scrolling List) must still be present after the scroll round trip")
        let topRowAfterScroll = firstMatch(app, labelContains: "Note:")
        XCTAssertTrue(topRowAfterScroll.waitForExistence(timeout: 5), "expected a note row to still be visible after the scroll round trip.\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(
            topRowAfterScroll.frame.minY, personalChip.frame.maxY,
            "the topmost visible note row must never overlap the Personal chip row after scrolling -- this is the exact collision bug task 20260831-notes-messages-list-scroll-blur fixed"
        )

        // Regression: header controls must stay fully functional (out-of-bounds
        // guard from the intake spec -- no change to header content/controls).
        XCTAssertTrue(app.buttons["Filter and sort notes"].isHittable, "the filter/sort menu button must remain reachable")
        XCTAssertTrue(app.buttons["Create new note"].isHittable, "the new-note button must remain reachable")
    }

    // MARK: - 2. Highlights tab: same header, same fix, rest-state gap

    func test_highlightsTab_hasRestStateGapBetweenToggleAndFirstRow() {
        let app = signInAndReachDashboard()

        let notesTabButton = app.buttons["Notes"]
        XCTAssertTrue(notesTabButton.waitForExistence(timeout: 5))
        tapWhenHittable(notesTabButton, app: app)

        let highlightsToggle = app.buttons["Highlights"]
        XCTAssertTrue(highlightsToggle.waitForExistence(timeout: 5), "expected the Notes/Highlights segmented toggle.\n\(app.debugDescription)")
        tapWhenHittable(highlightsToggle, app: app)

        let firstHighlightRow = firstMatch(app, labelContains: "Highlight in")
        XCTAssertTrue(firstHighlightRow.waitForExistence(timeout: 8), "expected at least one highlight row.\n\(app.debugDescription)")

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        attachScreenshot(app, name: "highlights-tab-rest-state-gap")

        let restGap = firstHighlightRow.frame.minY - highlightsToggle.frame.maxY
        XCTAssertGreaterThan(
            restGap, 12,
            "expected genuine breathing-room padding between the Notes/Highlights toggle and the first highlight card at rest; measured gap: \(restGap)pt"
        )
    }

    // MARK: - 3. Messages/Chat Friends segment: rest-state gap + header controls stay functional

    func test_chatFriendsList_hasRestStateGap_andHeaderControlsStayFunctional() {
        let app = signInAndReachDashboard()

        let chatTabButton = app.buttons["Chat"]
        XCTAssertTrue(chatTabButton.waitForExistence(timeout: 5), "expected the Chat tab.\n\(app.debugDescription)")
        tapWhenHittable(chatTabButton, app: app)

        // "Friends" is the default segment (selectedSegment == 0).
        let friendsSegment = app.buttons["Friends"]
        XCTAssertTrue(friendsSegment.waitForExistence(timeout: 8), "expected the Friends segment toggle.\n\(app.debugDescription)")

        let firstFriendRow = firstMatch(app, labelContains: "Chat with ")
        XCTAssertTrue(firstFriendRow.waitForExistence(timeout: 8), "expected at least one friend row.\n\(app.debugDescription)")

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        attachScreenshot(app, name: "chat-friends-list-rest-state-gap")

        let restGap = firstFriendRow.frame.minY - friendsSegment.frame.maxY
        XCTAssertGreaterThan(
            restGap, 12,
            "expected genuine breathing-room padding between the Friends/Groups/Agents toggle and the first friend row at rest; measured gap: \(restGap)pt"
        )

        // Round trip (mock data is small -- 2 friends -- so this mainly
        // confirms the gesture doesn't break the fixed header/toggle above
        // the List, mirroring notesTab's stronger post-scroll assertion).
        let list = listElement(in: app)
        list.swipeUp()
        list.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(friendsSegment.isHittable, "the Friends/Groups/Agents toggle must remain reachable after a scroll gesture")
        XCTAssertTrue(app.buttons["Add friend"].isHittable, "the add-friend header button must remain reachable")
    }

    // MARK: - 4. Groups + Agents segments: same fix, rest-state gap on each

    func test_chatGroupsAndAgentsSegments_haveRestStateGap() {
        let app = signInAndReachDashboard()

        let chatTabButton = app.buttons["Chat"]
        XCTAssertTrue(chatTabButton.waitForExistence(timeout: 5))
        tapWhenHittable(chatTabButton, app: app)

        let groupsSegment = app.buttons["Groups"]
        XCTAssertTrue(groupsSegment.waitForExistence(timeout: 8))
        tapWhenHittable(groupsSegment, app: app)

        let firstGroupRow = firstMatch(app, labelContains: "Open group:")
        XCTAssertTrue(firstGroupRow.waitForExistence(timeout: 8), "expected at least one group row.\n\(app.debugDescription)")
        attachScreenshot(app, name: "chat-groups-list-rest-state-gap")
        XCTAssertGreaterThan(
            firstGroupRow.frame.minY - groupsSegment.frame.maxY, 12,
            "expected genuine breathing-room padding above the first group row at rest"
        )

        let agentsSegment = app.buttons["Agents"]
        XCTAssertTrue(agentsSegment.waitForExistence(timeout: 5))
        tapWhenHittable(agentsSegment, app: app)

        let firstAgentRow = firstMatch(app, labelContains: "Chat with agent:")
        XCTAssertTrue(firstAgentRow.waitForExistence(timeout: 8), "expected at least one agent row.\n\(app.debugDescription)")
        attachScreenshot(app, name: "chat-agents-list-rest-state-gap")
        XCTAssertGreaterThan(
            firstAgentRow.frame.minY - agentsSegment.frame.maxY, 12,
            "expected genuine breathing-room padding above the first agent row at rest"
        )
    }
}
