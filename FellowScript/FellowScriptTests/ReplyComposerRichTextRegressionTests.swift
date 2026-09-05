// ReplyComposerRichTextRegressionTests.swift — testing gate coverage for task
// 20260903-notes-reply-rich-text.
//
// Reported ask: give ReplyComposerSheet (private struct in
// Notes/NotesListView.swift, "Add a Reply" from NoteDetailView) the same
// text-formatting capabilities NoteEditorView already has (bold/italic/
// underline/highlight/color), reusing the existing RichTextEditorController/
// RichTextEditorView/FormatButton stack verbatim rather than reimplementing
// it, with the reply body posted as HTML instead of plain text and with its
// own independent controller instance (not shared with any open
// NoteEditorView). No backend changes.
//
// Testability note: ReplyComposerSheet is declared `private` (file-scoped),
// so — like every other private-struct scenario in this test target (see
// NoteReplySectionTests.swift MARK 7) — its internal toolbar/extraction/
// canPost logic is not independently constructible from this test file, and
// ViewInspector cannot reach into a `.sheet` modifier's content in this
// project's checked-in ViewInspector version (0.10.3) to inspect it live
// either. This file therefore:
//
//   1. Exercises the real underlying mechanism ReplyComposerSheet's new code
//      depends on — RichTextEditorController's toggle*/apply* actions and
//      currentHTML() — directly and behaviorally (a live UITextView, no
//      SwiftUI hosting required), proving bold/italic/underline/highlight/
//      color actually produce the expected inline HTML tags. This exact
//      mechanism previously had zero test coverage (flagged by codegraph)
//      despite already backing NoteEditorView.
//   2. Source-pins ReplyComposerSheet's specific wiring (own StateObject
//      controller, all five FormatButtons bound to the right rtc methods,
//      the extractedHTML() fallback chain verified to match
//      NoteEditorView.handleSave()'s chain, canPost gating on extracted
//      content instead of the removed `text` @State string, onPost invoked
//      with extractedHTML(), and the old plain TextEditor(text:) fully
//      gone) — the same technique this file's neighbors already use for
//      scenarios ViewInspector/direct construction can't reach.
//   3. Proves HTML reply bodies (with real formatting tags, entities, and
//      quotes) survive NetworkService.postReply's JSON request body
//      unmangled — the acceptance criterion that a formatted reply's stored
//      `text` is HTML with those attributes applied, exercised at the real
//      network layer (StubURLProtocol, same harness
//      NoteReplyNetworkServiceTests.swift already uses for postReply's
//      plain-text case).

import XCTest
import UIKit
@testable import FellowScript

// MARK: - 1. RichTextEditorController mechanics (the mechanism ReplyComposerSheet's
// new toolbar and extractedHTML() fallback chain both depend on)

final class ReplyComposerRichTextControllerTests: XCTestCase {

    /// A live UITextView with `text` loaded and the full range selected, wired
    /// to a fresh controller — mirrors what RichTextEditorView.makeUIView does
    /// (`controller.textView = tv`), without needing to host a SwiftUI view.
    private func makeSelectedEditor(_ text: String) -> (RichTextEditorController, UITextView) {
        let controller = RichTextEditorController()
        let tv = UITextView()
        tv.attributedText = NSAttributedString(string: text)
        tv.selectedRange = NSRange(location: 0, length: (text as NSString).length)
        controller.textView = tv
        return (controller, tv)
    }

    func test_toggleBold_wrapsSelectedTextInBoldTag_andSetsIsBold() {
        // Keep a strong reference to `tv` -- RichTextEditorController only
        // holds it `weak`, exactly like the real RichTextEditorView/UIKit
        // relationship, so a discarded local would be deallocated
        // immediately and every subsequent access would silently no-op.
        let (rtc, tv) = makeSelectedEditor("Hello world")
        // Select only "Hello" (first 5 chars) so the HTML output shows the
        // bold run distinct from the untouched remainder.
        tv.selectedRange = NSRange(location: 0, length: 5)

        rtc.toggleBold()

        XCTAssertTrue(rtc.isBold, "toggling bold on a real selection must flip the toolbar's active-state flag")
        XCTAssertEqual(rtc.currentHTML(), "<b>Hello</b> world",
                       "only the selected run must be wrapped in <b>, the rest must stay plain")
        XCTAssertEqual(rtc.htmlOutput, rtc.currentHTML(),
                       "htmlOutput must be kept in sync with currentHTML() after every format action")
    }

    func test_toggleItalic_wrapsSelectedTextInEmTag_andSetsIsItalic() {
        let (rtc, tv) = makeSelectedEditor("Hello world")
        tv.selectedRange = NSRange(location: 6, length: 5) // "world"

        rtc.toggleItalic()

        XCTAssertTrue(rtc.isItalic)
        XCTAssertEqual(rtc.currentHTML(), "Hello <em>world</em>")
    }

