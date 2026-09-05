// ChatMessageGroupingMemoizationRegressionTests.swift — testing-gate coverage
// for task 20260904-compliance-performance-fixes, step 2 (High H12): chat
// message grouping + day-divider computation used to be plain computed
// properties on ChatThreadView, re-run in full on every SwiftUI render
// (including every composer keystroke via `text`'s @State, and every other
// unrelated @State toggle) with an O(n^2)-worst-case algorithm underneath.
//
// The fix moved messageGroups/threadRows into @State caches on
// ChatThreadView, recomputed only via recomputeMessageGroups() — called
// once up front from `.task` and again only from
// `.onChange(of: vm.messages.count)`. Because messageGroups/threadRows are
// private @State on a View struct (not a testable ViewModel), this suite
// covers the two things that actually matter for a caller of this code:
//
//   1. The underlying pure algorithm (MessageDisplayGroup.grouped /
//      withDayDividers) is correct — no visual/order regression versus the
//      pre-memoization behavior, including under incremental "append one
//      message" growth (the exact access pattern recomputeMessageGroups()
//      is now gated behind).
//   2. A source-guard against the specific regression this task fixed:
//      messageGroups/threadRows must remain cached (@State), not
//      reintroduced as plain `var ... : [T] { ... }` computed properties
//      that would silently re-run on every render again.
import XCTest
@testable import FellowScript

final class ChatMessageGroupingMemoizationRegressionTests: XCTestCase {

    private func msg(_ id: String, mine: Bool, sender: String, timestamp: String) -> FSMessage {
        FSMessage(id: id, text: "text-\(id)", mine: mine, sender: sender, timestamp: timestamp)
    }

    // MARK: - Grouping correctness

    func test_grouped_consecutiveSameSenderMessages_collapseIntoOneGroup() {
        let messages = [
            msg("1", mine: false, sender: "alice", timestamp: "2026-09-04T10:00:00Z"),
            msg("2", mine: false, sender: "alice", timestamp: "2026-09-04T10:00:05Z"),
            msg("3", mine: false, sender: "alice", timestamp: "2026-09-04T10:00:10Z"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 1, "three consecutive messages from the same sender must collapse into one group")
        XCTAssertEqual(groups[0].messages.map(\.id), ["1", "2", "3"])
    }

    func test_grouped_senderChange_startsNewGroup() {
        let messages = [
            msg("1", mine: false, sender: "alice", timestamp: "2026-09-04T10:00:00Z"),
            msg("2", mine: true,  sender: "",      timestamp: "2026-09-04T10:00:05Z"),
            msg("3", mine: false, sender: "alice",  timestamp: "2026-09-04T10:00:10Z"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 3, "an outgoing message and a return to the same sender must each start a new group, not merge across the interruption")
        XCTAssertEqual(groups.map { $0.messages.map(\.id) }, [["1"], ["2"], ["3"]])
    }

    func test_grouped_differentSendersBothIncoming_eachStartsNewGroup() {
        let messages = [
            msg("1", mine: false, sender: "alice", timestamp: "2026-09-04T10:00:00Z"),
            msg("2", mine: false, sender: "bob",   timestamp: "2026-09-04T10:00:05Z"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 2, "two different incoming senders must never merge into the same group even though both have mine == false")
    }

    func test_grouped_preservesOrder_appendOnlyGrowth() {
        // Mirrors recomputeMessageGroups()'s real trigger: vm.messages grows
        // by exactly one appended message at a time (an incoming WS frame,
        // or the sender's own optimistic echo).
        var messages = [msg("1", mine: false, sender: "alice", timestamp: "2026-09-04T10:00:00Z")]
        var groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 1)

        messages.append(msg("2", mine: false, sender: "alice", timestamp: "2026-09-04T10:00:05Z"))
        groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 1, "appending a same-sender message must extend the existing group")
        XCTAssertEqual(groups[0].messages.map(\.id), ["1", "2"])

        messages.append(msg("3", mine: true, sender: "", timestamp: "2026-09-04T10:00:10Z"))
        groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 2, "appending an outgoing message must start a new trailing group without disturbing the prior one")
        XCTAssertEqual(groups.map { $0.messages.map(\.id) }, [["1", "2"], ["3"]])
    }

