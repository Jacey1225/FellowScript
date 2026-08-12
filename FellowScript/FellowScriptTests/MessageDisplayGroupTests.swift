// MessageDisplayGroupTests.swift — coverage for task
// 20260809-chat-schedule-migrate-fellowscript, step 5 (testing).
//
// MessageDisplayGroup.grouped(from:me:) (Chat/MessageGroupRow.swift) is the
// presentation-only transform that powers ChatThreadView's new Slack-style
// grouped message list: it takes the *real* FSMessage array already loaded
// by ChatThreadViewModel and groups consecutive messages from the same
// sender into single visual groups. This is non-trivial pure logic
// introduced by this migration (the pre-restyle ChatThreadView rendered one
// bubble per message, ungrouped), so it gets direct unit coverage here.

import XCTest
@testable import FellowScript

final class MessageDisplayGroupTests: XCTestCase {

    private func message(_ id: String, text: String, mine: Bool, sender: String, ts: String = "2026-08-09T18:00:00.000Z") -> FSMessage {
        FSMessage(id: id, text: text, mine: mine, sender: sender, timestamp: ts)
    }

    func testEmptyMessageListProducesNoGroups() {
        XCTAssertTrue(MessageDisplayGroup.grouped(from: [], me: nil).isEmpty)
    }

    func testConsecutiveMessagesFromTheSameSenderAreGroupedTogether() {
        let messages = [
            message("1", text: "Hey", mine: false, sender: "alice"),
            message("2", text: "you there?", mine: false, sender: "alice"),
            message("3", text: "lol", mine: false, sender: "alice"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].messages.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(groups[0].senderName, "alice")
        XCTAssertFalse(groups[0].isOutgoing)
    }

    func testAlternatingSendersProduceSeparateGroupsInOrder() {
        let messages = [
            message("1", text: "hi", mine: false, sender: "alice"),
            message("2", text: "hi back", mine: true, sender: ""),
            message("3", text: "how are you", mine: false, sender: "alice"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map { $0.isOutgoing }, [false, true, false])
        XCTAssertEqual(groups.map { $0.messages.count }, [1, 1, 1])
    }

    func testDifferentSendersOnIncomingSideAreNotMergedIntoOneGroup() {
        // Two different real contacts (e.g. in a group chat) sending
        // consecutive incoming messages must NOT be merged just because
        // both have mine == false.
        let messages = [
            message("1", text: "hi", mine: false, sender: "alice"),
            message("2", text: "hello", mine: false, sender: "bob"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].senderName, "alice")
        XCTAssertEqual(groups[1].senderName, "bob")
    }

    func testOutgoingMessagesAreAlwaysGroupedTogetherRegardlessOfSenderField() {
        // mine == true messages always originate from "me" — the grouping
        // must not require sender-field equality on the outgoing side (the
        // real sendMessage() path always sets sender to "").
        let messages = [
            message("1", text: "a", mine: true, sender: ""),
            message("2", text: "b", mine: true, sender: ""),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isOutgoing)
    }

    func testGroupIdIsStableAsFirstMessageId() {
        let messages = [
            message("first", text: "a", mine: false, sender: "alice"),
            message("second", text: "b", mine: false, sender: "alice"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups[0].id, "first")
    }

    func testOutgoingSenderInitialUsesRealUserInitialsWhenProvided() {
        let me = FSUser(user_id: "u1", username: "Zoe", email: "z@example.com")
        let messages = [message("1", text: "hi", mine: true, sender: "")]
        let groups = MessageDisplayGroup.grouped(from: messages, me: me)
        XCTAssertEqual(groups[0].senderInitial, "Z")
        XCTAssertEqual(groups[0].senderName, "You")
    }

    func testIncomingSenderNameFallsBackToThemWhenSenderFieldIsEmpty() {
        // Real-world guard: an incoming message with an unexpectedly empty
        // sender field (e.g. malformed server payload) must not crash or
        // render a blank name.
        let messages = [message("1", text: "hi", mine: false, sender: "")]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups[0].senderName, "Them")
    }
}
