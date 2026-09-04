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
//   A. Visual migration: warmBloomBackground(), the reply field's card
//      recipe (glassCard(cornerRadius: 20) as of task
//      20260904-reply-field-background-match; originally widgetCard()),
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
//
// Updated by task 20260903-notes-reply-rich-text: that task replaced the
// plain `TextEditor(text: $text)` body field (and the `text` @State string
// it bound to) with the same RichTextEditorController/RichTextEditorView
// stack NoteEditorView already used, so a reply's posted body is HTML with
// real formatting instead of a plain string. Three assertions below were
// pinned to that now-superseded plain-text wiring
// (`TextEditor(text: $text)`, `onPost(text)`, and canPost's raw-`text`
// gate) — updated here to the new extractedHTML()-based wiring per that
// task's own acceptance criteria ("existing ReplyComposerSheet tests still
// compile and pass, or are updated only for the text -> HTML-content wiring
// change"). Every other assertion in this file (visual migration, posting-
// state handling, error display, dismiss timing, out-of-scope guards) is
// unrelated to that change and stays exactly as this task originally wrote
// it. See ReplyComposerRichTextRegressionTests.swift for that task's own,
// fuller coverage of the new rich-text wiring itself.
//
// Updated by task 20260904-reply-field-background-match: per the user's
// explicit request, the reply body field's card recipe was swapped from the
// opaque widgetCard() fill to the translucent glassCard(cornerRadius: 20)
// recipe NoteEditorView's own body field uses (matching that field's
// background exactly), deliberately diverging from the widgetCard()-matches-
// other-submenu-sheets precedent this file originally pinned for that one
// field. Only the one assertion checking the field's card modifier was
// updated (test_replyFieldIsWrappedInGlassCard_notFormSection, formerly
// test_replyFieldIsWrappedInWidgetCard_notFormSection); every other
// assertion in this file is unaffected by this style-only change.

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

    func test_replyFieldIsWrappedInGlassCard_notFormSection() throws {
        let body = try sheetBody(try componentSource())
        XCTAssertFalse(body.contains("Form {"), "must no longer use a plain Form")
        XCTAssertFalse(body.contains(#"Section("Reply")"#), "must no longer use a plain Form Section")
        // Updated by task 20260904-reply-field-background-match: the reply
        // field's card recipe was switched from the opaque widgetCard() fill
        // to the same translucent glassCard(cornerRadius: 20) recipe
        // NoteEditorView's body field uses, per the user's explicit request
        // to match that field's background exactly.
        XCTAssertTrue(body.contains(".glassCard(cornerRadius: 20)"),
                      "the reply field must be wrapped in the glassCard(cornerRadius: 20) recipe, matching NoteEditorView's body field")
        // Superseded by task 20260903-notes-reply-rich-text: the plain
        // TextEditor(text: $text) binding this test originally pinned was
        // replaced by the same RichTextEditorView stack NoteEditorView uses,
        // so a reply's body is HTML with real formatting instead of plain
        // text. See this file's header note and
        // ReplyComposerRichTextRegressionTests.swift for that task's own
        // fuller coverage of the new wiring.
        XCTAssertFalse(body.contains("TextEditor(text: $text)"),
                       "the old plain TextEditor(text:) binding must be fully replaced by RichTextEditorView")
        XCTAssertTrue(body.contains("RichTextEditorView("),
                      "the reply body must now be backed by RichTextEditorView, matching NoteEditorView's rich-text stack")
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
        // Superseded by task 20260903-notes-reply-rich-text: onPost is now
        // invoked with the extracted HTML content, not the removed plain
        // `text` @State string -- same onPost signature/contract, different
        // (now-formatted) content.
        XCTAssertTrue(body.contains("errorMessage = await onPost(extractedHTML())"),
                      "Post must invoke onPost with the extracted HTML reply content and capture its result as errorMessage")
    }

    func test_canPostGating_nonEmptyTrimmedTextAndNotAlreadyPosting() throws {
        let body = try sheetBody(try componentSource())
        // Superseded by task 20260903-notes-reply-rich-text: canPost gates on
        // the extracted HTML/text content now, since the raw `text` @State
        // string it used to check no longer exists.
        XCTAssertTrue(body.contains("!extractedHTML().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting"),
                      "canPost must still require non-empty trimmed (now extracted) content AND that a post isn't already in flight")
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
