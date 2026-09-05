// MessageGroupRowBaselineTests.swift — testing gate coverage for task
// 20260904-compliance-readability-cleanup, step 1 (testing).
//
// MessageGroupRow.swift had NO test coverage of its actual View (`struct
// MessageGroupRow: View`, `struct DayDividerRow: View`) before this task —
// MessageDisplayGroupTests.swift only covers the file's pure data-layer
// helpers (`MessageDisplayGroup.grouped`/`parseTimestamp`/`dayLabel`,
// `withDayDividers()`). This file adds baseline/characterization coverage
// for the View layer itself, specifically so step 4 of this task (switching
// `accessibilityLabel(for:)`'s stringly-typed `switch message.attachmentKind`
// at MessageGroupRow.swift:268-274 to switch over the real `FSAttachmentKind`
// enum instead, per compile-errors #3) has something to verify against: the
// exact same accessibility-label text must come out for every attachment
// kind both before and after that refactor.
//
// Uses ViewInspector, matching this target's existing convention for
// stateless View structs (PillButtonTests.swift, DashboardEmptyStateTests.swift,
// NoteRowAuthorIndicatorTests.swift).

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class MessageGroupRowBaselineTests: XCTestCase {

    private func message(
        id: String = "m1", text: String = "Hello", mine: Bool = false, sender: String = "alice",
        attachmentKind: String? = nil, attachmentURL: String? = nil, attachmentMeta: FSAttachmentMeta? = nil
    ) -> FSMessage {
        var m = FSMessage(id: id, text: text, mine: mine, sender: sender, timestamp: "2026-09-04T12:00:00.000Z")
        m.attachmentKind = attachmentKind
        m.attachmentURL  = attachmentURL
        m.attachmentMeta = attachmentMeta
        return m
    }

    private func group(isOutgoing: Bool = false, senderName: String = "Alice",
                        senderInitial: String = "A", timeLabel: String = "3:00 PM",
                        messages: [FSMessage]) -> MessageDisplayGroup {
        MessageDisplayGroup(id: messages[0].id, senderInitial: senderInitial, senderName: senderName,
                            timeLabel: timeLabel, isOutgoing: isOutgoing, date: nil, messages: messages)
    }

    // Finds the bubble Group carrying a given accessibility label — the same
    // node compile-errors #3's switch produces the label for.
    private func findBubble(_ sut: MessageGroupRow, label: String) throws -> InspectableView<ViewType.Group> {
        try sut.inspect().find(ViewType.Group.self, where: { g in
            (try? g.accessibilityLabel().string()) == label
        })
    }

    // MARK: - Plain text message (no attachment): "{sender}: {text}"

    func test_plainTextMessage_accessibilityLabel_isSenderColonText() throws {
        let msg = message(text: "Hey there", sender: "alice")
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))

        XCTAssertNoThrow(try sut.inspect().find(text: "Hey there"))
        XCTAssertNoThrow(try findBubble(sut, label: "Alice: Hey there"))
    }

    func test_plainTextMessage_emptyAttachmentKindString_isTreatedAsNoAttachment() throws {
        // MessageGroupRow.bubble(for:) gates on `!kind.isEmpty`, so an empty
        // (as opposed to nil) attachmentKind string must still render as a
        // plain text bubble, not an (empty) attachment branch.
        let msg = message(text: "plain", attachmentKind: "")
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))
        XCTAssertNoThrow(try findBubble(sut, label: "Alice: plain"))
    }

    // MARK: - Per-kind accessibility label (the exact switch step 4 touches)

    func test_imageAttachment_accessibilityLabel_isPhotoAttachment() throws {
        let msg = message(text: "", attachmentKind: "image")
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))
        XCTAssertNoThrow(try findBubble(sut, label: "Alice: photo attachment"))
    }

    func test_videoAttachment_accessibilityLabel_isVideoAttachmentTapToPlay() throws {
        let msg = message(text: "", attachmentKind: "video")
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))
        XCTAssertNoThrow(try findBubble(sut, label: "Alice: video attachment, tap to play"))
    }

    func test_gifAttachment_accessibilityLabel_isGIFAttachment() throws {
        let msg = message(text: "", attachmentKind: "gif")
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))
        XCTAssertNoThrow(try findBubble(sut, label: "Alice: GIF attachment"))
    }

    func test_fileAttachment_withFilename_accessibilityLabel_includesFilename() throws {
        let msg = message(text: "", attachmentKind: "file",
                           attachmentMeta: FSAttachmentMeta(filename: "report.pdf"))
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))
        XCTAssertNoThrow(try findBubble(sut, label: "Alice: file attachment, report.pdf, double tap to download"))
    }

    func test_fileAttachment_missingFilename_fallsBackToGenericFileLabel() throws {
        let msg = message(text: "", attachmentKind: "file", attachmentMeta: nil)
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))
        XCTAssertNoThrow(try findBubble(sut, label: "Alice: file attachment, file, double tap to download"))
    }

    func test_unrecognizedAttachmentKind_fallsBackToPlainSenderColonTextLabel() throws {
        // Baseline for the pre-refactor behavior: any string not matching one
        // of the four known cases (e.g. a value the enum-based rewrite in
        // step 4 doesn't recognize either) falls through to the `default:`
        // branch today -- must still fall back to the same plain-text label
        // afterward, not crash or produce something new.
        let msg = message(text: "caption", attachmentKind: "audio")
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))
        XCTAssertNoThrow(try findBubble(sut, label: "Alice: caption"))
    }

    // MARK: - Caption alongside an attachment

    func test_imageAttachment_withCaptionText_rendersCaptionBelowAttachment() throws {
        let msg = message(text: "Look at this!", attachmentKind: "image")
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: [msg]))
        XCTAssertNoThrow(try sut.inspect().find(text: "Look at this!"),
                          "a caption riding alongside an attachment must still render inside the bubble")
    }

    func test_imageAttachment_withoutCaptionText_rendersNoExtraTextNode() throws {
        // Compared against a sibling group whose only difference is a
        // non-empty message.text -- if bubble(for:) were to unconditionally
        // render the caption Text (dropping the `!message.text.isEmpty`
        // guard), this diff would collapse to zero.
        let withoutCaption = MessageGroupRow(group: group(senderName: "Alice", messages: [message(text: "", attachmentKind: "image")]))
        let withCaption    = MessageGroupRow(group: group(senderName: "Alice", messages: [message(text: "caption", attachmentKind: "image")]))

        let withoutCount = try withoutCaption.inspect().findAll(ViewType.Text.self).count
        let withCount    = try withCaption.inspect().findAll(ViewType.Text.self).count
        XCTAssertEqual(withCount, withoutCount + 1,
                        "a non-empty message.text riding alongside an attachment must add exactly one caption Text node")
        XCTAssertThrowsError(try withoutCaption.inspect().find(text: "caption"))
    }

    // MARK: - Outgoing vs incoming layout (sender header + grouped bubbles)

    func test_outgoingMessage_rendersSenderNameAndTimeLabel() throws {
        let msg = message(text: "hi", mine: true, sender: "")
        let sut = MessageGroupRow(group: group(isOutgoing: true, senderName: "You", senderInitial: "Y", messages: [msg]))
        XCTAssertNoThrow(try sut.inspect().find(text: "You"))
        XCTAssertNoThrow(try sut.inspect().find(text: "3:00 PM"))
    }

    func test_emptyTimeLabel_rendersNoTimeText() throws {
        // Compared against a sibling group whose only difference is a
        // non-empty timeLabel -- isolates the `!group.timeLabel.isEmpty`
        // guard from the avatar/sender-name Text nodes also present in body.
        let withoutTime = MessageGroupRow(group: group(senderName: "Alice", timeLabel: "", messages: [message(text: "hi")]))
        let withTime    = MessageGroupRow(group: group(senderName: "Alice", timeLabel: "3:00 PM", messages: [message(text: "hi")]))

        let withoutCount = try withoutTime.inspect().findAll(ViewType.Text.self).count
        let withCount    = try withTime.inspect().findAll(ViewType.Text.self).count
        XCTAssertEqual(withCount, withoutCount + 1,
                        "a non-empty timeLabel must add exactly one Text node over the empty-timeLabel case")
        XCTAssertThrowsError(try withoutTime.inspect().find(text: "3:00 PM"))
    }

    func test_multipleMessagesInOneGroup_rendersOneBubblePerMessage() throws {
        let messages = [
            message(id: "1", text: "first"),
            message(id: "2", text: "second"),
            message(id: "3", text: "third"),
        ]
        let sut = MessageGroupRow(group: group(senderName: "Alice", messages: messages))
        XCTAssertNoThrow(try sut.inspect().find(text: "first"))
        XCTAssertNoThrow(try sut.inspect().find(text: "second"))
        XCTAssertNoThrow(try sut.inspect().find(text: "third"))
    }
}

// MARK: - DayDividerRow (zero prior coverage of the View itself)

final class DayDividerRowBaselineTests: XCTestCase {

    func test_rendersTheGivenLabelText() throws {
        let sut = DayDividerRow(label: "Yesterday")
        XCTAssertNoThrow(try sut.inspect().find(text: "Yesterday"))
    }

    func test_accessibilityElementCombinesToJustTheLabel() throws {
        let sut = DayDividerRow(label: "Today")
        let root = try sut.inspect().hStack()
        XCTAssertEqual(try root.accessibilityLabel().string(), "Today",
                        "the two flanking hairlines must be combined away, leaving VoiceOver only the day label")
    }
}
