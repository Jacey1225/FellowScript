// LinkifyTests.swift -- task 20261124-clickable-message-links (iOS).
// Written, not run on the Linux build host (no xcodebuild). Runs the shared
// fixture table (shared/linkify-fixtures.json) that the web Vitest suite also
// runs, plus the open-policy scheme guard. The fixture file is located relative
// to this source file, so no Xcode resource wiring is needed.

import XCTest
@testable import FellowScript

final class LinkifyTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Case: Decodable { let name: String; let input: String; let segments: [[String]] }
        struct Susp: Decodable { let url: String; let suspicious: Bool; let host: String }
        let cases: [Case]
        let suspicious: [Susp]
    }

    private func loadFixtures(file: StaticString = #filePath) throws -> Fixtures {
        // <repo>/FellowScript/FellowScriptTests/LinkifyTests.swift -> <repo>
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("shared/linkify-fixtures.json")
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }

    func testSharedFixtureSegments() throws {
        let fx = try loadFixtures()
        XCTAssertFalse(fx.cases.isEmpty)
        for c in fx.cases {
            let got = Linkify.segments(c.input).map { [$0.isLink ? "link" : "text", $0.text] }
            XCTAssertEqual(got, c.segments, c.name)
            XCTAssertEqual(got.map { $0[1] }.joined(), c.input, c.name)
        }
    }

    func testSharedFixtureSuspiciousAndHost() throws {
        for c in try loadFixtures().suspicious {
            let info = Linkify.info(c.url)
            XCTAssertNotNil(info, c.url)
            XCTAssertEqual(info?.suspicious, c.suspicious, c.url)
            XCTAssertEqual(info?.host, c.host, c.url)
        }
    }

    func testLargeInputsFinishQuickly() {
        let bodies = [
            "https://a.com/" + String(repeating: ")", count: 100_000),
            String(repeating: "https://", count: 20_000),
            String(repeating: "x", count: 100_000),
            String(repeating: "(", count: 50_000) + "https://a.com" + String(repeating: ")", count: 50_000),
        ]
        for b in bodies {
            let t0 = Date()
            _ = Linkify.segments(b)
            XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0)
        }
    }

    func testUrlCutByScanCapIsNotLinked() {
        let s = "https://a.com/" + String(repeating: "a", count: Linkify.maxScanScalars + 10)
        XCTAssertEqual(Linkify.segments(s), [Linkify.Segment(text: s, isLink: false)])
    }

    func testOpenPolicyOnlyAllowsHttpAndHttps() {
        func decide(_ s: String) -> MessageLinkPolicy.Decision { MessageLinkPolicy.decide(URL(string: s)!) }
        XCTAssertEqual(decide("https://example.com/a"), .open(URL(string: "https://example.com/a")!))
        for bad in ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "ftp://x.com",
                    "fsprofile://abc", "tel:123", "mailto:a@b.c", "myapp://open"] {
            XCTAssertEqual(decide(bad), .reject, bad)
        }
        if case .confirm(_, let host) = decide("https://user@example.com/") { XCTAssertEqual(host, "example.com") }
        else { XCTFail("userinfo link must ask first") }
    }

    @MainActor
    func testLinkifiedAttributedStringKeepsVisibleText() {
        let text = "see https://example.com/a?b=1."
        let attr = MentionText.linkified(text)
        XCTAssertEqual(String(attr.characters), text)
        let links = attr.runs.compactMap { $0.link }
        XCTAssertEqual(links, [URL(string: "https://example.com/a?b=1")!])
    }
}
