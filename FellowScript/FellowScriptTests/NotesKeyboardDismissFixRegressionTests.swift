// NotesKeyboardDismissFixRegressionTests.swift — frontend-gate coverage for
// task 20260904-notes-keyboard-dismiss-fix (Lightweight, no testing gate
// ahead of it, so per this codebase's established convention -- see
// 20260903-apple-signin-no-response / MessageComposerKeyboardDismissRegression
// Tests.swift -- the frontend gate writes its own minimal regression test).
//
// Bug: tapping inside NoteEditorView's title TextField or rich-text body, or
// ReplyComposerSheet's reply-body rich-text editor, while it already had
// focus and text, dismissed the keyboard instead of just repositioning the
// cursor. The shared `dismissesKeyboardOnScrollAndTap()` modifier's
// `simultaneousGesture(TapGesture())` fired on any tap anywhere in its
// attached subtree, including on the text-editing control itself.
//
// Unlike the earlier Chat composer fix (task
// 20260903-message-composer-keyboard-dismiss), which worked by reordering
// the modifier ahead of `.safeAreaInset` so the composer sat outside the
// gesture's attached subtree entirely, neither NoteEditorView's title/body
// nor ReplyComposerSheet's reply body has that structural seam -- both
// render as ordinary inline descendants inside the same ScrollView/VStack
// the modifier wraps. So this fix is at the shared modifier's *source*
// instead (Theme.swift, per the Preference profile's Q4/Q5/Q32/Q34
// authorization to fix the real underlying defect rather than each Notes
// screen individually): `dismissesKeyboardOnScrollAndTap()` now wraps a real
// `UITapGestureRecognizer` via `UIGestureRecognizerRepresentable` (iOS 18+,
// within this app's 18.0 deployment floor) instead of a plain SwiftUI
// `TapGesture`, giving it a genuine `UIGestureRecognizerDelegate`. That
// delegate's `shouldReceive touch:` hook inspects the actual UIKit view a
// touch landed on (and its ancestor chain, via the extracted
// `isOrIsNestedInTextInputControl` helper) and declines to recognize the tap
// at all when it landed on/inside a `UITextField`/`UITextView` -- leaving
// that control's own native tap-to-reposition-cursor handling to run
// unopposed. `cancelsTouchesInView = false` plus a
// `shouldRecognizeSimultaneouslyWith` delegate hook returning `true`
// reproduce the previous `.simultaneousGesture`'s "never blocks or steals a
// tap meant for a button/list row underneath it" guarantee.
//
// This generalizes to Chat's already-fixed screens too, with no behavior
// change there: their composer's TextField is already outside this
// gesture's attached subtree via `.safeAreaInset`, so the new text-input
// exclusion is simply never invoked for it -- inert, not a regression. See
// MessageComposerKeyboardDismissRegressionTests.swift, which still passes
// unmodified against ChatThreadView.swift/AgentChatView.swift (untouched by
// this task).
//
// Source-pinned assertions (below) mirror the same "source-text pinning for
// facts ViewInspector can't cheaply assert on" precedent
// InteractionPolishSharedMechanismsTests.swift and
// MessageComposerKeyboardDismissRegressionTests.swift already established
// for this exact modifier, since a SwiftUI/UIKit gesture recognizer's real
// hit-testing region can't be cheaply asserted on by ViewInspector for an
// arbitrary host view. The `isOrIsNestedInTextInputControl` predicate itself
// -- the actual new logic this fix introduces -- IS behaviorally exercised
// below, directly, against real UIKit view instances.

import XCTest
import UIKit
@testable import FellowScript

// MARK: - Behavioral: the extracted text-input-detection predicate

final class IsOrIsNestedInTextInputControlTests: XCTestCase {

    func test_nilView_isNotATextInput() {
        XCTAssertFalse(isOrIsNestedInTextInputControl(nil))
    }

    func test_plainUIView_isNotATextInput() {
        XCTAssertFalse(isOrIsNestedInTextInputControl(UIView()))
    }

    func test_uiTextField_isATextInput() {
        XCTAssertTrue(isOrIsNestedInTextInputControl(UITextField()))
    }

    func test_uiTextView_isATextInput() {
        XCTAssertTrue(isOrIsNestedInTextInputControl(UITextView()))
    }

    /// Mirrors the real-world case this fix exists for: a tap inside
    /// RichTextEditorView's UITextView usually lands on one of the
    /// UITextView's own private internal subviews (e.g. its selection/
    /// content-display view), not the UITextView instance directly -- so the
    /// predicate must walk the full superview ancestor chain, not just check
    /// the touched view alone.
    func test_viewNestedInsideATextView_isATextInput() {
        let textView = UITextView()
        let innerContentView = UIView()
        textView.addSubview(innerContentView)

        XCTAssertTrue(isOrIsNestedInTextInputControl(innerContentView),
                      "a view nested inside a UITextView must count as landing on that text input")
    }

    func test_viewNestedInsideATextField_isATextInput() {
        let textField = UITextField()
        let innerContentView = UIView()
        textField.addSubview(innerContentView)

        XCTAssertTrue(isOrIsNestedInTextInputControl(innerContentView),
                      "a view nested inside a UITextField must count as landing on that text input")
    }

    /// Regression guard: an ordinary sibling view elsewhere on screen (not
    /// nested inside any text-input control) must still resign the keyboard
    /// as before -- this fix must not over-broadly suppress the dismiss tap.
    func test_viewNotNestedInATextInput_isNotATextInput() {
        let container = UIView()
        let textField = UITextField()
        let unrelatedSibling = UIView()
        container.addSubview(textField)
        container.addSubview(unrelatedSibling)

        XCTAssertFalse(isOrIsNestedInTextInputControl(unrelatedSibling),
                       "a sibling view that merely shares an ancestor with a text field, but isn't inside it, must not be treated as a text input")
    }
}

