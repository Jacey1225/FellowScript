// HomeWordmarkHeaderTests.swift -- coverage for task 20261008-home-wordmark-header
// (testing gate): the Home tab's small "FellowScript" wordmark, the bundled
// Schibsted Grotesk SemiBold font registration, and removal of the admin
// home-message fetch path.

import XCTest
import SwiftUI
import UIKit
import ViewInspector
@testable import FellowScript

final class HomeWordmarkHeaderTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: header

    func test_header_rendersFellowScriptText_andNoGreeting() throws {
        let sut = HomeWordmarkHeader()
        XCTAssertNoThrow(try sut.inspect().find(text: "FellowScript"))
        XCTAssertThrowsError(try sut.inspect().find(textWhere: { t, _ in t.contains("Welcome") })) { _ in }
    }

    func test_header_baseSizeIs17() {
        XCTAssertEqual(HomeWordmarkHeader.baseSize, 17)
    }

    func test_source_header_scalesWithDynamicType_hasHeaderTrait_andIsLeftAligned() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardComponents.swift")
        let start = try XCTUnwrap(source.range(of: "struct HomeWordmarkHeader: View"))
        let tail = String(source[start.lowerBound...])
        let end = tail.range(of: "// Mirrors activity.py")?.lowerBound ?? tail.endIndex
        let body = String(tail[..<end])
        XCTAssertTrue(body.contains("relativeTo: .headline"), "must scale with Dynamic Type")
        XCTAssertTrue(body.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertTrue(body.contains("alignment: .leading"))
        XCTAssertTrue(body.contains(".padding(.horizontal, 20)"))
    }

    func test_source_dashboardView_usesWordmarkHeader() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardView.swift")
        XCTAssertTrue(source.contains("HomeWordmarkHeader()"))
        XCTAssertFalse(source.contains("HeroHeader"))
        XCTAssertFalse(source.contains("homeMessage"))
    }

    // MARK: font

    func test_font_schibstedSemiBold_isRegisteredAndLoads() {
        let font = UIFont(name: "SchibstedGrotesk-SemiBold", size: 17)
        XCTAssertNotNil(font, "bundled Schibsted Grotesk SemiBold must register (Info.plist UIAppFonts)")
        XCTAssertEqual(font?.fontName, "SchibstedGrotesk-SemiBold")
        XCTAssertEqual(font?.familyName, "Schibsted Grotesk")
    }

    func test_font_schibstedWordmark_resolves() {
        // Font has no public introspection; resolving must not trap and the
        // helper must name the same face UIKit can load.
        _ = Font.schibstedWordmark(17, relativeTo: .headline)
        XCTAssertNotNil(UIFont(name: "SchibstedGrotesk-SemiBold", size: 17))
    }

    func test_wordmarkText_usesSchibstedHelper_notInterFallback() throws {
        let source = try readSource("FellowScript/Theme/Theme.swift")
        let start = try XCTUnwrap(source.range(of: "struct WordmarkText: View"))
        let body = String(source[start.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("Font.schibstedWordmark("))
        XCTAssertFalse(body.contains("Font.inter("))
        XCTAssertNoThrow(try WordmarkText().inspect().find(text: "FellowScript"))
    }

    func test_infoPlist_listsFontFile_andFileIsBundledWithLicense() throws {
        let plist = try readSource("FellowScript/Info.plist")
        XCTAssertTrue(plist.contains("SchibstedGrotesk-SemiBold.ttf"))
        XCTAssertNotNil(Bundle.main.path(forResource: "SchibstedGrotesk-SemiBold", ofType: "ttf")
                        ?? Bundle(for: Self.self).path(forResource: "SchibstedGrotesk-SemiBold", ofType: "ttf")
                        ?? Bundle.allBundles.compactMap { $0.path(forResource: "SchibstedGrotesk-SemiBold", ofType: "ttf") }.first)
        let notice = try readSource("FellowScript/Fonts/NOTICE.md")
        XCTAssertTrue(notice.contains("Schibsted Grotesk"))
    }

    // MARK: home-message removal

    func test_noSourceStillReferencesHomeMessageEndpoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript")
        let en = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["home-message", "HomeMessageStore", "HomeMessageService", "HomeMessageText", "FSHomeMessagePayload"]
            where text.contains(needle) { offenders.append("\(url.lastPathComponent):\(needle)") }
        }
        XCTAssertEqual(offenders, [])
    }
}
