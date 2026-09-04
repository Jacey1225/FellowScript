// MessageComposerKeyboardDismissRegressionTests.swift — frontend-gate
// coverage for task 20260903-message-composer-keyboard-dismiss (Lightweight,
// no testing gate ahead of it, so per this codebase's established
// convention -- see 20260903-apple-signin-no-response -- the frontend gate
// writes its own minimal regression test).
//
// Bug: tapping inside the message composer's TextField to reposition the
// cursor mid-text (not to open the keyboard) immediately dismissed the
// keyboard, because `.dismissesKeyboardOnScrollAndTap()` was applied to the
// outer container that also owned the composer via `.safeAreaInset(edge:
// .bottom)`. `.simultaneousGesture(TapGesture())` inside that shared
// modifier fired on any tap anywhere in the attached subtree -- including on
// the TextField itself -- and resigned first responder alongside the
// TextField's own tap-to-position gesture.
//
// Fix: in both ChatThreadView.swift and AgentChatView.swift, the shared
// modifier is now applied to the inner VStack (header/banners/message list)
// BEFORE `.safeAreaInset` adds the composer, rather than to the outer ZStack
// after the composer already exists in the subtree. `.safeAreaInset`'s
// content is laid out as a sibling to the view it's chained onto, not a
// descendant of it, so a `.simultaneousGesture` attached earlier in the
// chain never receives touches landing inside the composer. This mirrors the
// source-pinning approach InteractionPolishSharedMechanismsTests.swift
// already established for this exact modifier, since a SwiftUI
// simultaneousGesture's hit-testing region can't be cheaply asserted on by
// ViewInspector for an arbitrary host view.
//
// The shared modifier itself (Theme.swift) is untouched by this fix -- scope
// was narrowed to just these two Chat call sites (Preference profile's
// explicitly-sanctioned alternative) so the other five call sites sharing
// the same latent pattern (ChatRootView's search field, AddFriendSheet,
// AddGroupSheet, ReportUserSheet) are provably unaffected: this file doesn't
// touch them, and InteractionPolishSharedMechanismsTests.swift's own
// source-pinned assertions against Theme.swift's implementation still pass
// unmodified.

import XCTest
@testable import FellowScript

final class MessageComposerKeyboardDismissRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()   // FellowScriptTests/
            .deletingLastPathComponent()   // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Asserts the shared keyboard-dismiss modifier's call site now appears
    /// BEFORE the `.safeAreaInset(edge: .bottom` that introduces the
    /// composer, so the composer's TextField sits outside the modifier's
    /// gesture-attached subtree.
    private func assertModifierPrecedesComposerSafeAreaInset(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let source = try readSource(relativePath)

        guard let modifierRange = source.range(of: ".dismissesKeyboardOnScrollAndTap()") else {
            XCTFail("\(relativePath) must still apply the shared keyboard-dismiss convention", file: file, line: line)
            return
        }
        guard let safeAreaInsetRange = source.range(of: ".safeAreaInset(edge: .bottom") else {
            XCTFail("\(relativePath) must still render the composer via .safeAreaInset(edge: .bottom", file: file, line: line)
            return
        }

        XCTAssertTrue(
            modifierRange.lowerBound < safeAreaInsetRange.lowerBound,
            "\(relativePath): .dismissesKeyboardOnScrollAndTap() must be applied BEFORE .safeAreaInset(edge: .bottom) adds the composer -- otherwise the composer's TextField is inside the modifier's gesture-attached subtree and tapping it to reposition the cursor dismisses the keyboard instead (the reported bug)",
            file: file, line: line
        )
    }

    func test_chatThreadView_modifierScopedAheadOfComposerSafeAreaInset() throws {
        try assertModifierPrecedesComposerSafeAreaInset("FellowScript/Chat/ChatThreadView.swift")
    }

    func test_agentChatView_modifierScopedAheadOfComposerSafeAreaInset() throws {
        try assertModifierPrecedesComposerSafeAreaInset("FellowScript/Chat/AgentChatView.swift")
    }

    /// Regression guard: the fix must not have removed
    /// `.scrollDismissesKeyboard(.interactively)` coverage of the message
    /// list -- that behavior rides along inside the same shared modifier
    /// call, just relocated earlier in the chain, and must still exist
    /// exactly once per screen.
    func test_scrollDismissesKeyboardStillAppliedExactlyOnceViaSharedModifier() throws {
        for relativePath in ["FellowScript/Chat/ChatThreadView.swift", "FellowScript/Chat/AgentChatView.swift"] {
            let source = try readSource(relativePath)
            let modifierCallCount = source.components(separatedBy: ".dismissesKeyboardOnScrollAndTap()").count - 1
            XCTAssertEqual(modifierCallCount, 1,
                           "\(relativePath) must call the shared modifier exactly once, not add a second bespoke .scrollDismissesKeyboard call site")
            XCTAssertFalse(source.contains(".scrollDismissesKeyboard(.immediately)") || source.contains(".scrollDismissesKeyboard(.never)"),
                           "\(relativePath) must not have gained a conflicting bespoke scroll-dismiss policy")
        }
    }
}