    func test_toggleUnderline_wrapsSelectedTextInUTag_andSetsIsUnderline() {
        let (rtc, tv) = makeSelectedEditor("Hello world")
        tv.selectedRange = NSRange(location: 0, length: 11)

        rtc.toggleUnderline()

        XCTAssertTrue(rtc.isUnderline)
        XCTAssertEqual(rtc.currentHTML(), "<u>Hello world</u>")
    }

    func test_toggleHighlight_wrapsSelectedTextInMarkTag_andSetsIsHighlight() {
        let (rtc, tv) = makeSelectedEditor("Hello world")
        tv.selectedRange = NSRange(location: 0, length: 11)

        rtc.toggleHighlight()

        XCTAssertTrue(rtc.isHighlight)
        XCTAssertEqual(rtc.currentHTML(), "<mark>Hello world</mark>")
    }

    func test_applyTextColor_wrapsSelectedTextInColorSpan_andSetsHasCustomColor() {
        let (rtc, tv) = makeSelectedEditor("Hello world")
        tv.selectedRange = NSRange(location: 0, length: 11)

        rtc.applyTextColor(.red)

        XCTAssertTrue(rtc.hasCustomColor, "applying a non-default color must flip hasCustomColor so the Text color button lights up")
        XCTAssertTrue(rtc.currentHTML().hasPrefix("<span style=\"color:rgba("),
                     "a custom-colored run must be wrapped in an inline-styled span, got: \(rtc.currentHTML())")

        rtc.resetColor()
        XCTAssertFalse(rtc.hasCustomColor, "resetColor (the Text color button's active-state tap) must clear hasCustomColor again")
    }

    // NOTE: a combined Bold+Italic case is deliberately NOT asserted here.
    // Investigating a first attempt at this test surfaced a real, pre-existing
    // bug in RichText.swift, unrelated to this task's diff: no "Lora-*" font
    // files are actually bundled in this app (Info.plist's UIAppFonts list --
    // PlayfairDisplay/Inter only -- and Fonts/ contain no Lora-*.ttf at all),
    // so `UIFont(name: "Lora-BoldItalic", ...)` always returns nil and
    // `kBoldItalic` always falls back to its composite:
    //   UIFont(descriptor: UIFont.boldSystemFont(...).fontDescriptor
    //            .withSymbolicTraits(.traitItalic) ?? desc, size: ...)
    // `withSymbolicTraits(_:)` REPLACES a descriptor's symbolic traits rather
    // than unioning them, so this composite silently drops the bold trait --
    // toggling Bold then Italic on the same selection (or vice versa) loses
    // Bold from both the rendered glyph and the serialized HTML (attribu-
    // tedStringToHTML checks the same fontDescriptor.symbolicTraits). This
    // pre-dates this task (RichText.swift is explicitly out of bounds here,
    // reused verbatim by both NoteEditorView and this task's ReplyComposer-
    // Sheet), so it's reported here rather than fixed or asserted against --
    // fixing it belongs to a follow-up task scoped to RichText.swift's font
    // composition (e.g. `.union(desc.symbolicTraits)` before adding
    // `.traitItalic`), not this one.
    func test_boldAndHighlightTogether_nestTagsCorrectly() {
        // Two orthogonal attributes (font trait + backgroundColor) rather
        // than bold+italic -- proves combined formatting composes/nests
        // correctly in the case unaffected by the pre-existing font-trait bug
        // documented above.
        let (rtc, tv) = makeSelectedEditor("Hello")
        tv.selectedRange = NSRange(location: 0, length: 5)

        rtc.toggleBold()
        tv.selectedRange = NSRange(location: 0, length: 5)
        rtc.toggleHighlight()

        XCTAssertTrue(rtc.isBold && rtc.isHighlight)
        XCTAssertEqual(rtc.currentHTML(), "<b><mark>Hello</mark></b>",
                       "combined bold+highlight must nest as <b><mark>…</mark></b> -- attributedStringToHTML wraps innermost-to-outermost as color, mark, u, em, b, so bold (checked last) ends up outermost")
    }

    func test_toggleBold_withNoTextView_doesNotCrash_andLeavesFlagsUnchanged() {
        // Defensive: a format button tapped before RichTextEditorView's
        // makeUIView has run (or after the weak textView ref has been
        // deallocated) must no-op, not crash.
        let rtc = RichTextEditorController()
        rtc.toggleBold()
        XCTAssertFalse(rtc.isBold)
        XCTAssertEqual(rtc.currentHTML(), "")
    }
}

