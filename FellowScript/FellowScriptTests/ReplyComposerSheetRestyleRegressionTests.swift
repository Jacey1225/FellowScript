// ReplyComposerSheetRestyleRegressionTests.swift — testing-gate coverage for
// task 20260903-notes-reply-submenu-restyle.
//
// The frontend gate migrated ReplyComposerSheet (NotesListView.swift) off its
// plain Form/Section layout onto the same warm-bloom-ground + widgetCard() +
// ghost-chip-Cancel/gold-PillButton-Post recipe already established for
// AddFriendSheet/EventSetupSheet by the 20260902-submenu-visual-redesign and
// 20260902-submenu-followup-polish tasks. ReplyComposerSheet is `private` to
// NotesListView.swift, so — following this project's own established
// technique for this exact class of task (see
// SubmenuVisualRedesignRegressionTests.swift and
// SubmenuFollowupPolishRegressionTests.swift, the direct predecessors, and
// NoteReplySectionTests.swift's own `componentSource()` helper for this same
// file) — this pins the relevant render-tree/behavior facts by reading the
// real shipped source directly rather than hosting the private struct.
//
// This file proves:
//   A. Visual migration: warmBloomBackground(), widgetCard()-wrapped field,
//      ghost-chip Cancel, gold PillButton Post, and a `.principal` centered
//      title — replacing the old Form/Section + plain-text Cancel/Post.
//   B. No behavioral regression: onPost/postReplyDraft wiring, canPost
//      gating (non-empty trimmed text AND not already posting), the
//      "Posting…" in-progress label, inline errorMessage display without
//      dismissing on failure, dismiss()-on-success, and the pre-existing
//      .dismissesKeyboardOnScrollAndTap()/.preferredColorScheme(.dark)
//      modifiers are all still present and unchanged.
//   C. Reply list display (replyCard) and postReplyDraft's own posting logic
//      are untouched by this restyle (out-of-scope guard).

import XCTest
import SwiftUI
@testable import FellowScript

final class ReplyComposerSheetRestyleRegressionTests: XCTestCase {

    private func componentSource() throws -> String {
        let componentFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Notes/NotesListView.swift")
        return try String(contentsOf: componentFile, encoding: .utf8)
    }

    private func sheetBody(_ source: String) throws -> String {
        guard let start = source.range(of: "private struct ReplyComposerSheet: View {") else {
            XCTFail("ReplyComposerSheet not found")
            return ""
        }
        // The struct is the last declaration in the file, so its own closing
        // brace is the end of the source.
        return String(source[start.upperBound...])
    }

    // MARK: - A. Visual migration onto the established submenu-sheet recipe

