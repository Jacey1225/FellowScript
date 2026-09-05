// HighlightRowBaselineTests.swift — testing gate coverage for task
// 20260904-compliance-readability-cleanup, step 1 (testing).
//
// NotesListView.swift (2044 loc) had thorough coverage of NotesViewModel
// (NotesHighlightsRegressionTests.swift, NotesPaginationRegressionTests.swift,
// etc.) and of NoteRow (NoteRowAuthorIndicatorTests.swift), but `HighlightRow`
// — the row rendered per entry in the Highlights tab — had none. Added here
// as baseline/characterization coverage before this task's later step splits
// NotesListView.swift by section, per this project's convention for
// stateless single-purpose View structs (PillButtonTests.swift,
// DashboardEmptyStateTests.swift).

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

final class HighlightRowBaselineTests: XCTestCase {

    private func highlight(book: String = "John", chapter: Int = 3, verse: Int = 16,
                            color: String = "#D4922A", username: String? = nil) -> FSHighlight {
        FSHighlight(id: "\(book)-\(chapter)-\(verse)", book: book, chapter: chapter, verse: verse,
                    color: color, username: username)
    }

    func test_rendersBookChapterAndVerseReference() throws {
        let sut = HighlightRow(highlight: highlight(book: "John", chapter: 3, verse: 16))
        XCTAssertNoThrow(try sut.inspect().find(text: "John 3:16"))
    }

    func test_withUsername_rendersUsernameLabel() throws {
        let sut = HighlightRow(highlight: highlight(username: "alice"))
        XCTAssertNoThrow(try sut.inspect().find(text: "alice"),
                          "a group-segment highlight's captured username must render as its own label")
    }

    func test_withoutUsername_rendersNoUsernameText() throws {
        // Personal-segment highlights never carry a username.
        let noUsername = HighlightRow(highlight: highlight(username: nil))
        let withUsername = HighlightRow(highlight: highlight(username: "alice"))

        let baseline = try noUsername.inspect().findAll(ViewType.Text.self).count
        let withOne  = try withUsername.inspect().findAll(ViewType.Text.self).count
        XCTAssertEqual(withOne, baseline + 1,
                        "the username label must be the only Text node difference between the two states")
    }

    func test_differentReferences_renderDistinctText() throws {
        let first  = HighlightRow(highlight: highlight(book: "Genesis", chapter: 1, verse: 1))
        let second = HighlightRow(highlight: highlight(book: "Revelation", chapter: 22, verse: 21))
        XCTAssertNoThrow(try first.inspect().find(text: "Genesis 1:1"))
        XCTAssertNoThrow(try second.inspect().find(text: "Revelation 22:21"))
    }
}
