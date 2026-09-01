// AgentChatHeaderRemovalRegressionTests.swift — coverage for task
// 20260831-agent-chat-header-removal (testing gate).
//
// Proves the specific behaviors this task's frontend gate implemented
// against the real, shipped Chat/AgentChatView.swift source, so a
// regression of any one of these facts fails here rather than only being
// caught by a future manual screenshot comparison:
//
//   1. AgentMessageBubble no longer constructs a per-message avatar-icon +
//      sender-name(+timestamp) header row/column, for either message
//      direction — neither `message.formattedTime` nor a standalone
//      sender-name Text/avatar Circle exists in the live-rendered tree.
//   2. The freed space actually reaches the text column: a single
//      Theme.spacingLG gutter (not the old avatar+HStack-spacing column) on
//      the non-sender side, and a widened (0.95) screen-relative maxWidth
//      cap, applied to both "mine" and agent-response messages.
//   3. Sender identity remains programmatically available via the combined
//      accessibility label (`"<senderName>: <text>"`) even though the
//      visual row is gone — the accessibility contract established by
//      prior tasks (20260830-agent-chat-bubble-removal,
//      20260831-agent-chat-width-separator) is unchanged by this one.
//   4. No regressions to the screen-level header (back button + agent
//      avatar/name), the composer, or the "mine" vs. agent-response bubble
//      fill/border asymmetry — all explicitly out of scope for this task.
//
// Follows this project's established two-technique pattern (see
// AgentChatBubbleRemovalRegressionTests.swift /
// AgentChatWidthSeparatorRegressionTests.swift): source-text pinning for
// *absent*-modifier / exact-literal facts, and direct ViewInspector hosting
// for live-render facts.

import XCTest
import SwiftUI
import UIKit
import ViewInspector
@testable import FellowScript

// MARK: - Shared source reader

private func readAgentChatSource(from file: StaticString = #filePath) throws -> String {
    let thisFile = URL(fileURLWithPath: "\(file)")
    let projectFile = thisFile
        .deletingLastPathComponent()          // FellowScriptTests/
        .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
        .appendingPathComponent("FellowScript/Chat/AgentChatView.swift")
    return try String(contentsOf: projectFile, encoding: .utf8)
}

// MARK: - 1/2. Source-level: header row/avatar gone, freed space reaches the text

final class AgentChatHeaderRemovalSourceTests: XCTestCase {

    func test_source_agentMessageBubbleBody_hasNoTimestampReference() throws {
        let source = try readAgentChatSource()
        guard let structRange = source.range(of: "struct AgentMessageBubble: View {") else {
            XCTFail("could not locate AgentMessageBubble in the real source")
            return
        }
        let bubbleSource = String(source[structRange.lowerBound...])
        // Restrict to just this struct (stop at the next top-level struct).
        let bubbleBody: Substring
        if let nextStruct = bubbleSource.range(of: "\nstruct ", range: bubbleSource.index(bubbleSource.startIndex, offsetBy: 30)..<bubbleSource.endIndex) {
            bubbleBody = bubbleSource[bubbleSource.startIndex..<nextStruct.lowerBound]
        } else {
            bubbleBody = bubbleSource[...]
        }
        XCTAssertFalse(bubbleBody.contains("formattedTime"),
                       "AgentMessageBubble must no longer render message.formattedTime anywhere — the timestamp label was part of the removed header row")
        XCTAssertFalse(bubbleBody.contains("HStack(spacing: 8)"),
                       "the old sender-name/timestamp HStack(spacing: 8) row must be gone")
    }

    func test_source_agentMessageBubble_hasNoAvatarView() throws {
        let source = try readAgentChatSource()
        guard let structRange = source.range(of: "struct AgentMessageBubble: View {"),
              let bodyRange = source.range(of: "var body: some View {", range: structRange.upperBound..<source.endIndex),
              let accessRange = source.range(of: ".accessibilityLabel(\"\\(senderName): \\(message.text)\")", range: bodyRange.upperBound..<source.endIndex) else {
            XCTFail("could not locate AgentMessageBubble.body in the real source")
            return
        }
        let bodySource = String(source[bodyRange.upperBound..<accessRange.upperBound])

        XCTAssertFalse(bodySource.contains("Circle()"),
                       "AgentMessageBubble.body must no longer construct the circular avatar badge — that visual affordance was removed alongside the header row")
        XCTAssertFalse(bodySource.contains("userInitial"),
                       "the per-message avatar's initial-letter rendering (driven by userInitial) must be gone from the body — userInitial may still be an unused stored property for call-site compatibility, but must not be rendered")
    }