    func test_usesWarmBloomBackground_notFlatBgPage() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertTrue(body.contains(".warmBloomBackground()"),
                      "ReplyComposerSheet must render on the shared warm-bloom-ground background")
        XCTAssertFalse(body.contains("Theme.bgPage"),
                       "the old flat Theme.bgPage fill must be gone")
    }

    func test_replyFieldIsWrappedInWidgetCard_notFormSection() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertFalse(body.contains("Form {"), "must no longer use a plain Form")
        XCTAssertFalse(body.contains(#"Section("Reply")"#), "must no longer use a plain Form Section")
        XCTAssertTrue(body.contains(".widgetCard()"),
                      "the reply field must be wrapped in the shared widgetCard() card recipe")
        XCTAssertTrue(body.contains("TextEditor(text: $text)"),
                      "the reply TextEditor binding must be preserved verbatim")
        XCTAssertTrue(body.contains("Theme.textGoldMuted"),
                      "the field's section-label caption must use the established gold-muted caption color, matching AddFriendSheet's shape")
    }

    func test_cancelIsGhostChip_notPlainButton() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertFalse(body.contains(#"Button("Cancel")"#),
                       "must no longer use a plain string-literal Button(\"Cancel\") (picks up unstyled system Liquid Glass chrome)")
        XCTAssertTrue(body.contains("cancelGhostChip"),
                      "must use a ghost-chip Cancel label, matching EventSetupSheet's per-file-copy convention")
        XCTAssertTrue(body.contains("Button(action: { dismiss() }) { cancelGhostChip }"),
                      "Cancel must still call dismiss()")
        XCTAssertTrue(body.contains("Capsule().fill(Theme.parchment.opacity(0.06))"))
        XCTAssertTrue(body.contains("Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1)"))
    }

    func test_postUsesPillButton_notPlainButton() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertFalse(body.contains(#"Button("Post")"#),
                       "must no longer use a plain string-literal Button(\"Post\")")
        XCTAssertTrue(body.contains("PillButton(title: isPosting ? \"Posting…\" : \"Post\")"),
                      "Post must use the shared gold-gradient PillButton recipe and keep the in-progress label swap")
    }

    func test_toolbarItemsSuppressAutomaticGlassChrome() throws {
        let body = try sheetBody(try componentSource())
        // Both custom ToolbarItems (leading Cancel, trailing Post) must carry
        // the modifier so iOS 26's automatic Liquid Glass chrome doesn't
        // double up against each item's own capsule/pill chrome — the same
        // fix already applied to the other four sheets. Strip `//` line
        // comments first (this file's own doc comment narrates the fix by
        // name), matching NoteReplySectionTests.swift's established
        // technique, so only live code references are counted.
        let codeOnly = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let range = line.range(of: "//") { return line[..<range.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        let occurrences = codeOnly.components(separatedBy: ".suppressAutomaticGlassChrome()").count - 1
        XCTAssertEqual(occurrences, 2,
                       "both the Cancel and Post ToolbarItems must carry .suppressAutomaticGlassChrome(), got \(occurrences) occurrence(s)")
    }

    func test_hasPrincipalTitleItem_decoupledFromToolbarWidths() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertTrue(body.contains("ToolbarItem(placement: .principal)"),
                      "\"Add a Reply\" must center via a `.principal` toolbar item, independent of the asymmetric Cancel/Post widths -- the exact shape that caused visible off-centering on the other four sheets")
        XCTAssertTrue(body.contains(#"Text("Add a Reply")"#),
                      "the `.principal` item must render the sheet's actual title text")
    }

    // MARK: - B. No behavioral regression

    func test_onPostWiring_stillCalledWithComposedText() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertTrue(body.contains("let onPost: (String) async -> String?"),
                      "the onPost closure's signature must be unchanged")
        XCTAssertTrue(body.contains("errorMessage = await onPost(text)"),
                      "Post must still invoke onPost with the composed reply text and capture its result as errorMessage")
    }

    func test_canPostGating_nonEmptyTrimmedTextAndNotAlreadyPosting() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertTrue(body.contains("!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting"),
                      "canPost must still require non-empty trimmed text AND that a post isn't already in flight")
        XCTAssertTrue(body.contains(".disabled(!canPost)"),
                      "the Post PillButton must still be disabled whenever canPost is false")
    }

    func test_postingState_setsFlagAroundAwaitAndShowsInProgressLabel() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertTrue(body.contains("isPosting = true"))
        XCTAssertTrue(body.contains("isPosting = false"))
        XCTAssertTrue(body.contains(#"isPosting ? "Posting…" : "Post""#),
                      "the Post pill must swap to a 'Posting…' label while a post is in flight")
        XCTAssertTrue(body.contains(".disabled(isPosting)"),
                      "Cancel must be disabled while a post is in flight, unchanged from before the restyle")
    }

    func test_errorMessage_surfacesInlineWithoutDismissing_successDismisses() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertTrue(body.contains("if errorMessage == nil { dismiss() }"),
                      "the sheet must only dismiss when onPost returns nil (success) -- a failure must keep the sheet open")
        XCTAssertTrue(body.contains("if let errorMessage {"),
                      "a non-nil errorMessage must still be displayed inline")
        XCTAssertTrue(body.contains("Text(errorMessage)") && body.contains("foregroundColor(Theme.error)"),
                      "the inline error text must still use the error color token")
    }

    func test_preservedModifiers_dismissesKeyboardAndDarkColorScheme() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertTrue(body.contains(".dismissesKeyboardOnScrollAndTap()"),
                      "the shared keyboard-dismiss convention must be preserved")
        XCTAssertTrue(body.contains(".preferredColorScheme(.dark)"),
                      "the sheet must still force dark color scheme")
    }

    func test_replyFieldKeepsAccessibilityLabel() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertTrue(body.contains(#".accessibilityLabel("Reply text")"#),
                      "the reply TextEditor must keep an accessibility label through the restyle")
    }

    // MARK: - C. Out-of-scope guard: reply list display and posting logic untouched

    func test_postReplyDraft_networkAndOptimisticAppendLogicUnchanged() throws {
        let source = try componentSource()
        XCTAssertTrue(source.contains("let id = try await service.postReply(draft, noteId: note.id)"),
                      "postReplyDraft's network call must be unchanged by a visual-only restyle")
        XCTAssertTrue(source.contains("replies.append(draft)"),
                      "postReplyDraft's optimistic local append must be unchanged")
    }

    func test_replyCard_stillUsesWidgetCard_untouchedByThisRestyle() throws {
        let source = try componentSource()
        XCTAssertTrue(source.contains("private func replyCard(_ reply: FSNote) -> some View {"),
                      "replyCard must still exist, unmodified by this composer-sheet-only restyle")
    }
}
