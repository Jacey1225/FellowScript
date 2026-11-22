// ThreadUnreadAndActionsTests.swift -- task 20261122-app-fixes-threads-widget
// (items 1 and 2): thread unread decoding/bookkeeping and the thread-message
// frame mapper. Pure value tests, no network. NOT built or run on the Linux
// authoring box (no xcodebuild); the testing gate / a Mac must run them.

import XCTest
@testable import FellowScript

final class ThreadUnreadTests: XCTestCase {

    private func decode(_ json: String) throws -> FSThreadSummary {
        try JSONDecoder().decode(FSThreadSummary.self, from: Data(json.utf8))
    }

    func test_unreadCount_decodes_andClampsNegativeAndMissingToZero() throws {
        XCTAssertEqual(try decode(#"{"id":"t","unread_count":3}"#).unreadCount, 3)
        XCTAssertEqual(try decode(#"{"id":"t","unread_count":-2}"#).unreadCount, 0)
        XCTAssertEqual(try decode(#"{"id":"t"}"#).unreadCount, 0)
    }

    func test_markingRead_clearsOnlyThatThread_caseInsensitively() {
        let rows = [FSThreadSummary(id: "A", unreadCount: 2), FSThreadSummary(id: "b", unreadCount: 1)]
        let next = FSThreadUnread.markingRead(rows, threadId: "a")
        XCTAssertEqual(next.map(\.unreadCount), [0, 1])
    }

    func test_incrementing_bumpsKnownThread_andIgnoresUnknown() {
        let rows = [FSThreadSummary(id: "a", unreadCount: 0)]
        XCTAssertEqual(FSThreadUnread.incrementing(rows, threadId: "a").first?.unreadCount, 1)
        XCTAssertEqual(FSThreadUnread.incrementing(rows, threadId: "zzz"), rows)
    }

    func test_accessibilitySuffix() {
        XCTAssertEqual(FSThreadUnread.accessibilitySuffix(FSThreadSummary(id: "a", unreadCount: 1)), ", unread")
        XCTAssertEqual(FSThreadUnread.accessibilitySuffix(FSThreadSummary(id: "a")), "")
    }

    func test_threadFrame_carriesSenderIdAndReply() throws {
        let frame: [String: Any] = [
            "id": "m1", "thread_id": "t1", "sender": "ada", "body": "hi", "created_at": "2026-11-22T10:00:00Z",
            "from_user_id": "u-ada", "reply_to_id": "m0", "reply_to_text": "first", "reply_to_author": "bob",
        ]
        let m = try XCTUnwrap(FSMessage(threadFrame: frame))
        XCTAssertEqual(m.senderId, "u-ada")
        XCTAssertEqual(m.reply?.id, "m0")
    }

    func test_threadFrame_withoutSenderId_hasNilSenderId() throws {
        let m = try XCTUnwrap(FSMessage(threadFrame: ["id": "m1", "thread_id": "t1"]))
        XCTAssertNil(m.senderId)
        XCTAssertNil(m.reply)
    }
}