// MARK: - 2. Source-pinned coverage for ReplyComposerSheet (private struct;
// see file header for why this technique is used instead of ViewInspector).

final class ReplyComposerSheetWiringSourceTests: XCTestCase {

    // ReplyComposerSheet moved out of NotesListView.swift into its own file
    // in the compliance-readability-cleanup task's split (readability #6,
    // 20260904-frontend-arch-sweep) -- same type, same behavior, and no
    // longer `private` since a sibling-file split requires at least internal
    // visibility.
    private func componentSource() throws -> String {
        let componentFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Notes/ReplyComposerSheet.swift")
        return try String(contentsOf: componentFile, encoding: .utf8)
    }

    /// Isolates ReplyComposerSheet's own body — from its declaration to the
    /// end of the file, since it's the only top-level declaration in
    /// ReplyComposerSheet.swift now — so these assertions can't accidentally
    /// match unrelated text elsewhere.
    private func replyComposerSection() throws -> String {
        let source = try componentSource()
        guard let start = source.range(of: "struct ReplyComposerSheet: View {") else {
            XCTFail("could not locate ReplyComposerSheet to scope this check")
            return ""
        }
        return String(source[start.lowerBound...])
    }

    func test_ownsIndependentRichTextEditorController_notSharedWithNoteEditorView() throws {
        let section = try replyComposerSection()
        XCTAssertTrue(
            section.contains("@StateObject private var rtc = RichTextEditorController()"),
            "ReplyComposerSheet must construct its own RichTextEditorController instance -- " +
            "a reply composer is a distinct, independent editing session from any open NoteEditorView"
        )
    }

    func test_formatToolbar_allFiveButtons_wiredToControllerMethods() throws {
        let section = try replyComposerSection()
        let expectedWiring = [
            #"FormatButton(label: "Bold",      bold: true,           isActive: rtc.isBold)         { rtc.toggleBold() }"#,
            #"FormatButton(label: "Italic",    italic: true,         isActive: rtc.isItalic)       { rtc.toggleItalic() }"#,
            #"FormatButton(label: "Underline", underline: true,      isActive: rtc.isUnderline)    { rtc.toggleUnderline() }"#,
            #"FormatButton(label: "Highlight", highlightStyle: true, isActive: rtc.isHighlight)    { rtc.toggleHighlight() }"#,
            #"FormatButton(label: "Text color", colorBar: true, isActive: rtc.hasCustomColor) {"#,
        ]
        for wiring in expectedWiring {
            XCTAssertTrue(section.contains(wiring),
                          "ReplyComposerSheet's toolbar must reuse this exact FormatButton wiring from NoteEditorView: \(wiring)")
        }
    }

    func test_colorSwatchRow_usesThemeHighlightColorsAndHex() throws {
        let section = try replyComposerSection()
        XCTAssertTrue(
            section.contains("ForEach(Array(zip(Theme.highlightColors, Theme.highlightHex)), id: \\.1) { color, hex in"),
            "the color-picker swatch row must reuse Theme.highlightColors/highlightHex verbatim, matching NoteEditorView"
        )
        XCTAssertTrue(section.contains("@State private var showColorPicker = false"),
                      "ReplyComposerSheet must have its own local showColorPicker state, mirroring NoteEditorView's own")
    }

    func test_extractedHTML_fallbackChain_matchesNoteEditorViewHandleSave() throws {
        let section = try replyComposerSection()
        // The exact same three-tier fallback order handleSave() uses: live
        // UITextView content -> tracked @Published htmlOutput -> plain-text-
        // to-<br> conversion read straight from the live text view.
        XCTAssertTrue(section.contains("let liveHTML    = rtc.currentHTML()"))
        XCTAssertTrue(section.contains("let trackedHTML = rtc.htmlOutput"))
        XCTAssertTrue(section.contains("let tvText      = rtc.textView?.text ?? \"\""))
        XCTAssertTrue(section.contains("if !liveHTML.isEmpty {"))
        XCTAssertTrue(section.contains("} else if !trackedHTML.isEmpty {"))
        XCTAssertTrue(section.contains(".replacingOccurrences(of: \"\\n\", with: \"<br>\")"),
                      "the plain-text fallback must convert newlines to <br>, matching handleSave()'s conversion")
        // Unlike NoteEditorView (which falls back to the original note's own
        // text when everything else is empty), a reply has no prior text to
        // fall back to -- the final branch must be a plain empty string.
        XCTAssertTrue(section.contains("} else {\n            return \"\"\n        }"),
                      "a reply's extractedHTML() must fall back to an empty string, not any prior note text")
    }

