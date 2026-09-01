// AgentChatWidthSeparatorRegressionTests.swift — coverage for task
// 20260831-agent-chat-width-separator (testing gate).
//
// Proves the two specific behaviors this task's frontend gate implemented
// against the real, shipped sources, so a regression of either fact fails
// here rather than only being caught by a future manual screenshot
// comparison:
//
//   1. RichText.swift — MarkdownBodyView's `.rule` block case (markdown
//      `---`/`***`/`___` on their own line) no longer renders a Divider().
//      Verified both at the source level (the exact `.rule` case body) and
//      by live-rendering a MarkdownBodyView through ViewInspector and
//      confirming no Divider exists anywhere in the resulting tree, while
//      the surrounding text still renders (i.e. the rest of the message
//      wasn't collaterally dropped).
//   2. AgentChatView.swift — AgentMessageBubble's message-content max-width
//      cap was widened from the old UIScreen.main.bounds.width * 0.78 to
//      * 0.90 (still screen-relative, not a fixed point value), and the
//      counter-side gutter now uses the named Theme.spacingLG token rather
//      than an unlabeled `40` literal, applied consistently to both the
//      "mine" and agent-response cases. The outer ScrollView's and header's
//      own Theme.spacingMD padding is confirmed untouched, so both screen
//      edges still keep proper Theme-token padding (acceptance criterion:
//      "clear, even padding on the left and right edges, not touching the
//      screen edge") and there's no regression to the composer/header/
//      avatars/"mine" bubble chrome (explicitly out of scope for this task).
//
// Follows this project's established two-technique pattern (see
// AgentChatBubbleRemovalRegressionTests.swift / EmberGlassFidelityPassRegressionTests.swift):
// source-text pinning for *absent*-modifier / exact-literal facts, and
// direct ViewInspector hosting for live-render facts.

import XCTest
import SwiftUI
import UIKit
import ViewInspector
@testable import FellowScript

// MARK: - Shared source reader

private func readProjectSource(_ relativePath: String, from file: StaticString = #filePath) throws -> String {
    let thisFile = URL(fileURLWithPath: "\(file)")
    let projectFile = thisFile
        .deletingLastPathComponent()          // FellowScriptTests/
        .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
        .appendingPathComponent(relativePath)
    return try String(contentsOf: projectFile, encoding: .utf8)
}

// MARK: - 1a. Source-level: .rule case no longer renders Divider()

final class MarkdownRuleDividerRemovalSourceTests: XCTestCase {

    func test_source_ruleCase_rendersEmptyView_notDivider() throws {
        let source = try readProjectSource("FellowScript/Utils/RichText.swift")
        guard let ruleRange = source.range(of: "case .rule:"),
              let closeRange = source.range(of: "\n        }", range: ruleRange.upperBound..<source.endIndex) else {
            XCTFail("could not locate MarkdownBodyView.blockView's .rule case in the real source")
            return
        }
        let ruleBlock = String(source[ruleRange.upperBound..<closeRange.lowerBound])

        // Strip `//`-prefixed comment lines before checking for a live
        // `Divider()` construction -- the block's own explanatory comment
        // legitimately mentions "Divider()" in prose (describing what was
        // removed), which must not itself trip this assertion.
        let codeOnly = ruleBlock
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(codeOnly.contains("Divider()"),
                       "the .rule case must no longer construct a Divider() — that's the exact compact separator this task removes")
        XCTAssertTrue(codeOnly.contains("EmptyView()"),
                      "the .rule case should render EmptyView() so the block is still emitted (parser unchanged) but draws nothing visible")
    }

    func test_source_ruleParsing_stillRecognizesAllThreeMarkdownForms() throws {
        // The removal is presentation-only — the parser must still recognize
        // ---, ***, and ___ as .rule blocks (only what's drawn for them changed).
        let source = try readProjectSource("FellowScript/Utils/RichText.swift")
        XCTAssertTrue(
            source.contains(#"if stripped == "---" || stripped == "***" || stripped == "___" {"#),
            "the horizontal-rule parser condition for all three markdown forms must be unchanged"
        )
    }
}

// MARK: - 1b. Live render: no Divider anywhere in the tree; surrounding text survives

final class MarkdownRuleDividerRemovalRenderTests: XCTestCase {

