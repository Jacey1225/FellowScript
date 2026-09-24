// BibleChapterTapNavigationUITests.swift — real render-and-tap regression
// coverage for task 20260923-bible-tap-nav-not-working.
//
// Task 20260923-bible-tap-chapter-nav shipped left/right tap zones for
// chapter navigation (BibleReaderView.swift's chapterTapGesture /
// chapterTapZoneAccessibilityMarkers, replacing the old swipe DragGesture),
// but its own testing.json recorded that verification relied on
// source-pin/string-matching regression tests plus `xcodebuild build`
// success — a style of check that would pass even with a completely
// non-functional tap mechanism, since it only confirms certain source
// strings/wiring exist, not that a real tap reaches the handler at runtime.
// That is in fact what happened: the feature shipped broken (the original
// `.background(chapterTapZones)` wiring never received touches, because a
// ScrollView's backing UIScrollView claims every touch in its own frame via
// UIKit's front-to-back hit-testing before a sibling laid down *behind* it
// ever sees them).
//
// This file closes that specific verification gap for the tap mechanism's
// core behavior: it drives the real, running app and asserts the chapter
// actually changes on a real synthesized tap, the same way BibleNavDropdownUITests
// (this project's established pattern for BibleReaderView's other
// private-@State interactions) already does for the book/chapter picker.
//
// Coordinate choice: taps land in the chapter-heading block (BibleReaderView's
// `VStack` carrying the book label + "Chapter N" title, `.id("chapterTop")`),
// not on a verse row. That area always renders at the very top of the
// ScrollView's content -- every chapter change scrolls back to it
// (`proxy.scrollTo("chapterTop", anchor: .top)`) -- and, unlike a verse row's
// own tap target (whose real hit-testable area is only its rendered
// characters, not the full transparent row width, since VerseRow's
// background is `Color.clear` and this project's own established convention
// is that `Color.clear` is not hit-testable), is guaranteed to carry no verse
// content at all. That sidesteps any ambiguity about exactly which pixels a
// given verse row's own `.onTapGesture` would claim, while still exercising
// the same `.gesture(chapterTapGesture(width:))` mechanism a tap anywhere
// else in the zone (verse row padding, inter-row gaps, below the last verse)
// goes through.
//
// Update -- task 20260924-bible-verse-tap-select-removal: the paragraph above
// described why a real render-and-tap test *inside* a verse row wasn't
// included -- at the time, SwiftUI's child-gesture-wins-first
// disambiguation meant a tap there was claimed by VerseRow's own
// `.onTapGesture` (tap-to-select) before this gesture ever saw it, and that
// selection had no accessibility trait a UI test could assert on without
// pixel-sampling. That `.onTapGesture` has since been removed entirely
// (it was reported to conflict with tap-to-navigate, i.e. exactly this
// priority ordering), so a tap landing inside a verse row's own rendered
// bounds now reaches this gesture like any other point in the zone, and
// `test_tappingVerseRowInsideZone_realTap_nowAdvancesChapter` below closes
// that verification gap for real -- this is the specific runtime conflict
// this task's fix resolves, so it gets its own render-and-tap coverage
// rather than relying on manual Simulator observation alone.
import XCTest

