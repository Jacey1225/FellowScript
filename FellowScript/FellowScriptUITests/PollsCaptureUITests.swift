// PollsCaptureUITests.swift -- screenshots of the announcement poll card and builder against the
// DEBUG-only local preview (UI-TESTING-POLLS-PREVIEW). No server, no account.

import XCTest

final class PollsCaptureUITests: XCTestCase {
    private let outDir = ProcessInfo.processInfo.environment["FORMS_SHOT_DIR"] ?? "/private/tmp/claude-501/forms-shots/polls"

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let s = app.screenshot()
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func launch(_ extra: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING", "UI-TESTING-POLLS-PREVIEW", extra]
        app.terminate(); app.launch()
        return app
    }

    func test_voteFlow() {
        let app = launch("polls-detail")
        let friday = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Friday")).firstMatch
        XCTAssertTrue(friday.waitForExistence(timeout: 10))
        shot(app, "poll-01-before-vote")
        friday.tap()
        shot(app, "poll-02-after-vote")
        let clear = app.buttons["Clear my vote"]
        XCTAssertTrue(clear.waitForExistence(timeout: 4), "Clear my vote appears after voting")
        let tuesday = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tuesday")).firstMatch
        tuesday.tap()
        shot(app, "poll-03-changed-vote")
    }

    func test_closedPoll() {
        let app = launch("polls-closed")
        XCTAssertTrue(app.staticTexts["Study night schedule"].waitForExistence(timeout: 10))
        shot(app, "poll-04-closed")
    }

    func test_builder() {
        let app = launch("polls-form")
        let extras = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add extras")).firstMatch
        XCTAssertTrue(extras.waitForExistence(timeout: 10))
        extras.tap()
        let poll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Poll")).firstMatch
        XCTAssertTrue(poll.waitForExistence(timeout: 5))
        poll.tap()
        shot(app, "poll-05-builder")
        app.swipeUp()
        shot(app, "poll-06-builder-lower")
    }
}
