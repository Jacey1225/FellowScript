// AgentChatBubbleRemovalRegressionTests.swift — coverage for task
// 20260830-agent-chat-bubble-removal (testing gate).
//
// Proves the specific behavior this task's frontend gate implemented against
// the real, shipped Chat/AgentChatView.swift source, so a regression of any
// one of these facts fails here rather than only being caught by a future
// manual screenshot comparison:
//
//   1. AgentMessageBubble's `mine` branch keeps its full bubble chrome
//      (gold-tinted fill, stroke, corner-radius clip, top-edge highlight)
//      byte-for-byte unchanged.
//   2. The `!mine` (agent-response) branch has NONE of that chrome -- no
//      background, no overlay/stroke, no clipShape, no topEdgeHighlight --
//      only the alignment-preserving padding survives.
//   3. The 0.78-screen-width max-width wrap constraint is applied exactly
//      once, to the Group wrapping both branches, so both sides still wrap
//      at the same readable width even though only one side has a visual
//      container implying a boundary.
//   4. TypingIndicator's own background is untouched (explicitly out of
//      scope per the intake spec).
//   5. Both branches still render their message text and accessibility
//      label live (no regression to MarkdownBodyView rendering/parsing or
//      the AgentMessageBubble accessibility contract).
//   6. Agent-response text contrast against the actual worst-case rendered
//      background (Theme.bgPage blended with both ambient RadialGradient
//      washes stacked) is computed from the real Theme token values at test
//      time and asserted to clear the WCAG AA floor (4.5:1) for normal-size
//      text -- so a future change to any of these tokens that regresses
//      contrast (this app's own recent precedent, see
//      20260830-bible-nav-dropdown-blur) fails here rather than only
//      surfacing in a live screenshot.
//
// AgentMessageBubble takes no EnvironmentObject and performs no network/
// socket work, so items 1-5 use this project's two established techniques
// side by side: source-text pinning for *absent*-modifier facts ViewInspector
// can't cheaply assert on (see EmberGlassFidelityPassRegressionTests.swift's
// SenderGroupDividerRemovalRegressionTests / BibleReaderConsistencyRegressionTests.swift),
// and direct ViewInspector hosting for live-render facts (see
// ChatScheduleUICleanupIOSRegressionTests.swift's SessionCreatorSheet tests).

import XCTest
import SwiftUI
import UIKit
import ViewInspector
@testable import FellowScript

// MARK: - 1/2/3/4. Source-level chrome presence/absence

final class AgentChatBubbleRemovalSourceTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_source_mineBranch_keepsFullBubbleChrome() throws {
        let source = try readSource("FellowScript/Chat/AgentChatView.swift")
        guard let ifRange = source.range(of: "if message.mine {"),
              let elseRange = source.range(of: "} else {", range: ifRange.upperBound..<source.endIndex) else {
            XCTFail("could not locate AgentMessageBubble's mine/else branches in the real source")
            return
        }
        let mineBlock = String(source[ifRange.upperBound..<elseRange.lowerBound])

