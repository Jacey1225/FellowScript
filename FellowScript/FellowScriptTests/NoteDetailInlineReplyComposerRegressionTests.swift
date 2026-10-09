// NoteDetailInlineReplyComposerRegressionTests.swift -- task
// 20260909-reply-inline-editor. The reply composer used to open as a sheet;
// it must now render inline, directly below the note body, with no sheet.

import XCTest

final class NoteDetailInlineReplyComposerRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func codeOnly(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func test_noteDetailView_presentsNoReplySheet() throws {
        let code = codeOnly(try readSource("FellowScript/Notes/NoteDetailView.swift"))
        XCTAssertFalse(code.contains("ReplyComposerSheet"), "the old sheet type must not be referenced")
        XCTAssertFalse(code.contains(".sheet(isPresented: $showReplyComposer)"),
                       "showReplyComposer must not drive a sheet any more")
        XCTAssertTrue(code.contains("ReplyComposerInline("))
    }

    func test_inlineComposer_rendersBelowNoteBody_aboveRepliesList() throws {
        let code = codeOnly(try readSource("FellowScript/Notes/NoteDetailView.swift"))
        guard let body = code.range(of: "NoteHTMLView(html: note.text)"),
              let composer = code.range(of: "ReplyComposerInline(onPost: postReplyDraft"),
              let replies = code.range(of: "repliesSectionLabel(replies.count)") else {
            XCTFail("could not locate note body, inline composer and replies list")
            return
        }
        XCTAssertLessThan(body.lowerBound, composer.lowerBound, "composer must follow the note body")
        XCTAssertLessThan(composer.lowerBound, replies.lowerBound, "composer must precede the replies list")
    }

    func test_inlineComposer_gatedOnGroupNoteLoadedAndOpenFlag() throws {
        let code = codeOnly(try readSource("FellowScript/Notes/NoteDetailView.swift"))
        XCTAssertTrue(code.contains("if isGroupNote && repliesLoaded && showReplyComposer {"))
    }

    func test_inlineComposer_isNotANavigationStackOrSheetRoot() throws {
        let code = codeOnly(try readSource("FellowScript/Notes/ReplyComposerSheet.swift"))
        XCTAssertFalse(code.contains("struct ReplyComposerSheet"))
        XCTAssertFalse(code.contains("NavigationStack"))
    }
}
