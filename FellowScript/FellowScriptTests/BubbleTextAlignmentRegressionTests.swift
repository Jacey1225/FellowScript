// BubbleTextAlignmentRegressionTests.swift — testing gate for task
// 20261022-bubble-text-align. Text inside the user's OWN sent chat bubbles was
// right-aligned (`group.isOutgoing ? .trailing : .leading`); it must be leading
// for sent and received alike. Bubble POSITION (sent on the right) is untouched.
//
// Two layers: a source pin on MessageGroupRow.bubble(for:), and a ViewInspector
// render of the real view for both directions.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class BubbleTextAlignmentRegressionTests: XCTestCase {

    private func bubbleSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let full = try String(contentsOf: root.appendingPathComponent("FellowScript/Chat/MessageGroupRow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(full.range(of: "private func bubble(for message: FSMessage)")).lowerBound
        let tail = String(full[start...])
        // bubble(for:) ends at the next top-level-ish func; 60 lines is ample and stays inside it.
        return tail.components(separatedBy: "\n").prefix(60).joined(separator: "\n")
    }

    func testSource_bubbleContentIsNeverTrailingAligned() throws {
        let src = try bubbleSource()
        XCTAssertFalse(src.contains("isOutgoing ? .trailing"), "bubble text/content must not right-align for sent messages")
        XCTAssertFalse(src.contains(".multilineTextAlignment(.trailing)"))
        XCTAssertFalse(src.contains("VStack(alignment: .trailing"))
    }

    func testSource_bubbleUsesLeadingAlignmentInAllFourPlaces() throws {
        let src = try bubbleSource()
        XCTAssertEqual(src.components(separatedBy: "VStack(alignment: .leading, spacing: 0)").count - 1, 2,
                       "outer bubble VStack and attachment-caption VStack must both be .leading")
        XCTAssertEqual(src.components(separatedBy: ".multilineTextAlignment(.leading)").count - 1, 2,
                       "caption and plain-text MentionText must both be .leading")
    }

    private func render(mine: Bool) throws -> (align: TextAlignment, vstack: HorizontalAlignment?) {
        var m = FSMessage(id: "m1", text: "line one is long enough to wrap onto a second line of the bubble\nline two",
                          mine: mine, sender: "alice", timestamp: "2026-10-22T12:00:00.000Z")
        m.attachmentKind = nil
        let g = MessageDisplayGroup(id: "m1", senderInitial: "A", senderName: "Alice", timeLabel: "3:00 PM",
                                    isOutgoing: mine, date: nil, messages: [m])
        let sut = MessageGroupRow(group: g)
        let mt = try sut.inspect().find(ViewType.View<MentionText>.self)
        let align = try mt.multilineTextAlignment()
        // Outermost matching VStack is the row's own column (placement, out of scope);
        // the innermost one containing the text is the bubble's content stack.
        let stacks = try sut.inspect().findAll(ViewType.VStack.self, where: { v in
            (try? v.find(ViewType.View<MentionText>.self)) != nil
        })
        let bubbleStack = try XCTUnwrap(stacks.last)
        return (align, try bubbleStack.alignment())
    }

    func testRendered_sentBubbleTextIsLeading() throws {
        let r = try render(mine: true)
        XCTAssertEqual(r.align, .leading)
        XCTAssertEqual(r.vstack, .leading)
    }

    func testRendered_receivedBubbleTextIsLeading() throws {
        let r = try render(mine: false)
        XCTAssertEqual(r.align, .leading)
        XCTAssertEqual(r.vstack, .leading)
    }
}
