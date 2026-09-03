// OnboardingTourScreenshotCaptureUITests.swift — capture tooling for task
// 20260902-onboarding-tour-real-screenshots.
//
// This is NOT a regression/correctness test (that's `OnboardingTourUITests`
// and whatever the testing gate adds for this task) — it is the frontend
// gate's own capture mechanism, the "repeatable capture checklist/script"
// design-notes.md asks for. It drives the real, running app via
// MockDataService's "UI-TESTING" launch argument (same mechanism as
// AgentChatVisualParityScreenshotUITests / NoteDetailScreenshotUITests) to
// each of the 12 real screen states the tour's TourStep.all now maps to, and
// writes each raw, uncropped full-device screenshot to
// /tmp/onboarding-tour-raw/<asset-name>.png for the crop pass described in
// TOUR_SCREENSHOT_CAPTURE.md (same directory next to OnboardingView.swift).
//
// Capture provenance for this run (record here + in the checklist doc, per
// the intake spec's "capture provenance" acceptance criterion):
//   Simulator: "FellowScript-Screenshot", iPhone 17, iOS 26.5 (fresh install,
//   current `main`, MockDataService's UI-TESTING mock account "jacob").
//
// Deliberately one small, independent test method per capture (or tight
// group of captures on the same screen) rather than one long chained
// method: a fresh `signInAndReachDashboard()` per test means a flaky
// interaction in one capture (a long-press context menu, a sheet dismiss)
// can't cascade into silently skipping every capture after it in the same
// run — which is exactly what happened during this capture pass's own
// development (see git history / bounce notes on this task): a single
// chained test lost 6 of 12 screenshots to one stuck system context menu
// three runs in a row before this was split apart.
import XCTest

final class OnboardingTourScreenshotCaptureUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Shared helpers (same patterns as NoteDetailScreenshotUITests /
    // AgentChatVisualParityScreenshotUITests)

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
            XCTAssertTrue(usernameField.waitForExistence(timeout: 8))
            waitHittableThenTap(usernameField)
            usernameField.typeText("jacob")

            let passwordField = app.secureTextFields["Password field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
            waitHittableThenTap(passwordField)
            passwordField.typeText("password")

            let submitButton = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "sign in button")
            ).firstMatch
            XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
            waitHittableThenTap(submitButton)

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

    /// Taps a text-entry element and retries until it actually has keyboard
    /// focus before typing — a bare tap() that fires right as a sheet/keyboard
    /// transition is still settling can register as a hit without actually
    /// focusing the field, which makes typeText() throw ("Neither element nor
    /// any descendant has keyboard focus") rather than silently no-op.
    private func focusAndType(_ element: XCUIElement, _ text: String, app: XCUIApplication, retries: Int = 5) {
        for _ in 0..<retries {
            guard element.exists else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                continue
            }
            if element.isHittable { element.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if app.keyboards.element.exists {
                element.typeText(text)
                return
            }
        }
        // Best-effort fallback — still attempt the type even if the keyboard
        // never registered as present, so the rest of the capture sequence
        // can proceed rather than throwing and aborting the whole run.
        if element.exists { element.typeText(text) }
    }

    /// Dismisses the keyboard via `.dismissesKeyboardOnScrollAndTap()`'s tap
    /// gesture (Theme.swift): a `simultaneousGesture(TapGesture())` on the
    /// screen's root that calls `resignFirstResponder` on any tap, not a
    /// scroll-driven dismiss — a `swipeDown()` on the nearest ScrollView left
    /// the keyboard on screen in this same capture pass (confirmed live via
    /// screenshot), so this taps a coordinate inside the screen's own root
    /// view but in blank background margin (outside every field/button/card)
    /// so the tap only resigns the keyboard without also activating a
    /// control underneath it.
    private func dismissKeyboard(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.3)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Saves both an XCTAttachment (visible in the test report) and a raw PNG
    /// under /tmp/onboarding-tour-raw/ for the crop-and-import pass. `name`
    /// is the final Assets.xcassets imageset name (e.g. "tour-dashboard").
    private func captureRaw(_ app: XCUIApplication, name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4)) // let transitions/animations settle
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let pngData = screenshot.pngRepresentation as Data? {
            let dir = "/tmp/onboarding-tour-raw"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? pngData.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    /// Explicitly navigates the Bible reader to John chapter 1 — don't rely
    /// on BibleViewModel's John-1 default, since `load()` restores whatever
    /// book/chapter was last persisted (DiskCache), which can carry over
    /// from a previous run on this same Simulator. Both captures that need
    /// the real Bible reader (chapter nav, and the John-1:14 highlight,
    /// which depends on MockDataService.mockHighlights' "John-1-14" key)
    /// call this so each is deterministic regardless of prior state.
    private func navigateToJohnChapterOne(_ app: XCUIApplication) {
        let bibleTab = app.buttons["Bible"]
        XCTAssertTrue(bibleTab.waitForExistence(timeout: 5))
        waitHittableThenTap(bibleTab, app: app)
        let navPill = app.buttons["Navigate to book and chapter"]
        guard navPill.waitForExistence(timeout: 8) else { return }
        waitHittableThenTap(navPill, app: app)
        // The book list defaults to whichever testament curBook belongs to
        // (BibleNavDropdown.init) — if a prior run left the reader on an Old
        // Testament book, John won't be in the visible list until New
        // Testament is selected. Tapping it when already active is a no-op.
        let newTestamentToggle = app.buttons["New Testament"]
        if newTestamentToggle.waitForExistence(timeout: 5) {
            waitHittableThenTap(newTestamentToggle, app: app)
        }
        // Book/chapter buttons' accessibilityLabel is the exact name (or
        // "<name>, current <book/chapter>") — exact-match so a CONTAINS
        // predicate doesn't also match "1 John"/"2 John" or "Chapter 10"-19.
        let johnBook = app.buttons["John"]
        let johnBookCurrent = app.buttons["John, current book"]
        if johnBook.waitForExistence(timeout: 5) {
            waitHittableThenTap(johnBook, app: app)
        } else if johnBookCurrent.waitForExistence(timeout: 3) {
            waitHittableThenTap(johnBookCurrent, app: app)
        }
        let chapter1 = app.buttons["Chapter 1"]
        let chapter1Current = app.buttons["Chapter 1, current chapter"]
        if chapter1.waitForExistence(timeout: 5) {
            waitHittableThenTap(chapter1, app: app)
        } else if chapter1Current.waitForExistence(timeout: 3) {
            waitHittableThenTap(chapter1Current, app: app)
        }
    }

    // MARK: - 0. HOME — tour-dashboard

    func test_captureDashboard() {
        let app = signInAndReachDashboard()
        captureRaw(app, name: "tour-dashboard")
    }

    // MARK: - 1. BIBLE (chapter nav) — tour-bible-nav

    func test_captureBibleNav() {
        let app = signInAndReachDashboard()
        navigateToJohnChapterOne(app)
        // vm.curBook.uppercased() (not a .textCase modifier), so the
        // accessibility label really is the all-caps "JOHN".
        XCTAssertTrue(app.staticTexts["JOHN"].waitForExistence(timeout: 8), "expected the Bible reader to land on John 1.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Chapter 1"].waitForExistence(timeout: 5))
        captureRaw(app, name: "tour-bible-nav")
    }

    // MARK: - 2. BIBLE (highlight menu) — tour-highlights

    func test_captureBibleHighlightMenu() {
        let app = signInAndReachDashboard()
        navigateToJohnChapterOne(app)

        // Verse 14 is already highlighted in MockDataService.mockHighlights
        // ("John-1-14"), so long-pressing it and expanding the "Highlight"
        // submenu shows both an existing highlight and the 5-color picker in
        // one populated shot.
        let verse14 = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Verse 14")
        ).firstMatch
        XCTAssertTrue(verse14.waitForExistence(timeout: 8), "expected John 1:14 to be visible.\n\(app.debugDescription)")

        var menuOpened = false
        for attempt in 0..<3 where !menuOpened {
            if attempt > 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
            verse14.press(forDuration: 1.2)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            // Confirm the context menu actually opened (any of its top-level
            // items) before hunting for "Highlight" specifically — press-
            // and-hold can be flaky in Simulator automation.
            menuOpened = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Copy verse")
            ).firstMatch.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(menuOpened, "the verse context menu never opened after 3 long-press attempts.\n\(app.debugDescription)")

        let highlightMenuItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Highlight")
        ).firstMatch
        if highlightMenuItem.waitForExistence(timeout: 5) {
            highlightMenuItem.tap()
            captureRaw(app, name: "tour-highlights")
        }
        // No in-place dismiss attempted here — this native contextMenu is a
        // system-rendered (SpringBoard-hosted) overlay, confirmed live not
        // to reliably respond to an in-app coordinate tap. Since this is the
        // last capture this test method needs, the app is simply left as-is;
        // the next test method starts its own fresh `signInAndReachDashboard()`.
    }

    // MARK: - 3 & 4. NOTES — tour-create-note, tour-group-notes

    func test_captureNotesCreateAndGroupList() {
        let app = signInAndReachDashboard()

        let notesTab = app.buttons["Notes"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 5))
        waitHittableThenTap(notesTab, app: app)

        // 3. Create note — tour-create-note.
        let createNote = app.buttons["Create new note"]
        if createNote.waitForExistence(timeout: 5) {
            waitHittableThenTap(createNote, app: app)
            let titleField = app.textFields["Note title"]
            if titleField.waitForExistence(timeout: 5) {
                focusAndType(titleField, "John 1 — The Logos", app: app)
            }
            let bodyField = app.textViews.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Note body")
            ).firstMatch
            if bodyField.waitForExistence(timeout: 5) {
                focusAndType(bodyField, "John opens with \"In the beginning\" mirroring Genesis. The Logos was both with God and was God.", app: app)
            }
            dismissKeyboard(app)
            captureRaw(app, name: "tour-create-note")

            let cancelChip = app.buttons["Cancel and discard changes"]
            if cancelChip.waitForExistence(timeout: 5) { cancelChip.tap() }
        }

        // 4. Community/group notes — tour-group-notes. Switch to the
        // "Wednesday Night Study" group chip to show community-authored notes.
        if notesTab.waitForExistence(timeout: 5) { waitHittableThenTap(notesTab, app: app) }
        let groupChip = app.buttons["Wednesday Night Study"]
        if groupChip.waitForExistence(timeout: 5) {
            waitHittableThenTap(groupChip, app: app)
            captureRaw(app, name: "tour-group-notes")
        }
    }

    // MARK: - 5 & 6. COMMUNITY (friends) — tour-friend-chat, tour-add-friend

    func test_captureChatFriendsAndAddFriend() {
        let app = signInAndReachDashboard()

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5))
        waitHittableThenTap(chatTab, app: app, timeout: 20)
        XCTAssertTrue(app.buttons["Friends"].waitForExistence(timeout: 10))
        captureRaw(app, name: "tour-friend-chat")

        let addFriendButton = app.buttons["Add friend"]
        if addFriendButton.waitForExistence(timeout: 5) {
            waitHittableThenTap(addFriendButton, app: app)
            let usernameField = app.textFields.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "add as friend")
            ).firstMatch
            if usernameField.waitForExistence(timeout: 5) {
                focusAndType(usernameField, "eli_shepherd", app: app)
                dismissKeyboard(app)
            }
            captureRaw(app, name: "tour-add-friend")
        }
    }

    // MARK: - 7 & 8. COMMUNITY (groups) — tour-create-group, tour-group-session

    func test_captureChatCreateGroupAndSession() {
        let app = signInAndReachDashboard()

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5))
        waitHittableThenTap(chatTab, app: app, timeout: 20)

        let groupsSegment = app.buttons["Groups"]
        XCTAssertTrue(groupsSegment.waitForExistence(timeout: 10))
        waitHittableThenTap(groupsSegment, app: app)

        // 7. Create group — tour-create-group.
        let newGroupButton = app.buttons["New group"]
        if newGroupButton.waitForExistence(timeout: 5) {
            waitHittableThenTap(newGroupButton, app: app)
            let nameField = app.textFields["Group name field"]
            if nameField.waitForExistence(timeout: 5) {
                focusAndType(nameField, "Wednesday Night Study", app: app)
                dismissKeyboard(app)
            }
            for friend in ["Sarah", "Marcus"] {
                let row = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "\(friend). Not selected")
                ).firstMatch
                if row.waitForExistence(timeout: 3) { row.tap() }
            }
            captureRaw(app, name: "tour-create-group")
            let cancel = app.buttons["Cancel"]
            if cancel.waitForExistence(timeout: 5) {
                cancel.tap()
                // Wait for the sheet to actually finish dismissing — tapping
                // the group row immediately after Cancel can land on the
                // still-animating-away sheet instead of the real list row
                // underneath, silently no-opping (confirmed live: this
                // capture landed back on the Groups *list*, not the thread,
                // when this wait was missing).
                let deadline = Date().addingTimeInterval(5)
                while cancel.exists && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }

        // 8. Group session — tour-group-session. Open the "Wednesday Night
        // Study" group thread; MockDataService.fetchSessionsForContact
        // always returns mockSession, so SessionBanner's Join/Details row renders.
        // ContactRow is a plain View with `.onTapGesture` + `.accessibilityLabel`
        // (no Button/isButton trait), so it surfaces to XCUITest as the
        // List's row `.cell`, not `.buttons[...]` — same pattern as the
        // working AgentRow tap in test_captureAgentChat. There's exactly one
        // row in the Groups list, so `app.cells.firstMatch` is unambiguous.
        let groupRow = app.cells.firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 8), "expected the Wednesday Night Study group row.\n\(app.debugDescription)")
        waitHittableThenTap(groupRow, app: app)
        let joinButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Join call")
        ).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: 8), "expected the group thread's SessionBanner Join button.\n\(app.debugDescription)")
        captureRaw(app, name: "tour-group-session")
    }

    // MARK: - 9. AI AGENTS — tour-ai-agent

    func test_captureAgentChat() {
        let app = signInAndReachDashboard()

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5))
        waitHittableThenTap(chatTab, app: app, timeout: 20)

        let agentsSegment = app.buttons["Agents"]
        XCTAssertTrue(agentsSegment.waitForExistence(timeout: 10))
        waitHittableThenTap(agentsSegment, app: app)

        let agentRow = app.cells.firstMatch
        if agentRow.waitForExistence(timeout: 10) {
            waitHittableThenTap(agentRow, app: app)
            _ = app.buttons["Go back"].waitForExistence(timeout: 10)
            captureRaw(app, name: "tour-ai-agent")
        }
    }

    // MARK: - 10 & 11. ACCOUNT / EVENTS — tour-account, tour-heartbeat

    func test_captureAccountAndEvents() {
        let app = signInAndReachDashboard()

        let accountTab = app.buttons["Account"]
        XCTAssertTrue(accountTab.waitForExistence(timeout: 5))
        waitHittableThenTap(accountTab, app: app)
        // sectionLabel applies .textCase(.uppercase) for DISPLAY only — the
        // underlying accessibility label stays mixed-case ("Overview"), so
        // match case-insensitively rather than the all-caps rendered text.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Overview")).firstMatch.waitForExistence(timeout: 10),
            "expected AccountView's real Overview stats section.\n\(app.debugDescription)"
        )
        captureRaw(app, name: "tour-account")

        // Scroll down until the seeded demo heartbeat's Events section is
        // visible (MockDataService.mockHeartbeat). AccountView's eventsSection
        // sits in a plain (non-Lazy) VStack, so its Text already exists in
        // the accessibility tree even while scrolled off-screen — `.exists`
        // doesn't require on-screen visibility. Interacting with it directly
        // lets iOS's own accessibility engine auto-scroll the container into
        // view first (the same mechanism VoiceOver relies on), which is why
        // this taps the row instead of manually dragging the ScrollView —
        // several different manual-drag approaches (raw coordinates at
        // multiple positions, an element-anchored swipeUp(), varied
        // durations/velocities) were all confirmed live to leave the screen
        // completely unscrolled here, seemingly because any drag starting
        // low enough on screen to reach useful distance landed on
        // FloatingTabBar's floating capsule instead of the ScrollView
        // beneath it. Tapping plain text is a harmless no-op once it's
        // actually in view.
        let eventRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Reflect on a Psalm")
        ).firstMatch
        if eventRow.waitForExistence(timeout: 5) {
            eventRow.tap()
            // The auto-scroll-into-view path renders like a VoiceOver focus
            // highlight for a moment (rest of the screen dims, the nav title
            // stays bright) — a second plain tap directly on the now-on-screen
            // row, plus a longer settle, clears that highlight before capture.
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            if eventRow.exists { eventRow.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        captureRaw(app, name: "tour-heartbeat")
    }
}