        XCTAssertTrue(mineBlock.contains(".background(Theme.gold.opacity(0.18))"),
                      "the user's own outgoing bubble must keep its exact gold-tinted fill")
        XCTAssertTrue(mineBlock.contains(".stroke(Theme.borderGoldDim, lineWidth: 1)"),
                      "the user's own outgoing bubble must keep its exact stroke")
        XCTAssertTrue(mineBlock.contains(".clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))"),
                      "the user's own outgoing bubble must keep its exact corner-radius clip")
        XCTAssertTrue(mineBlock.contains(".topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusLG))"),
                      "the user's own outgoing bubble must keep its exact top-edge highlight")
    }

    func test_source_agentBranch_hasNoBubbleChrome() throws {
        let source = try readSource("FellowScript/Chat/AgentChatView.swift")
        guard let elseRange = source.range(of: "} else {"),
              let frameRange = source.range(
                of: ".frame(maxWidth: UIScreen.main.bounds.width * 0.78",
                range: elseRange.upperBound..<source.endIndex
              ) else {
            XCTFail("could not locate AgentMessageBubble's else branch / shared frame modifier in the real source")
            return
        }
        let agentBlock = String(source[elseRange.upperBound..<frameRange.lowerBound])

        XCTAssertFalse(agentBlock.contains(".background("),
                       "agent response text must have no fill background behind it")
        XCTAssertFalse(agentBlock.contains(".overlay("),
                       "agent response text must have no border/stroke overlay behind it")
        XCTAssertFalse(agentBlock.contains(".clipShape("),
                       "agent response text must have no corner-radius clip shape")
        XCTAssertFalse(agentBlock.contains(".topEdgeHighlight("),
                       "agent response text must have no edge-highlight chrome")

        // Alignment-preserving padding must still be present so the text
        // still lines up with the sender-name/time row above it.
        XCTAssertTrue(agentBlock.contains(".padding(.horizontal, Theme.spacingMD)"),
                      "agent response text must keep its horizontal padding for row alignment")
        XCTAssertTrue(agentBlock.contains(".padding(.vertical, Theme.spacingSM)"),
                      "agent response text must keep its vertical padding for row alignment")
    }

    func test_source_maxWidthWrapping_isSharedAcrossBothBranches() throws {
        let source = try readSource("FellowScript/Chat/AgentChatView.swift")
        let marker = ".frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: message.mine ? .trailing : .leading)"
        let occurrences = source.components(separatedBy: marker).count - 1
        XCTAssertEqual(
            occurrences, 1,
            "the 0.78-screen-width wrap constraint must be applied exactly once, to the shared Group " +
            "wrapping both branches -- otherwise agent text (which has no visual container implying a " +
            "boundary) could regress to spanning the full screen edge-to-edge"
        )
    }

    func test_source_typingIndicator_backgroundUntouched() throws {
        let source = try readSource("FellowScript/Chat/AgentChatView.swift")
        XCTAssertTrue(
            source.contains(".background(Color.white.opacity(0.05))"),
            "TypingIndicator's own background is explicitly out of scope for this task (it isn't itself " +
            "an agent response) and must remain untouched"
        )
    }

    // Pins the exact ambient wash color/opacity literals the contrast test
    // below relies on, so if either wash's color or opacity is ever changed,
    // this test fails and points a maintainer at the contrast test that
    // needs updating alongside it.
    func test_source_ambientWashColors_matchContrastTestAssumptions() throws {
        let source = try readSource("FellowScript/Chat/AgentChatView.swift")
        XCTAssertTrue(source.contains("Color(hex: \"#D4922A\").opacity(0.20)"),
                      "expected the first ambient RadialGradient wash's exact color/opacity")
        XCTAssertTrue(source.contains("Color(hex: \"#B8761D\").opacity(0.12)"),
                      "expected the second ambient RadialGradient wash's exact color/opacity")
    }
}

// MARK: - 5. Live render: both sides still render text + accessibility label

final class AgentMessageBubbleRenderTests: XCTestCase {

    private func makeMessage(mine: Bool, text: String = "Consider Psalm 23.") -> FSAgentMessage {
        FSAgentMessage(id: UUID().uuidString, text: text, mine: mine, timestamp: "")
    }

    func test_agentMessage_rendersTextAndAccessibilityLabel() throws {
        let message = makeMessage(mine: false, text: "Consider Psalm 23.")
        let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")

        XCTAssertNoThrow(try sut.inspect().find(text: "Consider Psalm 23."),
                          "agent response text must still render after the bubble chrome removal")
        XCTAssertNoThrow(try sut.inspect().find(text: "Spiritual Guide"),
                          "the agent's sender name row must still render")

        let root = try sut.inspect().find(ViewType.HStack.self, where: { h in
            (try? h.accessibilityLabel().string()) == "Spiritual Guide: Consider Psalm 23."
        })
        XCTAssertEqual(try root.accessibilityLabel().string(), "Spiritual Guide: Consider Psalm 23.",
                       "the combined accessibility label contract must survive the visual-only change")
    }

