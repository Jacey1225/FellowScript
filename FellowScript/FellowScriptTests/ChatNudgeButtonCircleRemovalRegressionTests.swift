// ChatNudgeButtonCircleRemovalRegressionTests.swift — coverage for task
// 20260923-chat-nudge-button-circle-removal (testing gate, Lightweight
// pipeline's final step after design implemented the change directly).
//
// Proves the specific behaviors this task's design gate implemented against
// the real, shipped Chat/ChatRootView.swift source, so a regression of any
// one of these facts fails here rather than only being caught by a future
// manual screenshot comparison:
//
//   1. ChatNudgeButton no longer constructs either circular backdrop layer
//      (outer gold-gradient Circle, inner dark-fill Circle) or the old
//      Circle-based failed-state error-tint overlay — only the bare glyph
//      (Image/ProgressView) renders now.
//   2. The failed-state signal is re-expressed as a tint directly on the
//      glyph (Theme.error vs. Theme.goldLight), still driven by the same
//      eased (.easeOut(duration: 0.3)) animation as before.
//   3. The 36x36pt tap target is preserved via an invisible frame +
//      contentShape, even though nothing visually draws that size anymore.
//   4. accessibilityLabel content/attachment and the disabled-state rule are
//      unchanged by the chrome removal.
//   5. Icon identity (bell.fill / checkmark / ProgressView) per nudgeState
//      still renders correctly with the chrome gone.
//   6. CheckInRow (Dashboard's distinct sibling control) is untouched.
//
// Follows this project's established two-technique pattern (see
// AgentChatHeaderRemovalRegressionTests.swift): source-text pinning for
// *absent*-modifier / exact-literal facts, and direct ViewInspector hosting
// for live-render facts.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - Shared source reader

private func readChatRootSource(from file: StaticString = #filePath) throws -> String {
    let thisFile = URL(fileURLWithPath: "\(file)")
    let projectFile = thisFile
        .deletingLastPathComponent()          // FellowScriptTests/
        .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
        .appendingPathComponent("FellowScript/Chat/ChatRootView.swift")
    return try String(contentsOf: projectFile, encoding: .utf8)
}

private func readDashboardComponentsSource(from file: StaticString = #filePath) throws -> String {
    let thisFile = URL(fileURLWithPath: "\(file)")
    let projectFile = thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("FellowScript/Dashboard/DashboardComponents.swift")
    return try String(contentsOf: projectFile, encoding: .utf8)
}

private func extractStruct(_ name: String, from source: String) throws -> Substring {
    guard let structRange = source.range(of: "struct \(name): View {") else {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not locate struct \(name) in the real source"])
    }
    let tail = source[structRange.lowerBound...]
    if let nextStruct = tail.range(of: "\nstruct ", range: tail.index(tail.startIndex, offsetBy: 30)..<tail.endIndex) {
        return tail[tail.startIndex..<nextStruct.lowerBound]
    }
    return tail
}

// MARK: - 1/2/3. Source-level: no Circle layers, failed-state re-expressed, tap target preserved

final class ChatNudgeButtonCircleRemovalSourceTests: XCTestCase {

    func test_source_chatNudgeButtonBody_hasNoCircleConstruction() throws {
        let source = try readChatRootSource()
        let body = try extractStruct("ChatNudgeButton", from: source)
        XCTAssertFalse(body.contains("Circle()"),
                       "ChatNudgeButton must no longer construct any Circle — both the outer gold-gradient and inner dark-fill backdrop layers, plus the old failed-state Circle overlay, were removed by this task")
    }

    func test_source_chatNudgeButton_hasNoGoldGradientOrDarkFillReferences() throws {
        let source = try readChatRootSource()
        let body = try extractStruct("ChatNudgeButton", from: source)
        XCTAssertFalse(body.contains("LinearGradient"),
                       "the outer gold-gradient circle backdrop must be gone")
        XCTAssertFalse(body.contains("#24170A"),
                       "the inner dark-fill circle backdrop must be gone")
    }

    func test_source_failedState_reExpressedAsGlyphTint_notCircleOverlay() throws {
        let source = try readChatRootSource()
        let body = try extractStruct("ChatNudgeButton", from: source)
        XCTAssertTrue(body.contains("nudgeState == .failed ? Theme.error : Theme.goldLight"),
                      "the failed-state signal must be a direct foregroundColor tint on the glyph, replacing the removed red Circle().fill(Theme.error...) overlay")

        // Restrict the "old mechanism is really gone" check to the actual
        // `var body` implementation, not the doc comment above it, which
        // legitimately narrates the removed `Theme.error.opacity(...)`
        // overlay in prose as part of explaining this task's change.
        guard let bodyDeclRange = body.range(of: "var body: some View {") else {
            XCTFail("could not locate ChatNudgeButton.body in the real source")
            return
        }
        let bodyImpl = body[bodyDeclRange.lowerBound...]
        XCTAssertFalse(bodyImpl.contains("Theme.error.opacity"),
                       "the old opacity-pulsed Circle overlay's fill expression must be gone from the actual rendered body, not just renamed in a comment")
    }

    func test_source_failedStatePulse_keepsEasedAnimation() throws {
        // Preference profile Q9: motion must stay eased (non-linear), not
        // constant-speed, even after the underlying mechanism changed from a
        // circle overlay to a glyph tint.
        let source = try readChatRootSource()
        let body = try extractStruct("ChatNudgeButton", from: source)
        XCTAssertTrue(body.contains(".animation(.easeOut(duration: 0.3), value: nudgeState)"),
                      "the failed-state flash must keep the same eased .easeOut(duration: 0.3) transition used before the circle removal")
    }

