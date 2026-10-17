// PlainTextNoteLineBreakRegressionTests.swift — task 20261017-devotion-note-format.
//
// Scheduled devotion notes are stored as plain text with real newlines. The
// HTML importer used by RichText.swift collapses bare newlines to spaces, so
// plain bodies must have line breaks converted to <br> before parsing, while
// bodies that already contain tags (editor output) stay untouched.

import XCTest
import UIKit
@testable import FellowScript

private func readProjectSource(_ relativePath: String, from file: StaticString = #filePath) throws -> String {
    let url = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

final class PlainTextNoteLineBreakRegressionTests: XCTestCase {

    private let plain = "Check-in\nHow did it go?\n\nScripture\nRomans 8:1-4"

    func test_plainBody_newlinesBecomeBr() {
        XCTAssertEqual(plainTextBodyToHTMLIfNeeded(plain),
                       "Check-in<br>How did it go?<br><br>Scripture<br>Romans 8:1-4")
    }

    func test_plainBody_crlfCountsAsOneBreak() {
        XCTAssertEqual(plainTextBodyToHTMLIfNeeded("a\r\nb\rc"), "a<br>b<br>c")
    }

    func test_htmlBody_isUntouched() {
        let html = "<b>Bold</b><br>line\nsecond"
        XCTAssertEqual(plainTextBodyToHTMLIfNeeded(html), html)
    }

    func test_htmlToAttributedString_preservesPlainLineBreaks() {
        let out = htmlToAttributedString(plain).string
        XCTAssertTrue(out.contains("Check-in\u{2028}How did it go?") || out.contains("Check-in\nHow did it go?"),
                      "line break after the first line must survive, got: \(out.debugDescription)")
        XCTAssertFalse(out.contains("Check-in How did it go?"))
        let breaks = out.unicodeScalars.filter { $0 == "\n" || $0 == "\u{2028}" }.count
        XCTAssertGreaterThanOrEqual(breaks, 4, "blank line and line breaks must be preserved")
    }

    func test_editorRoundTrip_doesNotPersistCollapsedText() {
        let html = attributedStringToHTML(htmlToAttributedString(plain))
        XCTAssertFalse(html.contains("Check-in How did it go?"))
        XCTAssertFalse(html.contains("Check-in How did it go? Scripture"))
    }

    func test_sourcePin_buildAttributedString_usesPlainTextConversion() throws {
        let source = try readProjectSource("FellowScript/Utils/RichText.swift")
        XCTAssertEqual(source.components(separatedBy: "plainTextBodyToHTMLIfNeeded(raw").count - 1, 2,
                       "both htmlToAttributedString and buildAttributedString must convert plain bodies")
    }
}
