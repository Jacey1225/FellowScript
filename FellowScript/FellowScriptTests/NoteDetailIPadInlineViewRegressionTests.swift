// NoteDetailIPadInlineViewRegressionTests.swift -- testing gate for task
// 20261015-ipad-inline-note-view-and-reply.
//
// Bug: on iPad, tapping a note in the workspace Notes panel opened
// NoteDetailView as a centered sheet. It must render inline in the panel
// (regular width, embedded), while iPhone / compact width keep the sheet.
// Source-pinned, matching the repo style for view-gating regressions.

import XCTest

final class NoteDetailIPadInlineViewRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func codeOnly(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func detailExt() throws -> String { codeOnly(try readSource("Notes/NotesListView+InlineDetail.swift")) }
    private func listView() throws -> String { codeOnly(try readSource("Notes/NotesListView.swift")) }
    private func detailView() throws -> String { codeOnly(try readSource("Notes/NoteDetailView.swift")) }

    // MARK: gating (regular vs compact)

    func test_inlineDetail_requiresEmbeddedAndNotCompact() throws {
        let c = try detailExt()
        XCTAssertTrue(c.contains("var inlineDetail: Bool { embedded && horizontalSizeClass != .compact }"),
                      "inline detail must be gated on embedded AND non-compact width")
    }

    func test_listView_readsHorizontalSizeClass() throws {
        XCTAssertTrue(try listView().contains("@Environment(\\.horizontalSizeClass) var horizontalSizeClass"))
    }

    func test_sheetStillPresentedForCompact_boundToNilOnlyWhenInline() throws {
        let c = try listView()
        XCTAssertTrue(c.contains(".sheet(item: inlineDetail ? Binding<FSNote?>.constant(nil) : $detailNote)"),
                      "sheet must stay bound to detailNote when not inline (iPhone/compact) and be suppressed when inline")
        XCTAssertTrue(c.contains("detailView(for: note, inline: false)"), "sheet path builds the non-inline detail")
    }

    func test_inlineLayer_onlyRendersWhenInlineAndNoteSelected() throws {
        let c = try detailExt()
        XCTAssertTrue(c.contains("if inlineDetail, let note = detailNote {"))
        XCTAssertTrue(c.contains("detailView(for: note, inline: true)"))
    }

    func test_inlineLayerIsMountedInNotesListBody_withListKeptMounted() throws {
        let c = try listView()
        XCTAssertTrue(c.contains("inlineDetailLayer"), "overlay layer must be placed in NotesListView body")
        // Overlay, not a replacement of the list: scroll position + cache survive Back.
        let ext = try detailExt()
        XCTAssertFalse(ext.contains("vm.reset") || ext.contains("vm.notes = []"),
                       "showing detail must not touch list cache")
    }

    func test_inlineDetail_hidesPanelChromeViaPreference() throws {
        XCTAssertTrue(try listView().contains("embedded && (showEditor || inlineDetailShowing)"))
    }

    // MARK: motion

    func test_transitionIsEasedAndRespectsReducedMotion() throws {
        let c = try listView() + (try detailExt())
        XCTAssertTrue(c.contains(".animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: detailNote?.id)"))
        XCTAssertTrue(c.contains("reduceMotion ? .identity : .opacity"))
    }

    // MARK: actions do not stack sheets

    func test_editFromInlineDetail_clearsDetailSoEditorReplacesIt() throws {
        let c = try detailExt()
        guard let a = c.range(of: "onEditInline: embedded ? {"),
              let b = c.range(of: "onEditReplyInline: embedded ? {"),
              let end = c.range(of: "inline: inline,") else { return XCTFail("closures not found") }
        let edit = String(c[a.lowerBound..<b.lowerBound])
        let reply = String(c[b.lowerBound..<end.lowerBound])
        XCTAssertTrue(edit.contains("detailNote     = nil"), "Edit must dismiss detail")
        XCTAssertTrue(reply.contains("detailNote     = nil"), "Edit-reply must dismiss detail")
        XCTAssertTrue(edit.contains("showEditor     = true") && reply.contains("showEditor     = true"))
    }

    func test_backReturnsToList_byClearingSelection() throws {
        XCTAssertTrue(try detailExt().contains("onBack: { detailNote = nil }"))
    }

    func test_sendInChat_inlinePresentsImmediately_sheetKeepsDelay() throws {
        let c = codeOnly(try readSource("Notes/NotesListView+List.swift"))
        guard let a = c.range(of: "func sendInChatFromDetail") else { return XCTFail("missing") }
        let body = String(c[a.lowerBound...].prefix(500))
        XCTAssertTrue(body.contains("if inlineDetail { sendInChat(note); return }"))
        XCTAssertTrue(body.contains("450_000_000"), "sheet path must keep the dismiss delay")
    }

    // MARK: NoteDetailView inline vs sheet bodies

    func test_noteDetailView_hasInlineAndSheetBodiesSharingScroll() throws {
        let c = try detailView()
        XCTAssertTrue(c.contains("inlineBody"))
        XCTAssertTrue(c.contains("sheetBody"))
        XCTAssertTrue(c.contains("detailScroll"))
        XCTAssertTrue(c.contains("onBack"))
    }

    func test_sheetBodyKeepsNavigationStack_inlineBodyHasNone() throws {
        let c = try detailView()
        guard let i = c.range(of: "private var inlineBody"), let s = c.range(of: "var sheetBody") else {
            return XCTFail("bodies not found")
        }
        let (first, second) = i.lowerBound < s.lowerBound ? (i, s) : (s, i)
        let firstText = String(c[first.lowerBound..<second.lowerBound])
        let secondText = String(c[second.lowerBound...])
        let inlineText = i.lowerBound < s.lowerBound ? firstText : secondText
        let sheetText = i.lowerBound < s.lowerBound ? secondText : firstText
        XCTAssertFalse(inlineText.prefix(2500).contains("NavigationStack"), "no nested NavigationStack inline")
        XCTAssertTrue(sheetText.contains("NavigationStack"), "sheet keeps its NavigationStack for compact")
    }

    func test_inlineHeader_hasAccessibleBackControl() throws {
        let c = try detailView()
        XCTAssertTrue(c.contains("Back to notes"))
        XCTAssertTrue(c.contains("minWidth: 44") || c.contains("frame(width: 44") || c.contains("44"))
    }

    func test_replyComposerStillInlineBelowBody_noSheet() throws {
        let c = try detailView()
        XCTAssertTrue(c.contains("ReplyComposerInline("))
        XCTAssertFalse(c.contains(".sheet(isPresented: $showReplyComposer)"))
    }

    func test_otherCallSites_keepSheet() throws {
        // Dashboard / shared-object call sites use the default (non-inline) init.
        let d = codeOnly(try readSource("Notes/NoteDetailView.swift"))
        XCTAssertTrue(d.contains("var inline: Bool = false"), "inline must default to false so other call sites keep sheets")
    }
}
