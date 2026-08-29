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

// MARK: - Ember Glass day-divider grouping logic (task
// 20260827-ember-glass-chat-rewrite, testing step 4)
//
// Added item 5 (design-notes.md §13) is real, functional grouping logic, not
// a cosmetic divider restyle: `MessageDisplayGroup.parseTimestamp`/`dayLabel`
// and `[MessageDisplayGroup].withDayDividers()` (Chat/MessageGroupRow.swift)
// use real `Calendar.isDate(_:inSameDayAs:)` detection to interleave labeled
// day-boundary rows into ChatThreadView's message list. These are pure
// functions of already-loaded data, unit-tested directly here per this
// project's convention for MessageDisplayGroup.grouped(from:me:) above.
final class MessageDisplayGroupDayDividerTests: XCTestCase {

    private func message(_ id: String, mine: Bool, sender: String, ts: String) -> FSMessage {
        FSMessage(id: id, text: "hi", mine: mine, sender: sender, timestamp: ts)
    }

    // MARK: dayLabel(for:calendar:)

    func testDayLabel_forToday_returnsToday() {
        XCTAssertEqual(MessageDisplayGroup.dayLabel(for: Date()), "Today")
    }

    func testDayLabel_forYesterday_returnsYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        XCTAssertEqual(MessageDisplayGroup.dayLabel(for: yesterday), "Yesterday")
    }

    func testDayLabel_forOlderDate_returnsShortMonthDayFormat() {
        // A date far enough in the past that it can never collide with
        // "Today"/"Yesterday" regardless of when this test runs.
        var components = DateComponents()
        components.year = 2020; components.month = 8; components.day = 25
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(MessageDisplayGroup.dayLabel(for: date), "Aug 25")
    }

    // MARK: parseTimestamp — must tolerate both real ISO8601 forms this app produces

    func testParseTimestamp_handlesServerFractionalSecondsFormat() {
        XCTAssertNotNil(MessageDisplayGroup.parseTimestamp("2026-08-09T18:00:00.000Z"))
    }

    func testParseTimestamp_handlesClientSendMessageFormatWithNoFractionalSeconds() {
        // ChatThreadViewModel.sendMessage() stamps its own outgoing messages
        // with ISO8601DateFormatter()'s default (no fractional seconds) — if
        // this weren't handled, every just-sent message would silently drop
        // out of day-boundary detection.
        XCTAssertNotNil(MessageDisplayGroup.parseTimestamp("2026-08-09T18:00:00Z"))
    }

    func testParseTimestamp_emptyStringReturnsNilRatherThanCrashing() {
        XCTAssertNil(MessageDisplayGroup.parseTimestamp(""))
    }

    func testParseTimestamp_malformedStringReturnsNilRatherThanCrashing() {
        XCTAssertNil(MessageDisplayGroup.parseTimestamp("not-a-real-date"))
    }

    // MARK: withDayDividers() — interleaving correctness

    func testWithDayDividers_singleDayMultipleGroups_insertsExactlyOneLeadingDivider() {
        let now = ISO8601DateFormatter().string(from: Date())
        let messages = [
            message("1", mine: false, sender: "alice", ts: now),
            message("2", mine: true,  sender: "",      ts: now),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        let rows = groups.withDayDividers()

        XCTAssertEqual(rows.count, 3, "one day-divider + two groups")
        guard case .dayDivider(_, let label) = rows[0] else {
            return XCTFail("first row must be a day divider for the first group's day")
        }
        XCTAssertEqual(label, "Today")
        guard case .group = rows[1], case .group = rows[2] else {
            return XCTFail("both message groups must follow the single leading divider, not get a divider each")
        }
    }

    func testWithDayDividers_groupsSpanningADayBoundary_insertsADividerAtEachBoundaryWithCorrectLabels() {
        let today = ISO8601DateFormatter().string(from: Date())
        let yesterday = ISO8601DateFormatter().string(
            from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)

        let messages = [
            message("1", mine: false, sender: "alice", ts: yesterday),
            message("2", mine: false, sender: "bob",   ts: yesterday), // different sender -> own group, same day
            message("3", mine: true,  sender: "",      ts: today),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 3, "sanity check: three distinct sender groups")

        let rows = groups.withDayDividers()
        // Expected order: [divider("Yesterday"), group(alice), group(bob), divider("Today"), group(me)]
        XCTAssertEqual(rows.count, 5)
        guard case .dayDivider(_, let firstLabel) = rows[0] else {
            return XCTFail("expected a leading divider for yesterday's groups")
        }
        XCTAssertEqual(firstLabel, "Yesterday")
        guard case .group = rows[1], case .group = rows[2] else {
            return XCTFail("both of yesterday's groups must render before the next divider, undivided from each other")
        }
        guard case .dayDivider(_, let secondLabel) = rows[3] else {
            return XCTFail("expected a divider at the day boundary between yesterday's last group and today's group")
        }
        XCTAssertEqual(secondLabel, "Today")
        guard case .group = rows[4] else {
            return XCTFail("today's group must follow its own divider")
        }
    }

    func testWithDayDividers_groupWithUnparseableTimestamp_getsNoDividerButDoesNotBreakLaterGroups() {
        // A group whose date is nil (e.g. a malformed timestamp that slipped
        // through) must not crash withDayDividers() or spuriously insert a
        // divider -- and must not corrupt day-boundary tracking for
        // subsequent groups that DO have a valid date.
        let today = ISO8601DateFormatter().string(from: Date())
        let messages = [
            message("1", mine: false, sender: "alice", ts: "not-a-real-date"),
            message("2", mine: true,  sender: "",      ts: today),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertNil(groups[0].date, "sanity check: the malformed timestamp really did fail to parse")

        let rows = groups.withDayDividers()
        // No divider for the undated first group; a "Today" divider still
        // precedes the second (dated) group.
        XCTAssertEqual(rows.count, 3)
        guard case .group = rows[0] else {
            return XCTFail("the undated group must render without a preceding divider")
        }
        guard case .dayDivider(_, let label) = rows[1] else {
            return XCTFail("the dated second group must still get its own divider")
        }
        XCTAssertEqual(label, "Today")
        guard case .group = rows[2] else {
            return XCTFail("the dated group must follow its divider")
        }
    }
}
