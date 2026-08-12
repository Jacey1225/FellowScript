// BibleNavDropdownUITests.swift — end-to-end regression coverage for the
// Concept B single-column drill-down rewrite of BibleNavDropdown
// (Bible/BibleReaderView.swift:567-823, task
// 20260811-bible-nav-picker-implementation).
//
// BibleNavDropdown keeps its Step-1/Step-2 drill-down as private @State
// (`step`, `activeTestament`) with no external binding and no ViewInspector
// dependency in this project (same shape as NoteEditorView, see
// NoteEditorUITests.swift's header note) — a from-scratch diagnostic
// confirmed that a bare, un-hosted ViewInspector `.tap()` on a Button whose
// action closure mutates only *internal* `@State` does not persist across
// separate `.inspect()` calls in this project's ViewInspector version
// (0.10.3) without a live SwiftUI render pass (`ViewHosting`), whereas the
// existing ChipToggle/PillButton/SegmentedDurationControl ViewInspector
// tests all drive an *external* `@Binding` instead, sidestepping that
// limitation entirely. BibleNavDropdown exposes no such binding, so these
// tests instead drive the real, running app through the same accessibility
// labels VoiceOver uses (per BibleReaderView.swift's own
// `.accessibilityLabel(...)` calls on every interactive element), matching
// this project's established NoteEditorUITests/AccountUITests convention
// for private-@State views.
//
// The app defaults AppState to MockDataService (see FellowScriptApp.swift's
// "UI-TESTING" launch argument), which accepts username "jacob" / password
// "password", so these tests run fully offline.
//
// Determinism note: BibleViewModel restores `curBook`/`curChapter` from
// UserDefaults ("fs_bible_pos") on init, which is NOT reset by relaunching
// the app between tests (only MockDataService's in-memory data resets per
// process). Rather than assume a particular starting book/chapter, the
// selection-round-trip test below first *drills into and selects* a known
// book/chapter (Genesis 1) itself, then reopens the picker to assert the
// current-book/current-chapter highlight against that just-established,
// fully deterministic position — never against whatever position an
// earlier test run happened to leave behind.
//
// Covers the intake spec's behavior-preservation checklist (design-notes.md
// §7) end-to-end: drill-down navigation (book tap -> Step 2, no onSelect),
// Back (-> Step 1, panel stays open), current-book highlight,
// current-chapter highlight (only after drilling into the current book),
// OT/NT pill scroll-jump grouping, and onSelect(book, chapter) -> close panel.
//
// Follow-up (task 20260811-bible-nav-toggle-close): the panel's in-panel "x"
// close control ("Close passage picker") was removed — the nav-bar pill
// button ("Navigate to book and chapter") now toggles the panel open/closed,
// so every test below that used to tap the "x" instead re-taps that pill.

import XCTest