    func test_mineMessage_rendersTextAndAccessibilityLabel() throws {
        let message = makeMessage(mine: true, text: "Thank you.")
        let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")

        XCTAssertNoThrow(try sut.inspect().find(text: "Thank you."),
                          "the user's own outgoing text must still render")
        XCTAssertNoThrow(try sut.inspect().find(text: "You"),
                          "the user's own sender-name row must still read \"You\", unchanged")

        let root = try sut.inspect().find(ViewType.HStack.self, where: { h in
            (try? h.accessibilityLabel().string()) == "You: Thank you."
        })
        XCTAssertEqual(try root.accessibilityLabel().string(), "You: Thank you.",
                       "the combined accessibility label contract must survive the visual-only change")
    }
}

// MARK: - 6. Contrast: agent text vs. worst-case rendered ambient background

final class AgentChatBubbleRemovalContrastTests: XCTestCase {

    private func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    // Simple over-compositing of a translucent foreground onto an opaque
    // background, matching how SwiftUI actually renders a `.opacity()`
    // color/wash stacked on top of another color.
    private func blend(fg: (r: Double, g: Double, b: Double, a: Double), overBg bg: (r: Double, g: Double, b: Double, a: Double)) -> (r: Double, g: Double, b: Double) {
        (
            fg.r * fg.a + bg.r * (1 - fg.a),
            fg.g * fg.a + bg.g * (1 - fg.a),
            fg.b * fg.a + bg.b * (1 - fg.a)
        )
    }

    private func relativeLuminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrastRatio(_ c1: (r: Double, g: Double, b: Double), _ c2: (r: Double, g: Double, b: Double)) -> Double {
        let l1 = relativeLuminance(c1), l2 = relativeLuminance(c2)
        let (lighter, darker) = l1 >= l2 ? (l1, l2) : (l2, l1)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func test_agentResponseText_worstCaseStackedWashBackground_clearsAAContrastFloor() throws {
        // Matches AgentChatView.body's real background stack: Theme.bgPage,
        // then both ambient RadialGradient washes at their own brightest
        // point, stacked (a strictly worse case than either wash alone, and
        // worse than their real non-overlapping centers ever actually
        // produce), then the exact agent-branch text color MarkdownBodyView
        // uses for `isMine: false` (Theme.parchment at 0.90 opacity).
        let bgPage = rgba(Theme.bgPage)
        let wash1  = rgba(Color(hex: "#D4922A").opacity(0.20))
        let wash2  = rgba(Color(hex: "#B8761D").opacity(0.12))
        let text   = rgba(Theme.parchment.opacity(0.90))

        let bgAfterWash1 = blend(fg: wash1, overBg: (bgPage.r, bgPage.g, bgPage.b, 1))
        let worstCaseBg  = blend(fg: wash2, overBg: (bgAfterWash1.r, bgAfterWash1.g, bgAfterWash1.b, 1))
        let renderedText = blend(fg: text, overBg: (worstCaseBg.r, worstCaseBg.g, worstCaseBg.b, 1))

        let ratio = contrastRatio(renderedText, worstCaseBg)

        XCTAssertGreaterThanOrEqual(
            ratio, 4.5,
            "agent response text (now with no bubble backing) must clear the WCAG AA floor (4.5:1 for " +
            "normal-size text) even against the worst-case stacked ambient background, per this app's " +
            "own recent precedent (20260830-bible-nav-dropdown-blur) of a contrast regression appearing " +
            "exactly when a solid backing was removed from behind text; measured ratio: \(ratio)"
        )
    }

    func test_mineMessageText_stillRendersOverItsOwnBubbleFill_forComparison() throws {
        // Sanity check that the "mine" side's own unchanged bubble fill
        // still clears AA too, so this test file documents both sides'
        // contrast rather than only the one that changed.
        let bubbleFill = rgba(Theme.gold.opacity(0.18))
        let bgPage      = rgba(Theme.bgPage)
        let text        = rgba(Theme.parchment)

        let renderedBubbleBg = blend(fg: bubbleFill, overBg: (bgPage.r, bgPage.g, bgPage.b, 1))
        let renderedText     = blend(fg: text, overBg: (renderedBubbleBg.r, renderedBubbleBg.g, renderedBubbleBg.b, 1))

        let ratio = contrastRatio(renderedText, renderedBubbleBg)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "the unchanged mine-side bubble must remain AA-compliant too; measured ratio: \(ratio)")
    }
}
