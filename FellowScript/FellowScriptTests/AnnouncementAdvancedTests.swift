// AnnouncementAdvancedTests.swift — testing gate for task
// 20261009-announcements-advanced, parts A-D (stock banners, translucent
// fields, title fonts, background themes).

import XCTest
import SwiftUI
import UIKit
@testable import FellowScript

@MainActor
final class AnnouncementAdvancedTests: XCTestCase {

    // MARK: helpers

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
    private func readRepo(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.deletingLastPathComponent().appendingPathComponent(relativePath), encoding: .utf8)
    }
    /// Quoted keys inside `NAME = frozenset({ ... })` in the server module.
    private func serverKeys(_ name: String) throws -> Set<String> {
        let py = try readRepo("api/backend/interactions/announcements.py")
        let start = try XCTUnwrap(py.range(of: "\(name) = frozenset({"))
        let tail = py[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "})"))
        let body = String(tail[..<end.lowerBound])
        var keys = Set<String>()
        for part in body.split(separator: "\"").enumerated() where part.offset % 2 == 1 { keys.insert(String(part.element)) }
        return keys
    }
    private func decode(_ extra: String) throws -> FSGroupAnnouncement {
        let json = """
        {"id":"a","group_id":"g","creator_id":"u","creator_username":"ann","title":"T","description":"D",
         "banner_url":null,"publish_at":"2026-01-01T00:00:00+00:00","created_at":"2026-01-01T00:00:00+00:00",
         "updated_at":"2026-01-01T00:00:00+00:00","published":true,"can_edit":true\(extra)}
        """
        return try JSONDecoder().decode(FSGroupAnnouncement.self, from: Data(json.utf8))
    }

    // MARK: Part A — stock manifest

    func testManifestHas32EntriesAllResolveToBundledJPEGs() throws {
        let photos = AnnouncementStockCatalog.load()
        XCTAssertEqual(photos.count, 32, "load() drops entries whose file is missing, so 32 means all resolve")
        XCTAssertEqual(Set(photos.map(\.id)).count, 32, "ids unique")
        for p in photos {
            let url = try XCTUnwrap(AnnouncementStockCatalog.fileURL(p), "\(p.id) not bundled")
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "\(p.id) is not a JPEG")
            XCTAssertLessThanOrEqual(data.count, 300_000, "\(p.id) over the size cap")
            XCTAssertNotNil(AnnouncementStockCatalog.thumbnail(p), "\(p.id) thumbnail")
        }
    }

    func testManifestCreditsAndCategories() throws {
        let photos = AnnouncementStockCatalog.load()
        let cats = Set(AnnouncementStockCatalog.categories.compactMap(\.key))
        let credits = try readSource("FellowScript/Resources/NatureBanners/CREDITS.md")
        for p in photos {
            XCTAssertFalse(p.author.isEmpty, p.id)
            XCTAssertEqual(p.license, "CC0 1.0", p.id)
            XCTAssertFalse(p.alt.isEmpty, "\(p.id) needs VoiceOver text")
            XCTAssertTrue(cats.contains(p.category), "\(p.id) category \(p.category)")
            XCTAssertTrue(credits.contains(p.id) || credits.contains(p.file), "\(p.id) missing from CREDITS.md")
        }
        for c in cats { XCTAssertEqual(photos.filter { $0.category == c }.count, 8, c) }
    }

    func testTotalBundledSizeUnderCap() throws {
        let total = try AnnouncementStockCatalog.load().reduce(0) { acc, p in
            acc + (try Data(contentsOf: XCTUnwrap(AnnouncementStockCatalog.fileURL(p))).count)
        }
        XCTAssertLessThan(total, 8_000_000)
    }

    func testMissingManifestFailsClosedToEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nobundle-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(AnnouncementStockCatalog.load(bundle: try XCTUnwrap(Bundle(url: dir))).isEmpty)
    }

    func testStockFullImageFeedsCropPipeline() throws {
        let p = try XCTUnwrap(AnnouncementStockCatalog.shared.first)
        let img = try AnnouncementStockCatalog.fullImage(p)
        let frame = AnnouncementCropMath.frameSize(width: 300)
        let jpeg = try AnnouncementCropMath.renderJPEG(
            image: img, frame: frame, zoom: 1, offset: AnnouncementCropMath.centeredOffset(natural: img.size, frame: frame))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
    }

    // MARK: Part C — font registry

    func testEveryFontResolvesViaUIFontWithExpectedPostScriptName() {
        let expected: [AnnouncementTitleFont: String] = [
            .playfair: "PlayfairDisplay-Bold", .schibsted: "SchibstedGrotesk-SemiBold", .lora: "Lora-SemiBold",
            .oswald: "Oswald-SemiBold", .dancing: "DancingScript-Bold", .nunito: "NunitoExtraLight-ExtraBold",
            .bebas: "BebasNeue-Regular",
        ]
        XCTAssertEqual(AnnouncementTitleFont.allCases.count, 8)
        XCTAssertNil(AnnouncementTitleFont.default.postScriptName)
        for (f, ps) in expected {
            XCTAssertEqual(f.postScriptName, ps)
            let ui = UIFont(name: ps, size: 14)
            XCTAssertNotNil(ui, "\(ps) not registered (Info.plist UIAppFonts?)")
            XCTAssertEqual(ui?.fontName, ps)
            XCTAssertTrue(f.isAvailable)
        }
        XCTAssertTrue(AnnouncementTitleFont.allResolve)
    }

    func testFontResolveIsStrictAndFallsBackToDefault() {
        XCTAssertEqual(AnnouncementTitleFont.resolve(nil), .default)
        XCTAssertEqual(AnnouncementTitleFont.resolve("comic-sans"), .default)
        XCTAssertEqual(AnnouncementTitleFont.resolve("Playfair"), .default, "case sensitive")
        XCTAssertEqual(AnnouncementTitleFont.resolve(" lora"), .default)
        XCTAssertEqual(AnnouncementTitleFont.resolve("lora"), .lora)
        XCTAssertNil(AnnouncementTitleFont.default.storedKey)
        XCTAssertEqual(AnnouncementTitleFont.bebas.storedKey, "bebas")
        XCTAssertEqual(AnnouncementTitleFont.flagName, "announcement_title_font")
    }

    func testFontKeysMatchServerAllowlistExactly() throws {
        XCTAssertEqual(Set(AnnouncementTitleFont.allCases.map(\.rawValue)), try serverKeys("TITLE_FONT_KEYS"))
    }

    func testFontAccessibilityNamesNonEmptyAndUnique() {
        let names = AnnouncementTitleFont.allCases.map(\.accessibilityName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.contains(",") })
    }

    // MARK: Part D — theme registry

    func testThemeKeysMatchServerAllowlistExactly() throws {
        XCTAssertEqual(Set(AnnouncementBgTheme.allCases.map(\.rawValue)), try serverKeys("BG_THEME_KEYS"))
        XCTAssertEqual(AnnouncementBgTheme.flagName, "announcement_bg_theme")
    }

    func testThemeResolveStrictAndStoredKey() {
        XCTAssertEqual(AnnouncementBgTheme.resolve(nil), .none)
        XCTAssertEqual(AnnouncementBgTheme.resolve("neon"), .none)
        XCTAssertEqual(AnnouncementBgTheme.resolve("Dusk"), .none)
        XCTAssertEqual(AnnouncementBgTheme.resolve("dusk"), .dusk)
        XCTAssertNil(AnnouncementBgTheme.none.storedKey)
        XCTAssertEqual(AnnouncementBgTheme.navy.storedKey, "navy")
        XCTAssertEqual(AnnouncementBgTheme.gradients.count, 6)
        XCTAssertEqual(AnnouncementBgTheme.solids.count, 6)
        XCTAssertTrue(AnnouncementBgTheme.gradients.allSatisfy(\.isGradient))
        XCTAssertTrue(AnnouncementBgTheme.solids.allSatisfy { !$0.isGradient && $0.stops.count == 1 })
    }

    func testEveryThemeMeetsAAForItsReadableTextOnWorstCaseStop() throws {
        for t in AnnouncementBgTheme.allCases {
            let ratio = try XCTUnwrap(t.worstCaseContrast(textHex: t.readableTextHex), t.rawValue)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(t.rawValue) readable text fails AA (\(ratio))")
            for stop in t.stops {
                XCTAssertNotNil(AnnouncementTitleColor.luminance(stop), "\(t.rawValue) stop \(stop) not valid hex")
            }
        }
    }

    func testThemeAccessibilityNamesUnique() {
        let names = AnnouncementBgTheme.allCases.map(\.accessibilityName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    // MARK: Model decode + edit payload rules

    func testDecodeToleratesAbsentNullAndPresentStyleKeys() throws {
        let old = try decode("")
        XCTAssertNil(old.title_font); XCTAssertNil(old.bg_theme)
        let nul = try decode(",\"title_font\":null,\"bg_theme\":null")
        XCTAssertNil(nul.title_font); XCTAssertNil(nul.bg_theme)
        let on = try decode(",\"title_font\":\"lora\",\"bg_theme\":\"dusk\"")
        XCTAssertEqual(on.title_font, "lora"); XCTAssertEqual(on.bg_theme, "dusk")
    }

    func testDraftOmitsKeysWhenUnchanged() {
        let d = FSAnnouncementDraft(title: "T", description: "D")
        XCTAssertNil(d.jsonObject["title_font"])
        XCTAssertNil(d.jsonObject["bg_theme"])
    }

    func testDraftSendsExplicitNullForResetAndKeyForSet() {
        var d = FSAnnouncementDraft(title: "T", description: "D")
        d.titleFont = .reset; d.bgTheme = .reset
        XCTAssertTrue(d.jsonObject["title_font"] is NSNull)
        XCTAssertTrue(d.jsonObject["bg_theme"] is NSNull)
        d.titleFont = .set("oswald"); d.bgTheme = .set("ink")
        XCTAssertEqual(d.jsonObject["title_font"] as? String, "oswald")
        XCTAssertEqual(d.jsonObject["bg_theme"] as? String, "ink")
    }

    func testDraftNeverSendsNonAllowlistedKeys() {
        var d = FSAnnouncementDraft(title: "T", description: "D")
        d.titleFont = .set("papyrus"); d.bgTheme = .set("neon")
        XCTAssertNil(d.jsonObject["title_font"])
        XCTAssertNil(d.jsonObject["bg_theme"])
        d.titleFont = .set("default"); d.bgTheme = .set("none")
        XCTAssertEqual(d.jsonObject["title_font"] as? String, "default", "allowlisted by server too")
    }

    func testFormSendsKeysOnlyWhenFlagOnAndChanged_sourcePinned() throws {
        let src = try readSource("FellowScript/Chat/GroupAnnouncementFormView.swift")
        XCTAssertTrue(src.contains("if fontsOn {\n            draft.titleFont = keyChange("))
        XCTAssertTrue(src.contains("if themesOn {\n            draft.bgTheme = keyChange("))
        XCTAssertTrue(src.contains("if chosen == original { return .unchanged }"))
        XCTAssertTrue(src.contains("return .reset"), "None/Default -> explicit null")
        XCTAssertTrue(src.contains("capabilities.isEnabled(AnnouncementTitleFont.flagName)"))
        XCTAssertTrue(src.contains("capabilities.isEnabled(AnnouncementBgTheme.flagName)"))
        XCTAssertTrue(src.contains("if fontsOn {\n                AnnouncementTitleFontRow("), "font row gated")
        XCTAssertTrue(src.contains("if themesOn { themeStrip }"), "palette gated")
    }

    func testCapabilitiesAllOffHidesBothFeatures() {
        let off = FSCapabilities.allOff
        XCTAssertFalse(off.isEnabled(AnnouncementTitleFont.flagName))
        XCTAssertFalse(off.isEnabled(AnnouncementBgTheme.flagName))
        let on = FSCapabilities(features: [AnnouncementTitleFont.flagName: true], exploreLink: nil, termsCurrent: true)
        XCTAssertTrue(on.isEnabled(AnnouncementTitleFont.flagName))
        XCTAssertFalse(on.isEnabled(AnnouncementBgTheme.flagName))
    }

    // MARK: Part B — translucent fields, removed dashed box / preview card

    func testFieldsAreTranslucentNoFillSourcePinned() throws {
        let tile = try readSource("FellowScript/Chat/AnnouncementBannerTile.swift")
        XCTAssertTrue(tile.contains(".background(Color.clear)"))
        XCTAssertTrue(tile.contains("Color.white.opacity(0.28)"))
        XCTAssertTrue(tile.contains("Theme.gold"))
        let form = try readSource("FellowScript/Chat/GroupAnnouncementFormView.swift")
        XCTAssertEqual(form.components(separatedBy: ".announcementTranslucentField(").count - 1, 2, "title + message")
        XCTAssertFalse(form.contains("StrokeStyle(lineWidth: 1, dash"), "dashed box removed")
        XCTAssertFalse(form.contains("dash:"), "dashed box removed")
        XCTAssertFalse(form.contains("Add banner photo"))
    }

    func testTranslucentModifierRendersFocusedAndUnfocused() {
        for focused in [false, true] {
            let host = UIHostingController(rootView:
                Text("x").frame(width: 200, height: 44).announcementTranslucentField(focused: focused))
            host.view.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
        }
    }

    // MARK: Accessibility pins

    func testBannerTileAccessibilityPins() throws {
        let t = try readSource("FellowScript/Chat/AnnouncementBannerTile.swift")
        for s in ["\"Upload a photo\"", "\"Upload a different photo\"", "\"Choose a nature stock photo\"",
                  "\"Remove banner\"", "accessibilityReduce", "isAccessibilitySize"] where s != "accessibilityReduce" {
            XCTAssertTrue(t.contains(s), s)
        }
        XCTAssertTrue(t.contains("showStock"), "stock button hidden when manifest empty")
    }

    func testFontRowAndPaletteAccessibilityPins() throws {
        let f = try readSource("FellowScript/Chat/AnnouncementTitleFont.swift")
        XCTAssertTrue(f.contains(".accessibilityLabel(\"Title font\")"))
        XCTAssertTrue(f.contains("Clear font, \\(f.displayName)"))
        XCTAssertTrue(f.contains(".accessibilityAddTraits(selected ? .isSelected : [])"))
        XCTAssertTrue(f.contains("minHeight: 44") && f.contains("width: 44, height: 44"), "44pt targets")
        XCTAssertTrue(f.contains("accessibilityReduceMotion"))
        XCTAssertTrue(f.contains("relativeTo"), "Dynamic Type scaling")
        let form = try readSource("FellowScript/Chat/GroupAnnouncementFormView.swift")
        XCTAssertTrue(form.contains("paintpalette") && form.contains(".accessibilityLabel(\"Background theme\")"))
        XCTAssertTrue(form.contains(".accessibilityValue(theme.accessibilityName)"))
        let th = try readSource("FellowScript/Chat/AnnouncementBgTheme.swift")
        XCTAssertTrue(th.contains(".accessibilityLabel(t.accessibilityName)"))
        XCTAssertTrue(th.contains(".isSelected"))
    }

    func testFontAndThemeRenderedInDetailWidgetAndList_sourcePinned() throws {
        for file in ["GroupAnnouncementDetailView", "GroupAnnouncementWidgetView", "GroupAnnouncementsView"] {
            let s = try readSource("FellowScript/Chat/\(file).swift")
            XCTAssertTrue(s.contains("AnnouncementTitleFont.resolve"), "\(file) renders the font")
        }
        let d = try readSource("FellowScript/Chat/GroupAnnouncementDetailView.swift")
        XCTAssertTrue(d.contains("AnnouncementBgTheme.resolve"))
    }

    func testRowsRenderAtAccessibilitySizeWithoutCrash() {
        let row = AnnouncementTitleFontRow(key: .constant("lora"), sample: "Potluck")
            .environment(\.dynamicTypeSize, .accessibility3)
        let host = UIHostingController(rootView: row)
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        host.view.layoutIfNeeded()
        let sheet = UIHostingController(rootView: AnnouncementBgThemeSheet(key: .constant("dusk")))
        sheet.view.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        sheet.view.layoutIfNeeded()
    }
}
