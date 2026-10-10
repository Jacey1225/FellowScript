// AnnouncementSwipeDismissTests.swift — source pins for task
// 20261009-announcement-swipe-dismiss: the X button on the chat announcement
// widget card was replaced by a swipe-left gesture plus a VoiceOver action.

import XCTest
@testable import FellowScript

final class AnnouncementSwipeDismissTests: XCTestCase {

    private func widgetSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/Chat/GroupAnnouncementWidgetView.swift"), encoding: .utf8)
    }

    func testNoXmarkDismissButtonRemains() throws {
        let src = try widgetSource()
        XCTAssertFalse(src.contains("xmark"), "the X icon was removed from the widget card")
        XCTAssertFalse(src.contains(".topTrailing"), "no corner overlay affordance replaces the X")
        XCTAssertFalse(src.contains("ZStack"), "the ZStack that hosted the X overlay is gone")
    }

    func testVoiceOverDismissActionPresentAndAnnounces() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains(".accessibilityAction(named: \"Dismiss announcement\") { dismissCard() }"))
        let fn = try XCTUnwrap(src.range(of: "private func dismissCard()")).lowerBound
        let tail = String(src[fn...])
        XCTAssertTrue(tail.prefix(400).contains("vm.dismiss()"))
        XCTAssertTrue(tail.prefix(400).contains("Announcement dismissed"))
    }

    func testSwipeAttachedSimultaneouslySoTapAndScrollSurvive() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains(".simultaneousGesture(swipeToDismiss)"))
        XCTAssertTrue(src.contains("DragGesture(minimumDistance: 16)"))
        XCTAssertTrue(src.contains("Button { viewing = item }"), "tap-to-open Button must remain")
    }

    func testReduceMotionGuardsDragFollowAndAnimation() throws {
        let src = try widgetSource()
        let g = try XCTUnwrap(src.range(of: "private var swipeToDismiss")).lowerBound
        let changed = try XCTUnwrap(src.range(of: ".onChanged", range: g..<src.endIndex)).lowerBound
        let ended = try XCTUnwrap(src.range(of: ".onEnded", range: g..<src.endIndex)).lowerBound
        XCTAssertTrue(src[changed..<ended].contains("!reduceMotion"), "drag follow must be skipped under Reduce Motion")
        XCTAssertTrue(src[ended...].contains("withMotionAwareAnimation(.easeIn"))
        XCTAssertTrue(src[ended...].contains("reduceMotion: reduceMotion"))
    }

    func testLeftwardOnlyCommitWithThresholds() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains("commitDistance: CGFloat = 96"))
        XCTAssertTrue(src.contains("commitPredicted: CGFloat = 220"))
        XCTAssertTrue(src.contains("t.width < 0"), "only leftward drags may dismiss")
        XCTAssertTrue(src.contains("t.width <= -Self.commitDistance"))
        XCTAssertTrue(src.contains("predictedEndTranslation.width <= -Self.commitPredicted"))
        XCTAssertTrue(src.contains("abs(t.width) > abs(t.height) * 1.5"), "horizontal-dominance check")
    }

    func testDragOffsetResetsWhenAnnouncementChanges() throws {
        let src = try widgetSource()
        XCTAssertTrue(src.contains(".onChange(of: vm.visibleItem?.id) { _, _ in dragX = 0 }"))
    }
}