final class BibleChapterTapNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Shared helpers (mirrors BibleNavDropdownUITests' own copies)

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

    private func bookRow(_ app: XCUIApplication, _ book: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", book)).firstMatch
    }

    private func chapterCell(_ app: XCUIApplication, _ n: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^Chapter \(n)(,.*)?$")).firstMatch
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

    /// Deterministically lands on Genesis 5 via the nav dropdown (mirrors
    /// BibleNavDropdownUITests' own determinism note: BibleViewModel restores
    /// curBook/curChapter from UserDefaults, so a fresh run can't assume any
    /// particular starting position) -- chapter 5 keeps both neighbors
    /// (4 and 6) away from any book boundary, so this test's forward/back
    /// assertions never have to account for BibleViewModel's cross-book
    /// boundary logic (covered separately, unchanged, by
    /// BibleViewModelChapterNavigationBoundaryTests).
    private func establishGenesisFive(_ app: XCUIApplication) {
        let navPill = app.buttons["Navigate to book and chapter"]
        XCTAssertTrue(waitHittableThenTap(navPill, app: app), "expected the nav pill to open BibleNavDropdown")
        XCTAssertTrue(app.buttons["Old Testament"].waitForExistence(timeout: 5))
        waitHittableThenTap(app.buttons["Old Testament"], app: app)

        let genesisRow = bookRow(app, "Genesis")
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 5))
        tapUntil(genesisRow, successElement: app.buttons["Back to book list"], app: app)

        let chapterFive = chapterCell(app, 5)
        XCTAssertTrue(chapterFive.waitForExistence(timeout: 5), "expected a Chapter 5 cell in Genesis's grid")
        tapUntil(chapterFive, successElement: app.staticTexts["Chapter 5"], app: app)

        XCTAssertTrue(app.staticTexts["Chapter 5"].waitForExistence(timeout: 5),
                      "expected the reading heading to show Chapter 5 after selecting it")
    }

    /// Taps the chapter-heading area (top of the ScrollView content, above
    /// any verse row -- see file header) at the given horizontal fraction of
    /// the screen width.
    private func tapHeadingZone(_ app: XCUIApplication, dx: CGFloat) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.20)).tap()
    }

    // MARK: - Core fix: a real tap actually changes the chapter, both directions

    func test_tappingRightZone_realTap_advancesToNextChapter() {
        let app = signInAndReachBible()
        establishGenesisFive(app)

        tapHeadingZone(app, dx: 0.85)

        XCTAssertTrue(app.staticTexts["Chapter 6"].waitForExistence(timeout: 5),
                      "a real tap on the right zone must actually advance the chapter -- this is the exact " +
                      "behavior task 20260923-bible-tap-chapter-nav shipped broken (source-pin tests alone " +
                      "could not catch it)")
    }

    func test_tappingLeftZone_realTap_goesBackToPreviousChapter() {
        let app = signInAndReachBible()
        establishGenesisFive(app)

        tapHeadingZone(app, dx: 0.15)

        XCTAssertTrue(app.staticTexts["Chapter 4"].waitForExistence(timeout: 5),
                      "a real tap on the left zone must actually go back a chapter")
    }

    func test_tappingBothZonesRepeatedly_realTaps_trackForwardAndBackCorrectly() {
        let app = signInAndReachBible()
        establishGenesisFive(app)

        // A short settle pause after each tap (beyond changeChapter's own
        // ~0.3s fade-out/in) before firing the next synthesized tap --
        // otherwise a tap landing mid cross-fade was observed to
        // occasionally land as the ScrollView's content was still
        // reflowing/re-scrolling to "chapterTop" from the previous change,
        // which is a synthesized-input-timing concern specific to firing
        // taps back-to-back in a test, not the underlying tap mechanism
        // itself -- each single-tap direction is already covered
        // independently (and reliably) by the two tests above.
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }

        tapHeadingZone(app, dx: 0.85)
        XCTAssertTrue(app.staticTexts["Chapter 6"].waitForExistence(timeout: 5))
        settle()

        tapHeadingZone(app, dx: 0.85)
        XCTAssertTrue(app.staticTexts["Chapter 7"].waitForExistence(timeout: 5))
        settle()

        tapHeadingZone(app, dx: 0.15)
        XCTAssertTrue(app.staticTexts["Chapter 6"].waitForExistence(timeout: 5))
        settle()

        tapHeadingZone(app, dx: 0.15)
        XCTAssertTrue(app.staticTexts["Chapter 5"].waitForExistence(timeout: 5))
    }

    // MARK: - Task 20260924-bible-verse-tap-select-removal: a real tap ON a verse row's own rendered text now changes chapter

    /// Locates a verse row via its `.accessibilityLabel("Verse \(v.num): ...")`
    /// (set on VerseRow's call site in BibleReaderView.swift) rather than a
    /// hardcoded coordinate, so this test is robust to font-size/layout
    /// differences across devices while still guaranteeing the tap lands
    /// within that row's own rendered frame.
    ///
    /// Live Simulator inspection (this task's own verification) showed
    /// XCUITest surfaces *two* `staticTexts` carrying the same
    /// accessibility label for a given verse -- the verse-number Text's own
    /// narrow frame, and the full-row-width accessibility element VerseRow's
    /// `.accessibilityLabel` produces -- so this picks the widest match
    /// rather than assuming a fixed match order.
    private func verseRow(_ app: XCUIApplication, verse: Int) -> XCUIElement {
        let matches = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verse \(verse):"))
        var widest: XCUIElement?
        var widestWidth: CGFloat = 0
        for i in 0..<matches.count {
            let el = matches.element(boundBy: i)
            if el.frame.width > widestWidth {
                widestWidth = el.frame.width
                widest = el
            }
        }
        return widest ?? matches.firstMatch
    }

    func test_tappingVerseRowInsideZone_realTap_nowAdvancesChapter() {
        // Regression coverage for this task's fix: prior to it, this exact
        // tap (inside the right-hand chapter-tap-zone's horizontal band, but
        // landing on a verse row's own rendered text) was claimed by
        // VerseRow's `.onTapGesture` for verse selection instead of reaching
        // chapterTapGesture -- confirmed via this task's own live Simulator
        // testing that this was the specific conflict reported. With that
        // `.onTapGesture` removed, the same tap must now reach
        // chapterTapGesture like any other point in the zone.
        let app = signInAndReachBible()
        establishGenesisFive(app)

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verse 1:")).firstMatch
                        .waitForExistence(timeout: 5),
                      "expected verse 1's row to be on screen in Genesis 5")
        let row = verseRow(app, verse: 1)

        // dx: 0.85 lands within the right-hand tap zone (> width * 0.7, see
        // chapterTapGesture); using the row's own frame (not raw window
        // coordinates) guarantees this specific tap lands on the row's
        // rendered content, not empty space beside it.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()

        XCTAssertTrue(app.staticTexts["Chapter 6"].waitForExistence(timeout: 5),
                      "a real tap landing on a verse row's own rendered text, inside the right tap zone, must now " +
                      "advance the chapter -- this is the exact tap-to-select-vs-tap-to-navigate conflict task " +
                      "20260924-bible-verse-tap-select-removal fixes")
    }

    func test_tappingVerseRowInsideZone_realTap_nowGoesBackAChapter() {
        let app = signInAndReachBible()
        establishGenesisFive(app)

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verse 1:")).firstMatch
                        .waitForExistence(timeout: 5),
                      "expected verse 1's row to be on screen in Genesis 5")
        let row = verseRow(app, verse: 1)

        // dx: 0.15 lands within the left-hand tap zone (< width * 0.3).
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()

        XCTAssertTrue(app.staticTexts["Chapter 4"].waitForExistence(timeout: 5),
                      "a real tap landing on a verse row's own rendered text, inside the left tap zone, must now " +
                      "go back a chapter")
    }

    // MARK: - Nav dropdown priority: tap-outside-to-dismiss must not also change chapter

    func test_withNavDropdownOpen_tapOutside_onlyDismissesDropdown_doesNotChangeChapterUnderneath() {
        let app = signInAndReachBible()
        establishGenesisFive(app)

        let navPill = app.buttons["Navigate to book and chapter"]
        XCTAssertTrue(waitHittableThenTap(navPill, app: app), "expected the nav pill to open BibleNavDropdown")
        XCTAssertTrue(app.buttons["Old Testament"].waitForExistence(timeout: 5), "expected the dropdown panel to be open")

        // Tap near the bottom of the screen, well below the drill-down
        // panel's own content, so this lands on TapOutsideDismissCatcher
        // rather than on the panel itself.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.92)).tap()

        XCTAssertFalse(app.buttons["Old Testament"].waitForExistence(timeout: 3),
                       "expected the tap outside the panel to close BibleNavDropdown")
        XCTAssertTrue(app.staticTexts["Chapter 5"].waitForExistence(timeout: 3),
                      "the dismiss-tap must not also fall through and trigger a chapter change underneath the dropdown")
    }
}