    func test_source_tapTarget_preservedAt36x36_viaInvisibleFrame() throws {
        // The old outer Circle used to both draw the badge AND define the
        // tappable region via its own 36x36pt frame. Once it stops drawing,
        // an equivalent invisible frame + contentShape must still define the
        // same hit area — this is the spec's single hard "must not regress"
        // requirement.
        let source = try readChatRootSource()
        let body = try extractStruct("ChatNudgeButton", from: source)
        XCTAssertTrue(body.contains(".frame(width: 36, height: 36)"),
                      "the invisible tap-target frame must still be 36x36pt, matching the removed outer circle's size")
        XCTAssertTrue(body.contains(".contentShape(Rectangle())"),
                      "contentShape(Rectangle()) must extend the tappable region to fill that invisible frame, not just the glyph's own tiny intrinsic size")
    }

    func test_source_accessibilityLabel_stillAttachedToButton() throws {
        let source = try readChatRootSource()
        let body = try extractStruct("ChatNudgeButton", from: source)
        XCTAssertTrue(body.contains(".accessibilityLabel(accessibilityText)"),
                      "accessibilityLabel must still be attached to the Button after the view hierarchy inside it changed")
    }

    func test_source_disabledRuleAndButtonStylePlain_untouched() throws {
        // Explicitly out of scope: no behavior change, purely visual chrome.
        let source = try readChatRootSource()
        let body = try extractStruct("ChatNudgeButton", from: source)
        XCTAssertTrue(body.contains(".buttonStyle(.plain)"),
                      "the row-level gesture-isolation trick (.buttonStyle(.plain) inside an HStack) must be untouched")
        XCTAssertTrue(body.contains(".disabled(isDisabled)"),
                      "the disabled-state wiring must be untouched")
    }

    func test_source_checkInRow_dashboardSibling_untouched() throws {
        // Out of bounds per intake spec: CheckInRow is a distinct,
        // larger sibling control and must keep its own circular chrome.
        let source = try readDashboardComponentsSource()
        let body = try extractStruct("CheckInRow", from: source)
        XCTAssertTrue(body.contains("Circle()"),
                      "CheckInRow's own circular badge must be untouched by this Chat-scoped task")
    }
}

// MARK: - 4/5. Live render: glyph identity, accessibility, and disabled state still correct

final class ChatNudgeButtonCircleRemovalRenderTests: XCTestCase {

    func test_idleState_rendersBellIcon_enabledAndAccessible() throws {
        let sut = ChatNudgeButton(friendName: "Sam", nudgeState: .idle, onTap: {})
        let image = try sut.inspect().find(ViewType.Image.self)
        XCTAssertEqual(try image.actualImage().name(), "bell.fill")

        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertFalse(try button.isDisabled(), "idle must remain tappable")
        XCTAssertEqual(try button.accessibilityLabel().string(), "Nudge Sam")
    }

    func test_sendingState_rendersProgressView_noImage_disabled() throws {
        let sut = ChatNudgeButton(friendName: "Sam", nudgeState: .sending, onTap: {})
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Image.self),
                             "while sending, the spinner replaces the glyph entirely — no Image should render")
        XCTAssertNoThrow(try sut.inspect().find(ViewType.ProgressView.self))

        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertTrue(try button.isDisabled(), "sending must be locked against re-tap")
    }

    func test_sentState_rendersCheckmark_disabled_withSentAccessibilityText() throws {
        let sut = ChatNudgeButton(friendName: "Sam", nudgeState: .sent, onTap: {})
        let image = try sut.inspect().find(ViewType.Image.self)
        XCTAssertEqual(try image.actualImage().name(), "checkmark")

        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertTrue(try button.isDisabled())
        XCTAssertEqual(try button.accessibilityLabel().string(), "Nudge sent to Sam")
    }

    func test_rateLimitedState_rendersCheckmark_disabled() throws {
        let sut = ChatNudgeButton(friendName: "Sam", nudgeState: .rateLimited, onTap: {})
        let image = try sut.inspect().find(ViewType.Image.self)
        XCTAssertEqual(try image.actualImage().name(), "checkmark")

        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertTrue(try button.isDisabled())
        XCTAssertEqual(try button.accessibilityLabel().string(), "Nudge sent to Sam")
    }

    func test_failedState_rendersBellIcon_stillTappable_forRetry() throws {
        // .failed is the one outcome that must stay tappable (invites an
        // immediate retry) — unchanged by the circle removal.
        let sut = ChatNudgeButton(friendName: "Sam", nudgeState: .failed, onTap: {})
        let image = try sut.inspect().find(ViewType.Image.self)
        XCTAssertEqual(try image.actualImage().name(), "bell.fill")

        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertFalse(try button.isDisabled(), ".failed must remain tappable to invite an immediate retry")
        XCTAssertEqual(try button.accessibilityLabel().string(), "Nudge Sam")
    }

    func test_tap_invokesOnTapClosure_regardlessOfMissingCircleChrome() throws {
        var tapped = false
        let sut = ChatNudgeButton(friendName: "Sam", nudgeState: .idle, onTap: { tapped = true })
        try sut.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(tapped, "tap behavior must be unaffected by the purely visual chrome removal")
    }
}
