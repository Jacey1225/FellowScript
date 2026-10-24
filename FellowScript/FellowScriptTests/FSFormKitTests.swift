// FSFormKitTests.swift
// Forms restyle (task 20261023-forms-restyle, step 2): coverage for the shared
// FSForm* kit. Logic helpers are tested directly; views are smoke-rendered
// through ViewInspector so a broken initializer or missing label fails here.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class FSFormKitTests: XCTestCase {

    func testTypedConfirmMatchesIgnoresCaseAndWhitespace() {
        XCTAssertTrue(fsTypedConfirmMatches("  Jacey ", required: "jacey"))
        XCTAssertFalse(fsTypedConfirmMatches("jace", required: "jacey"))
        XCTAssertFalse(fsTypedConfirmMatches("", required: "jacey"))
    }

    func testFormCardRendersHeadingAndEyebrow() throws {
        let view = FSFormCard(eyebrow: "Step", title: "Message") { Text("body") }
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("STEP"))
        XCTAssertTrue(texts.contains("Message"))
        XCTAssertTrue(texts.contains("body"))
    }

    func testToggleRowShowsTitleAndHelper() throws {
        var on = false
        let view = FSToggleRow(title: "Mute", helper: "Silence alerts", isOn: Binding(get: { on }, set: { on = $0 }))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Mute"))
        XCTAssertTrue(texts.contains("Silence alerts"))
    }

    func testPinnedActionBarShowsPrimaryAndSecondary() throws {
        let view = FSPinnedActionBar(secondaryTitle: "Back", primaryTitle: "Next", onPrimary: {})
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Back"))
        XCTAssertTrue(texts.contains("Next"))
    }

    /// Option B, always one row: flush bar, secondary hugs left, primary fills, never stacks.
    func testPinnedActionBarSourcePinsOneRowOptionB() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Shared/Forms/FSPinnedActionBar.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(src.contains("Theme.navBg"), "bar must be flush with the form background")
        XCTAssertFalse(src.contains("opacity(0.14)"), "no hairline")
        XCTAssertFalse(src.contains("VStack(spacing"), "the bar never stacks")
        XCTAssertFalse(src.contains("keyboardWillShowNotification"), "same row with the keyboard up")
        XCTAssertTrue(src.contains("HStack(spacing: 12)"))
        XCTAssertTrue(src.contains("minWidth: 92, minHeight: 54"))
    }

    func testErrorSummaryPluralizesHeading() throws {
        let one = FSErrorSummaryCard(fields: [("t", "Title")]) { _ in }
        let two = FSErrorSummaryCard(fields: [("t", "Title"), ("m", "Message")]) { _ in }
        XCTAssertTrue(try one.inspect().findAll(ViewType.Text.self).map { try $0.string() }.contains("1 thing needs attention"))
        XCTAssertTrue(try two.inspect().findAll(ViewType.Text.self).map { try $0.string() }.contains("2 things need attention"))
    }

    func testFormTokensUseSpecValues() {
        XCTAssertEqual(Theme.formFieldHeight, 48)
        XCTAssertEqual(Theme.formCardRadius, 20)
    }
}