    func test_grouped_emptyMessages_producesEmptyGroups() {
        XCTAssertTrue(MessageDisplayGroup.grouped(from: [], me: nil).isEmpty)
    }

    // MARK: - Day-divider correctness (interacts with grouping's `date` field)

    func test_withDayDividers_sameDayGroups_getExactlyOneLeadingDivider() {
        let messages = [
            msg("1", mine: false, sender: "alice", timestamp: "2026-09-04T09:00:00Z"),
            msg("2", mine: true,  sender: "",      timestamp: "2026-09-04T15:00:00Z"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        let rows = groups.withDayDividers()

        let dividerCount = rows.filter { if case .dayDivider = $0 { return true }; return false }.count
        XCTAssertEqual(dividerCount, 1, "two groups on the same calendar day must get exactly one leading day divider, not one per group")
        if case .dayDivider = rows.first {} else { XCTFail("first row must be the day divider") }
    }

    func test_withDayDividers_crossDayGroups_getADividerAtEachBoundary() {
        // grouped() merges purely on sender/mine, not date, so a genuine
        // same-sender run spanning a real calendar day boundary (e.g. a
        // conversation left open overnight) still collapses into ONE group
        // -- documented separately below. To exercise two groups that
        // actually span two different calendar days, force a sender change
        // at the boundary.
        let crossDayMessages = [
            msg("1", mine: false, sender: "alice", timestamp: "2026-09-03T09:00:00Z"),
            msg("2", mine: true,  sender: "",      timestamp: "2026-09-04T09:00:00Z"),
        ]
        let crossDayGroups = MessageDisplayGroup.grouped(from: crossDayMessages, me: nil)
        XCTAssertEqual(crossDayGroups.count, 2)
        let rows = crossDayGroups.withDayDividers()
        let dividerCount = rows.filter { if case .dayDivider = $0 { return true }; return false }.count
        XCTAssertEqual(dividerCount, 2, "two groups on two different calendar days must each get their own leading day divider")
    }

    func test_withDayDividers_sameSenderRunAcrossDayBoundary_singleGroupStillGetsOneDivider() {
        // Documents the pre-existing (unrelated to this task) behavior noted
        // above: grouped() has no date-boundary awareness of its own, so this
        // merges into one MessageDisplayGroup dated at the FIRST message's
        // timestamp -- withDayDividers() must not crash or double-count on
        // this shape, it just can't split mid-group.
        let messages = [
            msg("1", mine: false, sender: "alice", timestamp: "2026-09-03T23:59:00Z"),
            msg("2", mine: false, sender: "alice", timestamp: "2026-09-04T00:01:00Z"),
        ]
        let groups = MessageDisplayGroup.grouped(from: messages, me: nil)
        XCTAssertEqual(groups.count, 1)
        XCTAssertNoThrow(groups.withDayDividers())
        XCTAssertEqual(groups.withDayDividers().filter { if case .dayDivider = $0 { return true }; return false }.count, 1)
    }

    // MARK: - Source guard: messageGroups/threadRows must stay cached @State,
    // recomputed only from `.task` / `.onChange(of: vm.messages.count)` — not
    // reintroduced as computed properties that re-run on every render.

    func test_source_chatThreadView_messageGroupsAndThreadRowsAreCachedState_notComputedProperties() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Chat/ChatThreadView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var messageGroups: [MessageDisplayGroup] = []"),
                      "messageGroups must be a cached @State value, not a computed property recomputed on every render")
        XCTAssertTrue(source.contains("@State private var threadRows:    [ChatThreadRow]       = []"),
                      "threadRows must be a cached @State value, not a computed property recomputed on every render")
        XCTAssertTrue(source.contains(".onChange(of: vm.messages.count)"),
                      "recomputation must be gated behind an actual change to the message list, not run unconditionally on every render")
    }
}
