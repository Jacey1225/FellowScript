// ChatBottomPinTests.swift — task 20261013-ios-chat-initial-scroll-bottom.
// Unit tests for the pure bottom-pin state machine and source guards for its wiring.
import XCTest
import CoreGraphics
@testable import FellowScript

final class ChatBottomPinTests: XCTestCase {

    private func m(_ content: CGFloat, _ container: CGFloat = 800, _ dist: CGFloat = 0) -> ChatScrollMetrics {
        ChatScrollMetrics(contentHeight: content, containerHeight: container, distanceFromBottom: dist)
    }

    func test_initialState_isPinned_andOlderLoadBlocked() {
        let pin = ChatBottomPin()
        XCTAssertTrue(pin.isPinned)
        XCTAssertFalse(pin.allowsOlderPageLoad)
    }

    func test_olderLoad_blockedUntilLoadFinishedAndBottomEstablished() {
        var pin = ChatBottomPin()
        pin.markBottomEstablished()
        XCTAssertFalse(pin.allowsOlderPageLoad, "cannot establish before load finishes")
        pin.loadDidFinish()
        XCTAssertFalse(pin.allowsOlderPageLoad, "loaded but bottom not yet established")
        pin.markBottomEstablished()
        XCTAssertTrue(pin.allowsOlderPageLoad)
    }

    func test_pinned_contentGrowth_repins() {
        // The core bug: rows realize at real heights after first scroll.
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        let a = pin.scrollGeometryChanged(old: m(2000), new: m(2600, 800, 600), userDriven: false)
        XCTAssertEqual(a, .repin)
    }

    func test_pinned_containerChange_keyboard_repins() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        let a = pin.scrollGeometryChanged(old: m(2000, 800), new: m(2000, 500, 300), userDriven: false)
        XCTAssertEqual(a, .repin)
    }

    func test_pinned_alreadyAtBottom_noRepin() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        XCTAssertEqual(pin.scrollGeometryChanged(old: m(2000), new: m(2100, 800, 1), userDriven: false), .none)
    }

    func test_pinned_noSizeChange_noRepin() {
        var pin = ChatBottomPin()
        XCTAssertEqual(pin.scrollGeometryChanged(old: m(2000, 800, 0), new: m(2000, 800, 50), userDriven: false), .none)
    }

    func test_userDragAway_releases_andNeverRepinned() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        XCTAssertEqual(pin.scrollGeometryChanged(old: m(2000), new: m(2000, 800, 300), userDriven: true), .none)
        XCTAssertFalse(pin.isPinned)
        // Content grows while released: user must not be yanked back.
        XCTAssertEqual(pin.scrollGeometryChanged(old: m(2000, 800, 300), new: m(2500, 800, 800), userDriven: false), .none)
        XCTAssertFalse(pin.isPinned)
    }

    func test_smallUserDrag_withinReleaseDistance_staysPinned() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        _ = pin.scrollGeometryChanged(old: m(2000), new: m(2000, 800, 40), userDriven: true)
        XCTAssertTrue(pin.isPinned)
    }

    func test_released_reattachesWhenUserReturnsToBottom() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        _ = pin.scrollGeometryChanged(old: m(2000), new: m(2000, 800, 300), userDriven: true)
        _ = pin.scrollGeometryChanged(old: m(2000, 800, 300), new: m(2000, 800, 10), userDriven: true)
        XCTAssertTrue(pin.isPinned)
    }

    func test_released_reattachesOnProgrammaticArrival_jumpToLatest() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        _ = pin.scrollGeometryChanged(old: m(2000), new: m(2000, 800, 300), userDriven: true)
        XCTAssertEqual(pin.scrollGeometryChanged(old: m(2000, 800, 300), new: m(2000, 800, 0), userDriven: false), .none)
        XCTAssertTrue(pin.isPinned)
    }

    func test_released_olderLoadAllowed_evenIfBottomNeverEstablished() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        _ = pin.scrollGeometryChanged(old: m(2000), new: m(2000, 800, 300), userDriven: true)
        XCTAssertTrue(pin.allowsOlderPageLoad, "reader took over; older paging must work")
    }

    func test_beginReposition_repinsAndGatesOlderLoadAgain() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        pin.markBottomEstablished()
        _ = pin.scrollGeometryChanged(old: m(2000), new: m(2000, 800, 300), userDriven: true)
        pin.beginReposition()
        XCTAssertTrue(pin.isPinned)
        XCTAssertFalse(pin.allowsOlderPageLoad)
        pin.markBottomEstablished()
        XCTAssertTrue(pin.allowsOlderPageLoad)
    }

    func test_markBottomEstablished_ignoredWhileReleased() {
        var pin = ChatBottomPin()
        pin.loadDidFinish()
        _ = pin.scrollGeometryChanged(old: m(2000), new: m(2000, 800, 300), userDriven: true)
        pin.markBottomEstablished()
        XCTAssertFalse(pin.isPinned)
    }

    // MARK: - Source guards for the wiring

    private func sourceOf(_ rel: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_source_chatThreadView_olderAutoLoadGatedOnPin_andNoFixedSleepTrigger() throws {
        let s = try sourceOf("FellowScript/Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains("guard pin.allowsOlderPageLoad, olderHeaderVisible"),
                      "older auto-load must be gated until the bottom is established")
        XCTAssertTrue(s.contains("@State private var pin = ChatBottomPin()"))
        XCTAssertTrue(s.contains("pin.beginReposition()"), "thread enter/exit must re-pin")
        XCTAssertTrue(s.contains("onScrollPhaseChange"), "user drag must be tracked to release the pin")
        XCTAssertTrue(s.contains("pin.scrollGeometryChanged("), "geometry changes must feed the pin")
        XCTAssertFalse(s.contains("guard ready, let lastGroup = messageGroups.last else { return }"),
                       "the old one-shot ready handler must be gone")
    }

    func test_source_agentChatView_sharesPin() throws {
        let s = try sourceOf("FellowScript/Chat/AgentChatView.swift")
        XCTAssertTrue(s.contains("@State private var pin = ChatBottomPin()"))
        XCTAssertTrue(s.contains("pin.scrollGeometryChanged("))
        XCTAssertTrue(s.contains("settleBottomPin(proxy: proxy)"))
    }
}
