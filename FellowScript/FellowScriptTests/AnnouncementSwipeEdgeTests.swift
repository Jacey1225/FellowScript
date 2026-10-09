// AnnouncementSwipeEdgeTests.swift — testing gate for task
// 20261009-announcements-swipe-trailing. Source-pins that the announcement Delete
// swipe action sits on the trailing edge (swipe left), matching Notes and threads,
// and that the VoiceOver Delete/Edit actions remain.

import XCTest

final class AnnouncementSwipeEdgeTests: XCTestCase {

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/Chat/GroupAnnouncementsView.swift"), encoding: .utf8)
    }

    func testDeleteSwipeActionIsTrailingEdge() throws {
        let src = try source()
        XCTAssertTrue(src.contains(".swipeActions(edge: .trailing"), "Delete swipe must be trailing (swipe left)")
        XCTAssertFalse(src.contains("edge: .leading"), "No leading-edge swipe on announcements")
        XCTAssertEqual(src.components(separatedBy: ".swipeActions(").count - 1, 1)
    }

    func testSwipeStillGatedAndAccessibleAlternativesRemain() throws {
        let src = try source()
        let swipe = try XCTUnwrap(src.range(of: ".swipeActions(edge: .trailing")).lowerBound
        let tail = String(src[swipe...])
        XCTAssertTrue(tail.prefix(400).contains("item.can_edit"))
        XCTAssertTrue(tail.prefix(400).contains("vm.startDelete(item)"))
        XCTAssertTrue(src.contains(".accessibilityAction(named: \"Delete\")"))
        XCTAssertTrue(src.contains(".accessibilityAction(named: \"Edit\")"))
    }
}
