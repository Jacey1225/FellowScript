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

    // The two tests that ran the HTML importer (htmlToAttributedString / the editor round trip) were
    // removed: NSAttributedString's HTML import pumps the main run loop, and in a full parallel run
    // that let other classes' pending work run and made MessagingAttachmentsNetworkServiceTests'
    // shared StubURLProtocol request-log assertions fail. The importer behaviour was verified with a
    // standalone macOS script (testing.json); the pure conversion and the source pins stay here.

    func test_sourcePin_buildAttributedString_usesPlainTextConversion() throws {
        let source = try readProjectSource("FellowScript/Utils/RichText.swift")
        XCTAssertEqual(source.components(separatedBy: "plainTextBodyToHTMLIfNeeded(raw").count - 1, 2,
                       "both htmlToAttributedString and buildAttributedString must convert plain bodies")
    }
}