    func test_source_singleGutterPerSide_appliesToBothDirections() throws {
        // A single Theme.spacingLG gutter (not the old avatar(32)+HStack-
        // spacing(12) column) sits on the non-sender side only, for both
        // "mine" and agent-response messages — replacing the removed
        // header/avatar column's width with usable text space rather than
        // leaving it as unused padding (the prior round's core mistake,
        // per the intake spec).
        let source = try readAgentChatSource()
        XCTAssertTrue(source.contains("if message.mine { Spacer(minLength: Theme.spacingLG) }"),
                      "the 'mine' branch must keep a single leading Theme.spacingLG gutter")
        XCTAssertTrue(source.contains("if !message.mine { Spacer(minLength: Theme.spacingLG) }"),
                      "the agent-response branch must keep a single trailing Theme.spacingLG gutter")

        // Old avatar-column construction (spacing 12/32pt Circle-based
        // HStack layout) must not still be present inside AgentMessageBubble
        // specifically -- note the screen-level `header` property
        // legitimately keeps its own unrelated HStack(spacing: 12) for its
        // own avatar+name (explicitly out of scope for this task), so this
        // check is scoped to AgentMessageBubble's body only rather than the
        // whole file.
        guard let structRange = source.range(of: "struct AgentMessageBubble: View {") else {
            XCTFail("could not locate AgentMessageBubble in the real source")
            return
        }
        let bubbleSource = String(source[structRange.lowerBound...])
        XCTAssertFalse(bubbleSource.contains("HStack(spacing: 12) {"),
                       "AgentMessageBubble must no longer construct the old avatar+content HStack(spacing: 12) column layout")
    }

    func test_source_maxWidthCap_widenedTo0_95_afterColumnRemoval() throws {
        let source = try readAgentChatSource()
        XCTAssertTrue(source.contains(".frame(maxWidth: UIScreen.main.bounds.width * 0.95, alignment: message.mine ? .trailing : .leading)"),
                      "the maxWidth cap must be re-tuned to 0.95 of screen width once the avatar/header column was removed, per the spec's instruction to re-tune the cap alongside the removal rather than leave it as an unused headroom increase")
    }

    func test_source_accessibilityLabel_stillCombinesSenderAndText() throws {
        // Q14.2 preference: accessibility wins by default. The visual row
        // is gone, but sender attribution must remain available to
        // VoiceOver via the combined accessibility label.
        let source = try readAgentChatSource()
        XCTAssertTrue(source.contains(".accessibilityElement(children: .combine)"),
                      "AgentMessageBubble must still combine its children into a single accessibility element")
        XCTAssertTrue(source.contains(".accessibilityLabel(\"\\(senderName): \\(message.text)\")"),
                      "AgentMessageBubble must still expose sender identity + message text as its accessibility label")
    }

    func test_source_screenHeaderAndComposer_untouched() throws {
        // Explicitly out of scope per intake spec: the screen-level header
        // (back button + agent avatar/name) and the composer.
        let source = try readAgentChatSource()
        XCTAssertTrue(source.contains("RoundIconButton(systemIcon: \"chevron.left\") { dismiss() }"),
                      "the screen-level header's back button must be untouched")
        XCTAssertTrue(source.contains("Text(agent.displayLabel)"),
                      "the screen-level header's agent identity label must be untouched")
        XCTAssertTrue(source.contains("\"Ask about Scripture…\""),
                      "the composer's placeholder copy must be untouched")
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Message to agent\")"),
                      "the composer's accessibility label must be untouched")
    }

    func test_source_mineVsAgentBubbleChromeAsymmetry_untouched() throws {
        // Established in prior tasks as intentional — must not be reverted
        // as a side effect of removing the header row.
        let source = try readAgentChatSource()
        XCTAssertTrue(source.contains(".background(Theme.gold.opacity(0.18))"),
                      "the 'mine' bubble's gold-tinted fill must be untouched")
        XCTAssertTrue(source.contains(".topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusLG))"),
                      "the 'mine' bubble's top-edge highlight must be untouched")
    }
}