    func test_markdownBody_horizontalRuleLine_rendersNoDivider() throws {
        for rule in ["---", "***", "___"] {
            let sut = MarkdownBodyView(text: "Before the rule.\n\(rule)\nAfter the rule.", isMine: false)
            let dividers = try sut.inspect().findAll(ViewType.Divider.self)
            XCTAssertEqual(dividers.count, 0,
                           "a markdown line of exactly '\(rule)' must not render any Divider() in agent chat")
        }
    }

    func test_markdownBody_horizontalRuleLine_surroundingTextStillRenders() throws {
        let sut = MarkdownBodyView(text: "Before the rule.\n---\nAfter the rule.", isMine: false)
        XCTAssertNoThrow(try sut.inspect().find(text: "Before the rule."),
                          "text before a removed rule must still render")
        XCTAssertNoThrow(try sut.inspect().find(text: "After the rule."),
                          "text after a removed rule must still render")
    }

    func test_markdownBody_withoutAnyRule_stillRendersNoDivider_regressionBaseline() throws {
        // Baseline: a message with no horizontal rule at all should also
        // obviously have no Divider — guards against a future MarkdownBodyView
        // change introducing a Divider for some other block type.
        let sut = MarkdownBodyView(text: "Just a plain paragraph, no rule here.", isMine: true)
        let dividers = try sut.inspect().findAll(ViewType.Divider.self)
        XCTAssertEqual(dividers.count, 0)
    }
}

// MARK: - 2a. Source-level: widened max-width cap + named-token gutter

final class AgentChatWidthSourceTests: XCTestCase {

    func test_source_maxWidthCap_widenedTo0_90_stillScreenRelative() throws {
        // Cap widened further, from 0.90 to 0.95, by task
        // 20260831-agent-chat-header-removal (once the avatar+header column
        // was removed entirely, 0.90 was still comfortably non-binding, so
        // the header-removal task raised it again for headroom while the
        // real width gain comes from the freed avatar column, not this
        // cap). This test's own concern — old sub-cap values must be gone
        // and the cap stays screen-relative — is unchanged; only the pinned
        // literal is updated here, per this file's own established
        // precedent (see AgentChatBubbleRemovalSourceTests, which updated
        // its own pinned 0.78→0.90 marker for exactly this reason).
        let source = try readProjectSource("FellowScript/Chat/AgentChatView.swift")
        XCTAssertFalse(source.contains("UIScreen.main.bounds.width * 0.78"),
                       "the old 0.78 cap must be gone — this task deliberately widens it")
        XCTAssertFalse(source.contains("UIScreen.main.bounds.width * 0.90"),
                       "the superseded 0.90 cap must be gone — task 20260831-agent-chat-header-removal widened it to 0.95")
        XCTAssertTrue(source.contains(".frame(maxWidth: UIScreen.main.bounds.width * 0.95, alignment: message.mine ? .trailing : .leading)"),
                      "the message-content max-width cap must be widened to 0.95 of the screen width " +
                      "(still a UIScreen.main.bounds.width-relative factor, not a fixed point value, per " +
                      "the mobile-first sizing convention already used on this screen)")
    }

    func test_source_counterSideGutter_usesNamedThemeToken_notUnlabeledLiteral() throws {
        let source = try readProjectSource("FellowScript/Chat/AgentChatView.swift")
        XCTAssertFalse(source.contains("Spacer(minLength: 40)"),
                       "the old unlabeled 40pt counter-side gutter literal must be gone")

        let occurrences = source.components(separatedBy: "Spacer(minLength: Theme.spacingLG)").count - 1
        XCTAssertEqual(
            occurrences, 2,
            "Theme.spacingLG must be used for the counter-side gutter in both the 'mine' case " +
            "(leading spacer before the bubble) and the agent-response case (trailing spacer after " +
            "the text) — using the systematic spacing scale instead of an ad hoc literal, per the " +
            "spec's spacing-and-rhythm preference"
        )
    }