    func test_canPost_gatesOnExtractedContent_notRawTextState() throws {
        let section = try replyComposerSection()
        XCTAssertTrue(
            section.contains("!extractedHTML().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting"),
            "canPost must gate on the extracted HTML/text content being non-empty, not on a removed raw `text` @State string"
        )
        XCTAssertFalse(section.contains("@State private var text"),
                       "the old plain-string @State var text must be fully removed, not left dangling alongside the rich editor")
    }

    func test_onPost_calledWithExtractedHTML_notRawTextVariable() throws {
        let section = try replyComposerSection()
        XCTAssertTrue(section.contains("errorMessage = await onPost(extractedHTML())"),
                      "posting must send the extracted HTML through onPost, not a plain-string local variable")
    }

    func test_noPlainTextEditorRemainsInReplyBody() throws {
        let section = try replyComposerSection()
        XCTAssertFalse(section.contains("TextEditor("),
                       "the old plain TextEditor(text:) body field must be fully replaced by RichTextEditorView, not left alongside it")
    }

    func test_bodyUsesRichTextEditorView_withOwnPlaceholderAndEmptyInitialHTML() throws {
        let section = try replyComposerSection()
        XCTAssertTrue(section.contains("RichTextEditorView("), "the reply body must be backed by RichTextEditorView, matching NoteEditorView")
        XCTAssertTrue(section.contains("controller:  rtc,"))
        XCTAssertTrue(section.contains(#"initialHTML: "","#),
                      "a brand-new reply has no prior content to preload -- initialHTML must be empty")
        XCTAssertTrue(section.contains(#"placeholder: "Write a reply…""#))
        // Placeholder-Text-always-in-the-ZStack pattern, same rationale
        // NoteEditorView's own comment documents: never recreate the
        // UIViewRepresentable via a structural conditional, or htmlOutput resets.
        XCTAssertTrue(section.contains(".opacity(rtc.htmlOutput.isEmpty ? 1 : 0)"),
                      "the placeholder Text must stay unconditionally in the ZStack, toggling only its opacity off htmlOutput")
    }
}

// MARK: - 3. HTML reply bodies survive the real NetworkService.postReply
// request round trip unmangled (network-layer acceptance criterion: a
// formatted reply's stored `text` is HTML with those attributes applied).

@MainActor
final class ReplyComposerPostReplyHTMLIntegrationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
    }

    func test_postReply_formattedHTMLBody_reachesServerUnmangled() async throws {
        StubURLProtocol.stubStatusCode = 201
        StubURLProtocol.stubBody = #"{"id": "reply-formatted-001"}"#.data(using: .utf8)!

        // Exactly the shape attributedStringToHTML/extractedHTML() would
        // produce for "Great point!" with the first word bolded, the second
        // highlighted, and a custom color applied -- entities, quotes, and
        // nested tags all present, the same content class real formatted
        // replies will now carry (they used to always be plain strings).
        let formattedHTML = #"<b>Great</b> <mark>point!</mark> <span style="color:rgba(200,50,50,0.90)">&amp; well said</span>"#

        var draft = FSNote()
        draft.user     = "user-1"
        draft.text     = formattedHTML
        draft.group_id = "group-abc"
        draft.is_reply = true

        let id = try await NetworkService.shared.postReply(draft, noteId: "note-grp-001")
        XCTAssertEqual(id, "reply-formatted-001")

        let last = try XCTUnwrap(StubURLProtocol.requestLog.last)
        XCTAssertEqual(last.path, "/api/notes/reply/note-grp-001")
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.bodyJSON?["text"] as? String, formattedHTML,
                       "the reply's HTML text -- tags, inline style, and entities -- must reach the backend byte-for-byte, unmangled by JSON encoding")
    }

    func test_postReply_plainTextStillWorks_noRegressionForUnformattedReplies() async throws {
        // A reply posted with no formatting applied (extractedHTML()'s
        // plain-text-to-<br> fallback path) must still round-trip correctly --
        // this is the pre-existing behavior NoteReplyNetworkServiceTests.swift
        // already covers; re-asserted here alongside the new HTML case so a
        // future change can't fix one path while quietly breaking the other.
        StubURLProtocol.stubStatusCode = 201
        StubURLProtocol.stubBody = #"{"id": "reply-plain-001"}"#.data(using: .utf8)!

        var draft = FSNote()
        draft.user     = "user-1"
        draft.text     = "No formatting here"
        draft.group_id = "group-abc"
        draft.is_reply = true

        _ = try await NetworkService.shared.postReply(draft, noteId: "note-grp-001")

        let last = try XCTUnwrap(StubURLProtocol.requestLog.last)
        XCTAssertEqual(last.bodyJSON?["text"] as? String, "No formatting here")
    }
}
