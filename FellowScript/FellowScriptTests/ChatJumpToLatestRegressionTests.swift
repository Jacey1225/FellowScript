// ChatJumpToLatestRegressionTests.swift -- task 20261009-chat-jump-to-latest.
// The button's logic is view-local, so this suite proves its precondition at
// the view-model layer (after paging far back the newest message is still the
// last row, in order, no dupes) and source-guards the View wiring.
import XCTest
@testable import FellowScript

@MainActor
final class ChatJumpToLatestRegressionTests: XCTestCase {

    private func m(_ id: String) -> FSMessage {
        FSMessage(id: id, text: "t-\(id)", mine: false, sender: "someone", timestamp: "2026-10-01T10:00:00Z")
    }
    private func page(_ msgs: [FSMessage], more: Bool, cursorId: String? = nil) -> FSMessagePage {
        FSMessagePage(messages: msgs, hasMore: more,
                      cursor: more ? FSMessageCursor(timestamp: "ts-\(cursorId ?? msgs.first!.id)", seq: 1, id: cursorId ?? msgs.first!.id) : nil)
    }

    func test_pagedFarBack_newestMessageStaysLastRow_noDuplicates() async {
        let s = ThrowingTestDataService()
        s.wsBaseOverride = "ws://127.0.0.1:1"
        let dm = FSContact(id: "friend-1", name: "Friend", type: .friend)
        s.historyResult = .paged(page([m("5"), m("6")], more: true, cursorId: "5"))
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: "me-\(UUID().uuidString)",
                      capabilities: FSCapabilities(features: ["chat_pagination_dm": true], exploreLink: nil, termsCurrent: true))
        s.olderResults = [.success(page([m("3"), m("4")], more: true, cursorId: "3")),
                          .success(page([m("1"), m("2")], more: false))]
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        XCTAssertEqual(vm.messages.last?.id, "6", "jump-to-latest targets the last row, which must stay the newest")
        XCTAssertEqual(vm.messages.map(\.id), ["1", "2", "3", "4", "5", "6"])
        vm.disconnect()
    }

    func test_source_jumpButton_wiring() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Chat/ChatThreadView.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(src.contains("onScrollGeometryChange"))
        XCTAssertTrue(src.contains("Jump to latest messages"))
        XCTAssertTrue(src.contains(".accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(src.contains("minWidth: 44, minHeight: 44"))
        XCTAssertTrue(src.contains("@ScaledMetric"))
        XCTAssertTrue(src.contains("proxy.scrollTo(lastGroup.id, anchor: .bottom)"))
        XCTAssertTrue(src.contains("withMotionAwareAnimation(.easeOut(duration: 0.25), reduceMotion: reduceMotion)"))
        XCTAssertTrue(src.contains("if isAwayFromBottom && readyForInitialScroll && !messageGroups.isEmpty"),
                      "button must be removed from the tree when hidden")
        XCTAssertFalse(src.contains(".linear"), "no linear animation")
    }
}
