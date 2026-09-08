// ChatStandaloneAttachmentUITests.swift — on-device regression coverage for
// task 20260908-chat-userid-exposure-standalone-media, Bug 2 (standalone
// photo/video sending). A prior static-only code review of ChatThreadView's
// `canSend`/`sendMessage()` concluded the composer already supported sending
// a staged photo/video with no text, since the boolean logic reads correct.
// That conclusion was wrong: a real simulator run (this file) proved the
// send button stays visibly disabled after a photo finishes uploading, with
// no text typed, exactly matching the user's real report.
//
// Root cause (confirmed by reading StagedAttachment/ChatThreadView together,
// then proven live here): `StagedAttachment` is a `class: ObservableObject`
// with `@Published var uploadState`, but ChatThreadView holds it via a plain
// `@State private var stagedAttachment: StagedAttachment?` — @State only
// re-renders a view when the *reference itself* is reassigned, not when an
// `@Published` property on the referenced object changes. Only
// `StagedAttachmentChipView` (which takes the attachment via
// `@ObservedObject`) is actually subscribed to `uploadState` changes, so its
// own spinner/retry UI updates correctly — but nothing forces
// `ChatThreadView.composer`'s sibling `canSend`/Send-button to re-evaluate
// once `startUpload`'s async `Task` flips `attachment.uploadState` from
// `.uploading` to `.uploaded(...)` off the initial synchronous render pass.
// The Send button is left stuck at whatever `canSend` evaluated to at the
// moment the attachment was staged (disabled, since image/video start in
// `.uploading`) until some *unrelated* state change (typing into the text
// field, which reassigns the `text` @State) forces ChatThreadView's body to
// recompute and pick up the now-current `uploadState`. That's exactly why
// typing text "unblocks" sending a photo/video.
//
// Uses the same UI-TESTING -> MockDataService seam as AccountUITests.swift
// (jacob/password), reaching a real DM thread ("Chat with Sarah") and
// driving the real PHPickerViewController via a photo pre-seeded into the
// simulator's Photos library (`xcrun simctl addmedia`).
import XCTest

final class ChatStandaloneAttachmentUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @discardableResult
    private func waitHittableThenTap(_ element: XCUIElement, timeout: TimeInterval = 10, scrollContainer app: XCUIApplication? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if element.exists && element.isHittable {
                    element.tap()
                    return true
                }
            }
            // Row exists but is off-screen (e.g. below the fold in the chat
            // list) rather than genuinely un-hittable -- nudge it into view,
            // matching the working idiom in NotesMessagesListScrollBlurUITests.
            if element.exists, let app {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        // Last resort: the element exists and is visually on-screen (has a
        // real frame) but XCUITest's isHittable heuristic never flips true --
        // this happens for a StaticText matched via `.any` whose parent List
        // row/cell is the actual interactive element. A raw coordinate tap
        // bypasses the hittability check and hits whatever is really at that
        // point on screen (the row), same as a real finger tap would.
        if element.exists, element.frame.width > 0, element.frame.height > 0 {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }
        return false
    }

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists {
            for label in ["Allow", "OK", "Allow While Using App", "Allow Full Access", "Select Photos..."] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
        }
        let notNow = app.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
    }

    /// Mirrors AccountUITests.signInAndReachAccount, routed to the Chat tab
    /// -> "Chat with Sarah" DM thread instead of Account.
    private func signInAndReachChatThreadWithSarah() -> XCUIApplication {
        let app = XCUIApplication()

        addUIInterruptionMonitor(withDescription: "System permission alerts") { alert in
            for label in ["Allow", "OK", "Allow While Using App", "Allow Full Access", "Select Photos..."] {
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
            XCTAssertTrue(waitHittableThenTap(usernameField))
            usernameField.typeText("jacob")

            let passwordField = app.secureTextFields["Password field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
            XCTAssertTrue(waitHittableThenTap(passwordField))
            passwordField.typeText("password")

            let submitButton = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "sign in button")
            ).firstMatch
            XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
            XCTAssertTrue(waitHittableThenTap(submitButton))

            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                dismissSystemAlertIfPresent(app)
                if app.buttons["Home"].exists { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }

        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 15), "expected Dashboard tab bar after sign-in")

        let chatTab = app.buttons["Chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5), "FloatingTabBar's Chat destination")
        var chatTabTapped = false
        let chatTabDeadline = Date().addingTimeInterval(20)
        while Date() < chatTabDeadline && !chatTabTapped {
            dismissSystemAlertIfPresent(app)
            if waitHittableThenTap(chatTab, timeout: 3) {
                chatTabTapped = true
            }
        }
        XCTAssertTrue(chatTabTapped, "expected the Chat tab to become hittable\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let target = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Chat with Sarah")
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 15), "expected \"Chat with Sarah\" row on the Chat tab\n\(app.debugDescription)")
        XCTAssertTrue(waitHittableThenTap(target, scrollContainer: app), "expected \"Chat with Sarah\" row to be tappable")

        let composerField = app.textViews["Message input field"].exists
            ? app.textViews["Message input field"] : app.textFields["Message input field"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 15), "expected ChatThreadView's composer to load\n\(app.debugDescription)")

        return app
    }

    /// Reproduces + proves the fix for Bug 2: stage a real photo via the real
    /// PHPickerViewController with NO text typed, then assert the Send
    /// button becomes enabled once the upload completes -- without ever
    /// touching the text field. Before the fix, this hangs/fails (Send stays
    /// disabled); after the fix, it passes.
    func test_standalonePhotoAttachment_noTextTyped_sendButtonBecomesEnabled() {
        let app = signInAndReachChatThreadWithSarah()

        let attachButton = app.buttons["Attach a photo, video, file, or GIF"]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitHittableThenTap(attachButton))

        let photoVideoPill = app.buttons["Photo & Video"]
        XCTAssertTrue(photoVideoPill.waitForExistence(timeout: 5))
        XCTAssertTrue(waitHittableThenTap(photoVideoPill))

        // System PHPickerViewController -- pre-seeded photo via
        // `xcrun simctl addmedia` (see task notes). Grant full-library
        // access if prompted, then tap the first asset cell.
        dismissSystemAlertIfPresent(app)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        dismissSystemAlertIfPresent(app)

        let firstCell = app.collectionViews.cells.element(boundBy: 0).exists
            ? app.collectionViews.cells.element(boundBy: 0)
            : app.scrollViews.images.firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 15), "expected the seeded photo to appear in PHPickerViewController\n\(app.debugDescription)")
        XCTAssertTrue(waitHittableThenTap(firstCell), "expected the first photo cell to be tappable")

        // Confirm the selection (PHPicker's top-right "Add" control).
        let addButton = app.buttons["Add"]
        if addButton.waitForExistence(timeout: 5) {
            waitHittableThenTap(addButton)
        }

        // Back in the composer: the staged-attachment chip's remove control
        // proves an attachment actually got staged.
        let removeAttachment = app.buttons["Remove attachment"]
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 15), "expected the staged-attachment chip to appear after picking a photo\n\(app.debugDescription)")

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))

        // Give the mock upload's async Task a real chance to complete
        // (task-hop back to MainActor, not an artificial delay) --
        // deliberately NOT typing into the text field, since that's the
        // unrelated state change that was masking this bug.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !sendButton.isEnabled {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "composer-after-photo-staged-no-text-typed"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(sendButton.isEnabled,
                      "Send must become enabled once the staged photo finishes uploading, even with no text typed -- " +
                      "if this fails, ChatThreadView's composer never re-renders after StagedAttachment.uploadState " +
                      "changes off-screen (a @State-holding-an-ObservableObject-class invalidation gap).\n\(app.debugDescription)")

        waitHittableThenTap(sendButton)

        // Attachment-only send succeeded: the chip clears and the composer
        // resets, exactly as sendMessage() does on a normal send.
        XCTAssertFalse(app.buttons["Remove attachment"].waitForExistence(timeout: 3),
                       "expected the staged-attachment chip to clear after a successful standalone send")
    }
}
