// ReplyBodyTruncationRegressionTests.swift — testing gate for task
// 20261105-chat-reply-body-truncation. A reply's OWN body rendered as one line with
// a tail ellipsis (only on replies, because the quote row's fixedSize(vertical:) sits
// in the same VStack). Fix: the body claims its full wrapped height.
//
// Renders the real MessageGroupRow in a UIHostingController and measures it, under a
// normal height proposal and a squeezed one.

import XCTest
import SwiftUI
import UIKit
@testable import FellowScript

@MainActor
final class ReplyBodyTruncationRegressionTests: XCTestCase {

    private let longBody = String(repeating: "this is a fairly long reply body that must wrap onto many lines ", count: 8)
        + String(repeating: "U", count: 120)

    private func row(text: String, reply: FSReplyRef?) -> MessageGroupRow {
        var m = FSMessage(id: "m1", text: text, mine: false, sender: "alice", timestamp: "2026-11-05T12:00:00.000Z")
        m.reply = reply
        let g = MessageDisplayGroup(id: "m1", senderInitial: "A", senderName: "Alice", timeLabel: "3:00 PM",
                                    isOutgoing: false, date: nil, messages: [m])
        return MessageGroupRow(group: g)
    }

    private func height(_ v: MessageGroupRow, proposedHeight: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: v)
        return host.sizeThatFits(in: CGSize(width: 390, height: proposedHeight)).height
    }

    private let quote = FSReplyRef(id: "o1", text: "original message being quoted", author: "Bob")

    func testReplyBody_wrapsToFullHeight_notOneLine() {
        let oneLine = height(row(text: "short", reply: quote), proposedHeight: 10_000)
        let long = height(row(text: longBody, reply: quote), proposedHeight: 10_000)
        // ~8+ wrapped lines of body text must add far more than a couple of lines.
        XCTAssertGreaterThan(long - oneLine, 100, "long reply body must wrap to many lines (got \(long) vs \(oneLine))")
    }

    func testReplyBody_isNotSqueezedByShortHeightProposal() {
        let tall = height(row(text: longBody, reply: quote), proposedHeight: 10_000)
        let squeezed = height(row(text: longBody, reply: quote), proposedHeight: 90)
        XCTAssertEqual(squeezed, tall, accuracy: 1, "a short height proposal must not clip the reply body (tall \(tall), squeezed \(squeezed))")
    }

    func testReplyBody_matchesNonReplyBodyHeightPlusQuote() {
        let plain = height(row(text: longBody, reply: nil), proposedHeight: 10_000)
        let reply = height(row(text: longBody, reply: quote), proposedHeight: 90)
        XCTAssertGreaterThanOrEqual(reply, plain, "a reply must be at least as tall as the same body without a quote (reply \(reply), plain \(plain))")
    }
}