final class BibleNavDropdownUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tap helpers (mirrors AccountUITests/NoteEditorUITests' settle-then-tap pattern)

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

    /// Taps `tapTarget` and waits for `successElement` to appear, retrying
    /// the tap a few times if it doesn't (mirrors AccountUITests.tapUntil) —
    /// an occasional synthesized tap right after a scroll-jump animation
    /// (e.g. the Old Testament pill settling before a book row is tapped)
    /// can get silently absorbed without the underlying SwiftUI action
    /// firing. Re-tapping is harmless since book-row/back taps are
    /// idempotent no-ops once already applied.
    private func tapUntil(_ tapTarget: XCUIElement, successElement: XCUIElement, app: XCUIApplication,
                          attempts: Int = 4, perAttemptTimeout: TimeInterval = 4) {
        for _ in 0..<attempts {
            dismissSystemAlertIfPresent(app)
            if tapTarget.exists && tapTarget.isHittable {
                tapTarget.tap()
            }
            if successElement.waitForExistence(timeout: perAttemptTimeout) {
                return
            }
        }
        XCTFail("expected \(successElement) to appear after tapping \(tapTarget)\n\(app.debugDescription)")
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
        let notNow = app.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
    }

    /// A book row's accessibility label is either the bare book name or
    /// "<book>, current book" (BibleNavDropdown.bookRow) — match either.
    private func bookRow(_ app: XCUIApplication, _ book: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", book)).firstMatch
    }

    /// A chapter cell's accessibility label is either "Chapter <n>" or
    /// "Chapter <n>, current chapter" (BibleNavDropdown.chapterGridStep) —
    /// match either. A prior test run may leave a given chapter as curBook/
    /// curChapter via UserDefaults (see header note), so plain exact-string
    /// lookups like `app.buttons["Chapter 1"]` are not reliable; anchor the
    /// regex so "Chapter 1" never accidentally matches "Chapter 10"-"Chapter 19".
    private func chapterCell(_ app: XCUIApplication, _ n: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^Chapter \(n)(,.*)?$")).firstMatch
    }

    // MARK: - Shared flow: onboarding + sign-in, then land on the Bible tab
    // (mirrors NoteEditorUITests.signInAndReachDashboard / AccountUITests.signInAndReachAccount).

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

    /// Opens the picker and (unless `jump` is false) taps the Old Testament
    /// pill segment so the book list's `LazyVStack` deterministically
    /// renders from the top (Genesis) regardless of wherever
    /// `proxy.scrollTo(curBook, ...)` happened to land on open — `LazyVStack`
    /// only instantiates rows near the current scroll position, so a book
    /// row or the "Old Testament" section label can otherwise be absent from
    /// the accessibility tree entirely (not just off-screen) if curBook was
    /// left somewhere else by a previous UserDefaults-persisted position
    /// (see the header note on determinism).
    @discardableResult
    private func openPicker(_ app: XCUIApplication, jumpToOldTestament jump: Bool = true) -> Bool {
        let navPill = app.buttons["Navigate to book and chapter"]
        XCTAssertTrue(waitHittableThenTap(navPill, app: app), "expected the nav pill to open BibleNavDropdown")
        XCTAssertTrue(app.staticTexts["Select Passage"].waitForExistence(timeout: 5),
                      "expected Step 1's 'Select Passage' header to appear")
        guard jump else { return true }
        return waitHittableThenTap(app.buttons["Old Testament"], app: app)
    }

    // MARK: - Step 1: book list

    func test_openingPicker_showsBookListStepWithOTNTPillAndSections() {
        let app = signInAndReachBible()
        XCTAssertTrue(openPicker(app), "expected the Old Testament pill to jump the list to the top")

        XCTAssertTrue(app.buttons["Old Testament"].exists, "expected the OT/NT pill's Old Testament segment")
        XCTAssertTrue(app.buttons["New Testament"].exists, "expected the OT/NT pill's New Testament segment")
        XCTAssertTrue(app.staticTexts["Old Testament"].waitForExistence(timeout: 5),
                      "expected the 'Old Testament' section label above the book list")
        XCTAssertTrue(bookRow(app, "Genesis").waitForExistence(timeout: 5),
                      "expected Genesis (first Old Testament book) after the jump")

        app.buttons["Navigate to book and chapter"].tap()
    }

    func test_newTestamentPill_scrollJumpsToNewTestamentBooksWithoutFiltering() {
        let app = signInAndReachBible()
        openPicker(app)

        XCTAssertTrue(waitHittableThenTap(app.buttons["New Testament"], app: app))
        // Jump lands near Matthew (first NT book) — a scroll-jump, not a
        // filter, so Old Testament books must still exist in the tree too.
        XCTAssertTrue(bookRow(app, "Matthew").waitForExistence(timeout: 5),
                      "expected the New Testament pill to scroll-jump to Matthew")

        app.buttons["Navigate to book and chapter"].tap()
    }

    // MARK: - Drill-down: Step 1 -> Step 2 -> Back (no premature close/select)

    func test_tappingABookRow_advancesToChapterGrid_andBackReturnsToBookList_withoutClosingPanel() {
        let app = signInAndReachBible()
        openPicker(app)

        // Genesis is the Old Testament pill's scroll-jump anchor (first OT
        // book, `anchor: .top`) — always fully within the panel's visible
        // viewport right after the jump, unlike a book several rows further
        // down (observed empirically to be an intermittently-clipped/
        // not-reliably-hittable target right at the 430pt panel's edge).
        let genesisRow = bookRow(app, "Genesis")
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 5))
        tapUntil(genesisRow, successElement: app.buttons["Back to book list"], app: app)

        // Step 2: header replaces "Select Passage" with Back + book name;
        // tapping the book row alone must not have selected/closed anything.
        XCTAssertTrue(app.buttons["Back to book list"].exists,
                      "expected Step 2's Back control after tapping a book row")
        XCTAssertFalse(app.staticTexts["Select Passage"].exists,
                        "Step 2 must replace the Step 1 header title")
        XCTAssertTrue(chapterCell(app, 1).waitForExistence(timeout: 5),
                      "expected Genesis's chapter grid to render")

        // Back returns to Step 1 without closing the panel.
        tapUntil(app.buttons["Back to book list"], successElement: app.staticTexts["Select Passage"], app: app)
        XCTAssertTrue(app.staticTexts["Select Passage"].exists,
                      "Back must return to Step 1, not close the panel")
        XCTAssertTrue(app.buttons["Old Testament"].exists)

        app.buttons["Navigate to book and chapter"].tap()
    }

    // MARK: - Chapter selection -> onSelect -> close; reopening shows current-book/current-chapter highlight

    func test_tappingAChapterCell_selectsAndClosesPanel_thenReopeningHighlightsCurrentBookAndChapter() {
        let app = signInAndReachBible()
        openPicker(app)

        // Drill into Genesis and select chapter 1 — this deterministically
        // establishes curBook/curChapter regardless of whatever position a
        // prior test run left in UserDefaults (see header note).
        let genesisRow = bookRow(app, "Genesis")
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 5))
        tapUntil(genesisRow, successElement: app.buttons["Back to book list"], app: app)

        let chapterOne = chapterCell(app, 1)
        XCTAssertTrue(chapterOne.waitForExistence(timeout: 5), "expected a Chapter 1 cell in Genesis's grid")
        tapUntil(chapterOne, successElement: app.buttons["Navigate to book and chapter"], app: app)

        // onSelect -> the call site sets showNavSheet = false: the panel
        // closes and the nav pill becomes reachable again.
        XCTAssertTrue(app.buttons["Navigate to book and chapter"].exists,
                      "expected the panel to close after selecting a chapter")
        XCTAssertFalse(app.staticTexts["Select Passage"].exists)

        // Reopen: Genesis must now show the current-book highlight.
        openPicker(app)
        let currentGenesisRow = app.buttons["Genesis, current book"]
        XCTAssertTrue(currentGenesisRow.waitForExistence(timeout: 5),
                      "expected Genesis to carry the current-book accessibility label after selecting it")

        // Drilling into Genesis must show chapter 1 as the current chapter.
        tapUntil(currentGenesisRow, successElement: app.buttons["Chapter 1, current chapter"], app: app)
        XCTAssertTrue(app.buttons["Chapter 1, current chapter"].exists,
                      "expected chapter 1 to carry the current-chapter accessibility label")

        app.buttons["Navigate to book and chapter"].tap()
    }

    // MARK: - Nav pill toggle-close present/functional on both steps

    func test_navPillToggle_dismissesPickerFromBookListStep() {
        let app = signInAndReachBible()
        openPicker(app)

        waitHittableThenTap(app.buttons["Navigate to book and chapter"], app: app)
        XCTAssertTrue(app.buttons["Navigate to book and chapter"].waitForExistence(timeout: 5),
                      "expected the panel to close and the nav pill to remain reachable")
        XCTAssertFalse(app.staticTexts["Select Passage"].exists)
    }

    func test_navPillToggle_dismissesPickerFromChapterGridStep() {
        let app = signInAndReachBible()
        openPicker(app)

        let genesisRow = bookRow(app, "Genesis")
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 5))
        tapUntil(genesisRow, successElement: app.buttons["Back to book list"], app: app)

        waitHittableThenTap(app.buttons["Navigate to book and chapter"], app: app)
        XCTAssertFalse(app.buttons["Back to book list"].waitForExistence(timeout: 3),
                        "expected the pill toggle to close the picker from Step 2 too")
        XCTAssertTrue(app.buttons["Navigate to book and chapter"].exists,
                      "expected the nav pill to still be reachable after closing")
    }
}
