// AnnouncementTitleColorTests.swift — testing gate for task
// 20260929-announcement-title-color-crop-layer-fix. Covers:
//   * AnnouncementTitleColor: strict #RRGGBB validation, normalization, sRGB
//     conversion from wide-gamut colors, contrast/legibility, fallback rendering
//   * FSGroupAnnouncement decoding tolerance and FSAnnouncementDraft JSON semantics
//   * Crop-to-save race regression (busy flag set before the cover dismisses) and
//     crop view layout (safe-area header, clipped photo, opaque panel), source-pinned
//     following AnnouncementBannerCropTests.

import XCTest
import SwiftUI
import UIKit
@testable import FellowScript

@MainActor
final class AnnouncementTitleColorTests: XCTestCase {

    private typealias C = AnnouncementTitleColor

    private func rgba(_ c: Color) -> (r: Int, g: Int, b: Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    // MARK: validation

    func testAcceptsStrictSixDigitHexInEitherCase() {
        for s in ["#FFC61A", "#ffc61a", "#000000", "#aBcDeF", "#123456"] { XCTAssertTrue(C.isValidHex(s), s) }
    }

    func testRejectsEverythingElse() {
        let bad: [String?] = [nil, "", "#FFF", "#FFFF", "FFFFFF", "#12345", "#1234567", "#GGGGGG", "red",
                              "rgb(1,2,3)", " #FFFFFF", "#FFFFFF ", "#FFFFFF\n", "\n#FFFFFF", "#FFFFFF;",
                              "#FFFFFF; background:url(x)", "javascript:alert(1)", "url(#FFFFFF)",
                              "#ＦＦＦＦＦＦ", "#١٢٣٤٥٦", "#FFFFFÉ", "#FF\u{0}FFF", "0xFFFFFF", "##FFFFF"]
        for s in bad { XCTAssertFalse(C.isValidHex(s), s ?? "nil"); XCTAssertNil(C.normalized(s)) }
    }

    func testNormalizedUppercasesAndIsDefaultSemantics() {
        XCTAssertEqual(C.normalized("#ffc61a"), "#FFC61A")
        XCTAssertTrue(C.isDefault(nil))
        XCTAssertTrue(C.isDefault("garbage"))
        XCTAssertTrue(C.isDefault("#f2f2f2"))
        XCTAssertFalse(C.isDefault("#FFC61A"))
    }

    // MARK: hex parsing and sRGB conversion

    func testRgbParsing() throws {
        let c = try XCTUnwrap(C.rgb("#FF8000"))
        XCTAssertEqual(c.r, 1, accuracy: 1e-9)
        XCTAssertEqual(c.g, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.b, 0, accuracy: 1e-9)
        XCTAssertNil(C.rgb("nope"))
    }

    func testHexFromSRGBColorRoundTrips() {
        for h in ["#FFC61A", "#000000", "#FFFFFF", "#123ABC", "#9CD3FF"] {
            XCTAssertEqual(C.hex(from: Color(hex: h)), h)
        }
    }

    func testHexFromWideGamutColorConvertsToSRGB() throws {
        // Display P3 pure-ish red is outside sRGB: it must clamp into #RRGGBB, not crash or emit junk.
        let p3 = try XCTUnwrap(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [1, 0, 0, 1]))
        let hex = try XCTUnwrap(C.hex(from: Color(UIColor(cgColor: p3))))
        XCTAssertTrue(C.isValidHex(hex), hex)
        XCTAssertEqual(hex, hex.uppercased())
        // P3 mid-gray equals sRGB mid-gray to within rounding after conversion.
        let g = try XCTUnwrap(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0.5, 0.5, 0.5, 1]))
        let gh = try XCTUnwrap(C.hex(from: Color(UIColor(cgColor: g))))
        XCTAssertTrue(C.isValidHex(gh))
        let comps = try XCTUnwrap(C.rgb(gh))
        XCTAssertEqual(comps.r, comps.g, accuracy: 0.01); XCTAssertEqual(comps.g, comps.b, accuracy: 0.01)
        XCTAssertEqual(comps.r, 0.5, accuracy: 0.03)
    }

    // MARK: fallback rendering

    func testBannerColorFallsBackToDefaultForInvalid() {
        let def = rgba(Color(hex: C.defaultHex))
        for bad in [nil, "red", "#FFF", "x; color:red", ""] as [String?] {
            let got = rgba(C.bannerColor(bad)); XCTAssertEqual(got.r, def.r); XCTAssertEqual(got.g, def.g); XCTAssertEqual(got.b, def.b)
        }
        let sky = rgba(C.bannerColor("#9cd3ff")); XCTAssertEqual([sky.r, sky.g, sky.b], [0x9C, 0xD3, 0xFF])
    }

    func testSurfaceColorAppliesOnlyAAColorsElseFallback() {
        let fb = Color(hex: "#010203")
        let fbc = rgba(fb)
        for v in [nil, "junk", "#F2F2F2", "#222222"] as [String?] {
            let got = rgba(C.surfaceColor(v, fallback: fb)); XCTAssertEqual([got.r, got.g, got.b], [fbc.r, fbc.g, fbc.b], v ?? "nil")
        }
        let sky = rgba(C.surfaceColor("#9CD3FF", fallback: fb)); XCTAssertEqual([sky.r, sky.g, sky.b], [0x9C, 0xD3, 0xFF])
    }

    // MARK: palette and contrast

    func testContrastKnownValuesAndInvalidInputs() throws {
        XCTAssertEqual(try XCTUnwrap(C.contrastRatio("#000000", "#FFFFFF")), 21, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(C.contrastRatio("#FFFFFF", "#FFFFFF")), 1, accuracy: 1e-9)
        XCTAssertNil(C.contrastRatio("bad", "#FFFFFF"))
    }

    func testPaletteIsUniqueNamedValidAndAllPassAA() throws {
        XCTAssertEqual(C.swatches.first?.hex, C.defaultHex)
        XCTAssertEqual(Set(C.swatches.map(\.hex)).count, C.swatches.count)
        XCTAssertEqual(Set(C.swatches.map(\.name)).count, C.swatches.count)
        for s in C.swatches {
            XCTAssertTrue(C.isValidHex(s.hex)); XCTAssertFalse(s.name.isEmpty)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(C.contrastRatio(s.hex, C.scrimWorstCaseHex)), 4.5, s.name)
            XCTAssertFalse(C.needsLegibilityWarning(s.hex), s.name)
        }
    }

    func testLegibilityWarningAndNames() {
        XCTAssertTrue(C.needsLegibilityWarning("#222222"))
        XCTAssertFalse(C.needsLegibilityWarning(nil))
        XCTAssertFalse(C.needsLegibilityWarning("junk"))
        XCTAssertEqual(C.name(for: nil), "Parchment (default)")
        XCTAssertEqual(C.name(for: "#ffc61a"), "Gold")
        XCTAssertEqual(C.name(for: "#123456"), "Custom color #123456")
    }

    // MARK: model decoding and draft JSON

    private func decode(_ extra: String) throws -> FSGroupAnnouncement {
        let json = """
        {"id":"a","group_id":"g","creator_id":"u","creator_username":"ann","title":"T","description":"D",
         "banner_url":null,"publish_at":"2026-01-01T00:00:00+00:00","created_at":"2026-01-01T00:00:00+00:00",
         "updated_at":"2026-01-01T00:00:00+00:00","published":true,"can_edit":true\(extra)}
        """
        return try JSONDecoder().decode(FSGroupAnnouncement.self, from: Data(json.utf8))
    }

    func testDecodingToleratesAbsentNullAndPresentTitleColor() throws {
        XCTAssertNil(try decode("").title_color)
        XCTAssertNil(try decode(",\"title_color\":null").title_color)
        XCTAssertEqual(try decode(",\"title_color\":\"#FFC61A\"").title_color, "#FFC61A")
    }

    func testDraftJSONOmitsResetsAndSetsColor() throws {
        var d = FSAnnouncementDraft(title: "T", description: "D")
        XCTAssertNil(d.jsonObject["title_color"], "unchanged omits the key")
        d.titleColor = .reset
        XCTAssertTrue(d.jsonObject["title_color"] is NSNull, "reset is explicit null")
        d.titleColor = .set("#ffc61a")
        XCTAssertEqual(d.jsonObject["title_color"] as? String, "#FFC61A")
        d.titleColor = .set("red; background:url(x)")
        XCTAssertNil(d.jsonObject["title_color"], "invalid client value never leaves the device")
    }

    // MARK: crop-to-save race and layout (source-pinned)

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testBusyFlagIsSetBeforeCropCoverDismissesAndUploadStarts() throws {
        let src = try readSource("FellowScript/Chat/GroupAnnouncementFormView.swift")
        let confirm = try XCTUnwrap(src.range(of: "AnnouncementBannerCropView(image: cropImage"))
        let tail = src[confirm.lowerBound...]
        let busy = try XCTUnwrap(tail.range(of: "self.bannerBusy = true")).lowerBound
        let dismiss = try XCTUnwrap(tail.range(of: "self.cropImage = nil\n                    Task")).lowerBound
        let upload = try XCTUnwrap(tail.range(of: "Task { await uploadCropped(jpeg) }")).lowerBound
        XCTAssertTrue(busy < dismiss && dismiss < upload, "busy set before the cover dismisses and before the upload Task starts")
    }

    func testSubmitIsGatedOnBannerBusyAndLabelShowsUploading() throws {
        let src = try readSource("FellowScript/Chat/GroupAnnouncementFormView.swift")
        XCTAssertTrue(src.contains("!saving && !bannerBusy"))
        XCTAssertTrue(src.contains(".disabled(!canSubmit)"))
        XCTAssertTrue(src.contains("bannerBusy ? \"Uploading…\""))
    }

    func testUploadFailureDoesNotSetBannerKeyAndBusyAlwaysClears() throws {
        let src = try readSource("FellowScript/Chat/GroupAnnouncementFormView.swift")
        let fn = try XCTUnwrap(src.range(of: "private func uploadCropped"))
        let body = String(src[fn.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("defer { bannerBusy = false }"))
        let keyAssign = try XCTUnwrap(body.range(of: "banner = .uploaded(key)")).lowerBound
        let tryUpload = try XCTUnwrap(body.range(of: "try await vm.uploadBanner")).lowerBound
        let catchAt = try XCTUnwrap(body.range(of: "} catch")).lowerBound
        XCTAssertTrue(tryUpload < keyAssign && keyAssign < catchAt, "key only assigned after a successful upload")
    }

    func testCropViewHeaderInSafeAreaPhotoClippedAndPanelOpaque() throws {
        let src = try readSource("FellowScript/Chat/AnnouncementBannerCropView.swift")
        // Header is a safe-area top inset, not a zIndex layer inside a GeometryReader.
        XCTAssertTrue(src.contains(".safeAreaInset(edge: .top, spacing: 0)"))
        XCTAssertFalse(src.contains("header.zIndex") || src.contains(".zIndex(1)\n                    .frame"), "header no longer relies on zIndex")
        // Opaque root that ignores safe area, opaque controls panel.
        XCTAssertTrue(src.contains("surface.ignoresSafeArea()"))
        XCTAssertTrue(src.contains(".background(surface)"))
        // The photo is clipped to the frame before gestures/overlays attach.
        let clip = try XCTUnwrap(src.range(of: ".clipped()   // the photo never renders outside")).lowerBound
        let gesture = try XCTUnwrap(src.range(of: ".gesture(dragGesture(fs)")).lowerBound
        XCTAssertTrue(clip < gesture, "gestures attach to the clipped frame only")
        // The old 0.6 dim overlay (even-odd fill) that let the photo bleed is gone.
        XCTAssertFalse(src.contains("eoFill") || src.contains("opacity(0.6)"))
        // Overlay decoration cannot steal touches.
        XCTAssertTrue(src.contains(".allowsHitTesting(false)"))
        // 44pt targets and large-text fallback layout.
        XCTAssertTrue(src.contains("ViewThatFits(in: .horizontal)"))
        for label in ["Zoom out", "Zoom in", "Reset crop", "Zoom"] { XCTAssertTrue(src.contains("accessibilityLabel(\"\(label)\")"), label) }
        XCTAssertTrue(src.contains(".frame(width: 44, height: 44)"))
    }

    func testCropViewRendersAtSmallAndLargeSizesWithoutCrash() {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1600)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1600))
        }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 430, height: 932)] {
            let host = UIHostingController(rootView: AnnouncementBannerCropView(image: img, onCancel: {}, onConfirm: { _ in }))
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
            XCTAssertEqual(host.view.bounds.size, size)
        }
    }
}