// MARK: - Source-pinned: shared modifier now UIKit-backed, still no plain onTapGesture

final class SharedModifierUIKitBackedTapTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()   // FellowScriptTests/
            .deletingLastPathComponent()   // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_dismissesKeyboardOnScrollAndTap_stillCoversScrollDismiss_andNowUsesUIKitGesture() throws {
        let source = try readSource("FellowScript/Theme/Theme.swift")
        guard let range = source.range(of: "func dismissesKeyboardOnScrollAndTap() -> some View {") else {
            XCTFail("shared keyboard-dismiss modifier not found in Theme.swift")
            return
        }
        let body = String(source[range.upperBound...].prefix(600))

        XCTAssertTrue(body.contains(".scrollDismissesKeyboard(.interactively)"),
                      "scroll-to-dismiss must be unaffected by this fix")
        XCTAssertTrue(body.contains(".gesture(KeyboardResignTapGesture())"),
                      "the tap side must now be the UIKit-backed KeyboardResignTapGesture, not a plain SwiftUI TapGesture")
        XCTAssertFalse(body.contains(".simultaneousGesture(TapGesture()"),
                       "must not still construct a plain SwiftUI TapGesture -- it has no visibility into which UIKit view a tap landed on")
    }

    func test_keyboardResignTapGesture_excludesTextInputControlsAndPreservesSimultaneity() throws {
        let source = try readSource("FellowScript/Theme/Theme.swift")
        guard let structRange = source.range(of: "struct KeyboardResignTapGesture: UIGestureRecognizerRepresentable {") else {
            XCTFail("KeyboardResignTapGesture not found in Theme.swift")
            return
        }
        let structBody = String(source[structRange.upperBound...].prefix(2000))

        XCTAssertTrue(structBody.contains("shouldReceive touch"),
                      "must gate recognition on which UIKit view the touch actually landed on")
        XCTAssertTrue(structBody.contains("isOrIsNestedInTextInputControl"),
                      "must use the shared, directly-tested predicate to exclude text-input controls")
        XCTAssertTrue(structBody.contains("cancelsTouchesInView = false"),
                      "must not swallow touches meant for underlying controls (the prior simultaneousGesture guarantee)")
        XCTAssertTrue(structBody.contains("shouldRecognizeSimultaneouslyWith"),
                      "must allow simultaneous recognition with other gesture recognizers underneath it")
    }
}

// MARK: - Source-pinned: Notes call sites still apply the shared modifier

final class NotesScreensStillUseSharedModifierTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_noteEditorView_stillAppliesSharedModifierExactlyOnce() throws {
        let source = try readSource("FellowScript/Notes/NoteEditorView.swift")
        let count = source.components(separatedBy: ".dismissesKeyboardOnScrollAndTap()").count - 1
        XCTAssertEqual(count, 1,
                       "NoteEditorView must still apply the shared modifier exactly once (covering the title TextField and body RichTextEditorView), not a bespoke per-field workaround")
    }

    func test_notesListView_replyComposerSheet_stillAppliesSharedModifierExactlyOnce() throws {
        let source = try readSource("FellowScript/Notes/NotesListView.swift")
        guard let sheetRange = source.range(of: "private struct ReplyComposerSheet: View {") else {
            XCTFail("ReplyComposerSheet not found in NotesListView.swift")
            return
        }
        let sheetBody = String(source[sheetRange.upperBound...].prefix(12000))
        let count = sheetBody.components(separatedBy: ".dismissesKeyboardOnScrollAndTap()").count - 1
        XCTAssertEqual(count, 1,
                       "ReplyComposerSheet must still apply the shared modifier exactly once (covering the reply body RichTextEditorView), not a bespoke per-field workaround")
    }
}

// MARK: - Regression guard: Chat's already-fixed screens are untouched

final class ChatCallSitesUntouchedByNotesFixTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Chat's own regression coverage (MessageComposerKeyboardDismissRegression
    /// Tests.swift) already re-asserts the modifier-before-safeAreaInset
    /// ordering; this just confirms this task didn't touch either file at
    /// all, since the whole point of fixing Notes at the shared-modifier
    /// level (rather than per-screen) was to leave Chat's structural fix
    /// completely alone.
    func test_chatThreadView_stillOrdersModifierBeforeComposerSafeAreaInset() throws {
        let source = try readSource("FellowScript/Chat/ChatThreadView.swift")
        guard let modifierRange = source.range(of: ".dismissesKeyboardOnScrollAndTap()"),
              let safeAreaInsetRange = source.range(of: ".safeAreaInset(edge: .bottom") else {
            XCTFail("ChatThreadView must still apply the shared modifier before .safeAreaInset(edge: .bottom")
            return
        }
        XCTAssertTrue(modifierRange.lowerBound < safeAreaInsetRange.lowerBound)
    }

    func test_agentChatView_stillOrdersModifierBeforeComposerSafeAreaInset() throws {
        let source = try readSource("FellowScript/Chat/AgentChatView.swift")
        guard let modifierRange = source.range(of: ".dismissesKeyboardOnScrollAndTap()"),
              let safeAreaInsetRange = source.range(of: ".safeAreaInset(edge: .bottom") else {
            XCTFail("AgentChatView must still apply the shared modifier before .safeAreaInset(edge: .bottom")
            return
        }
        XCTAssertTrue(modifierRange.lowerBound < safeAreaInsetRange.lowerBound)
    }
}