// MARK: - 3/4. Live render: header row truly absent, text + a11y label still work

final class AgentChatHeaderRemovalRenderTests: XCTestCase {

    private func makeMessage(mine: Bool, text: String) -> FSAgentMessage {
        FSAgentMessage(id: UUID().uuidString, text: text, mine: mine, timestamp: "2026-08-31T10:15:00Z")
    }

    func test_agentMessage_rendersNoSenderNameOrTimeText() throws {
        // Avatar-Circle absence is covered at the source level
        // (test_source_agentMessageBubble_hasNoAvatarView) since ViewInspector
        // represents all SwiftUI shapes (Circle *and* the 'mine' bubble's
        // legitimate RoundedRectangle clip/stroke) under the same generic
        // ViewType.Shape, so a live-tree shape count can't distinguish them.
        // This test's concern is the header row's *content*: neither the
        // sender name nor a formatted timestamp should appear as their own
        // rendered Text -- only inside the (non-Text) accessibility label
        // modifier.
        let message = makeMessage(mine: false, text: "The Logos in John 1 draws on both Greek philosophy and Hebrew wisdom tradition.")
        let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")

        XCTAssertThrowsError(try sut.inspect().find(text: "Spiritual Guide"),
                             "the agent's sender name must no longer render as a standalone Text")
        XCTAssertThrowsError(try sut.inspect().find(text: message.formattedTime),
                             "the timestamp must no longer render as a standalone Text")

        // The message body itself must still render.
        XCTAssertNoThrow(try sut.inspect().find(text: "The Logos in John 1 draws on both Greek philosophy and Hebrew wisdom tradition."))
    }

    func test_mineMessage_rendersNoSenderNameOrTimeText() throws {
        let message = makeMessage(mine: true, text: "Thank you, that's helpful.")
        let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")

        XCTAssertThrowsError(try sut.inspect().find(text: "You"),
                             "the user's own sender name ('You') must no longer render as a standalone Text")
        XCTAssertThrowsError(try sut.inspect().find(text: message.formattedTime),
                             "the timestamp must no longer render as a standalone Text")

        XCTAssertNoThrow(try sut.inspect().find(text: "Thank you, that's helpful."))
    }

    func test_agentMessage_accessibilityLabel_stillCarriesSenderIdentity() throws {
        // Q14.2: accessibility wins by default -- sighted users lose the
        // visual row, VoiceOver users must not lose the information.
        let message = makeMessage(mine: false, text: "Consider Psalm 23.")
        let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")

        let root = try sut.inspect().find(ViewType.HStack.self, where: { h in
            (try? h.accessibilityLabel().string()) == "Spiritual Guide: Consider Psalm 23."
        })
        XCTAssertEqual(try root.accessibilityLabel().string(), "Spiritual Guide: Consider Psalm 23.")
    }

    func test_mineMessage_accessibilityLabel_stillCarriesSenderIdentity() throws {
        let message = makeMessage(mine: true, text: "Got it, thanks.")
        let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")

        let root = try sut.inspect().find(ViewType.HStack.self, where: { h in
            (try? h.accessibilityLabel().string()) == "You: Got it, thanks."
        })
        XCTAssertEqual(try root.accessibilityLabel().string(), "You: Got it, thanks.")
    }

    func test_shortMessage_stillRendersUnderWidenedCap_bothDirections() throws {
        // Baseline regression guard: typical short/medium messages (the
        // exact case the prior round's cap-only change failed to visibly
        // affect) must still render correctly post-removal, for both
        // directions.
        for mine in [true, false] {
            let message = makeMessage(mine: mine, text: "Welcome! I'm here to help you study Scripture.")
            let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")
            XCTAssertNoThrow(try sut.inspect().find(text: "Welcome! I'm here to help you study Scripture."),
                             "message text must render for mine=\(mine)")
        }
    }
}