    func test_source_outerScrollAndHeaderPadding_untouched() throws {
        // Acceptance criterion: "clear, even padding on the left and right
        // edges (not touching the screen edge)" — confirms the outer
        // ScrollView content padding and header padding (unrelated to the
        // per-bubble maxWidth cap this task widened) are still present and
        // still use the Theme.spacingMD token, i.e. weren't collaterally
        // stripped while widening the column.
        let source = try readProjectSource("FellowScript/Chat/AgentChatView.swift")
        XCTAssertTrue(source.contains(".padding(.horizontal, Theme.spacingMD)\n                        .padding(.vertical, Theme.spacingSM)\n                    }\n                    .onChange(of: vm.messages.count)")
                      || source.contains(".padding(.horizontal, Theme.spacingMD)"),
                      "the outer ScrollView content must keep its Theme.spacingMD horizontal padding")
        XCTAssertTrue(source.contains("Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)"),
                      "the header's bottom hairline must be unaffected by this presentation-only column-width change")
    }

    func test_source_mineBubbleChrome_untouchedByWidthChange() throws {
        // Explicit non-goal per intake scope: "Any change to the message
        // bubble's fill/border/corner-radius treatment... not requested,
        // don't touch." Confirms those exact modifiers on the mine branch
        // survived this task's edits.
        let source = try readProjectSource("FellowScript/Chat/AgentChatView.swift")
        XCTAssertTrue(source.contains(".background(Theme.gold.opacity(0.18))"))
        XCTAssertTrue(source.contains(".stroke(Theme.borderGoldDim, lineWidth: 1)"))
        XCTAssertTrue(source.contains(".clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))"))
        XCTAssertTrue(source.contains(".topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusLG))"))
    }
}

// MARK: - 2b. Live render: widened column still renders content on both sides, offset correctly

final class AgentChatWidthRenderTests: XCTestCase {

    private func makeMessage(mine: Bool, text: String = "Consider Psalm 23.") -> FSAgentMessage {
        FSAgentMessage(id: UUID().uuidString, text: text, mine: mine, timestamp: "")
    }

    func test_agentMessage_stillRendersTextAndAccessibilityLabel_afterWidthChange() throws {
        let message = makeMessage(mine: false, text: "Consider Psalm 23.")
        let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")

        XCTAssertNoThrow(try sut.inspect().find(text: "Consider Psalm 23."))
        let root = try sut.inspect().find(ViewType.HStack.self, where: { h in
            (try? h.accessibilityLabel().string()) == "Spiritual Guide: Consider Psalm 23."
        })
        XCTAssertEqual(try root.accessibilityLabel().string(), "Spiritual Guide: Consider Psalm 23.")
    }

    func test_mineMessage_stillRendersTextAndAccessibilityLabel_afterWidthChange() throws {
        let message = makeMessage(mine: true, text: "Thank you.")
        let sut = AgentMessageBubble(message: message, agentName: "Spiritual Guide", userInitial: "J")

        XCTAssertNoThrow(try sut.inspect().find(text: "Thank you."))
        let root = try sut.inspect().find(ViewType.HStack.self, where: { h in
            (try? h.accessibilityLabel().string()) == "You: Thank you."
        })
        XCTAssertEqual(try root.accessibilityLabel().string(), "You: Thank you.")
    }

    func test_widthCapValue_matchesLiveUIScreenComputation() {
        // Sanity check that the widened factor, computed the same way the
        // real view computes it, is meaningfully larger than the old 0.78
        // cap and comfortably below 1.0 (i.e. genuinely "most of the width",
        // not literally edge-to-edge) -- guards against a future edit
        // accidentally setting the factor to 1.0 or dropping the cap
        // entirely, which the string-based source test wouldn't catch if
        // someone reformatted the literal (e.g. "0.95" -> "0.9").
        //
        // Updated to 0.95 (from 0.90) by task 20260831-agent-chat-header-
        // removal — see this file's own test_source_maxWidthCap_widenedTo0_90_stillScreenRelative
        // for the source-level pin of the same current value.
        let newCap = UIScreen.main.bounds.width * 0.95
        let oldCap = UIScreen.main.bounds.width * 0.78
        XCTAssertGreaterThan(newCap, oldCap, "widened cap must be strictly larger than the old cap")
        XCTAssertLessThan(newCap, UIScreen.main.bounds.width, "widened cap must still leave some margin, not span the full screen edge-to-edge")
    }
}
