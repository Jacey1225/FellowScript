// AnnouncementBannerCropTests.swift — testing gate for task
// 20260929-announcement-banner-crop-list-style. Covers:
//   * AnnouncementCropMath: cover scale, clamping (no empty edges), centering,
//     zoom-around-anchor, output draw rect, decode (EXIF-free / garbage throws),
//     renderJPEG (canonical 1536x512 JPEG, tall + white sources)
//   * widget / banner layout: a tall photo cannot grow the 3:1 box (the clipping
//     regression), plus source-pinned structure for the widget stack (image and
//     scrim as overlays, text above) and the Notes-card list row.

import XCTest
import SwiftUI
import UIKit
@testable import FellowScript

@MainActor
final class AnnouncementBannerCropTests: XCTestCase {

    private let frame = CGSize(width: 300, height: 100)

    // MARK: constants

    func testCanonicalGeometryConstants() {
        XCTAssertEqual(AnnouncementLimits.bannerAspect, 3)
        XCTAssertEqual(AnnouncementLimits.bannerOutputWidth, 1536)
        XCTAssertEqual(AnnouncementLimits.bannerJpegQuality, 0.85, accuracy: 0.0001)
        XCTAssertEqual(AnnouncementLimits.cropZoomMax, 4)
        XCTAssertEqual(AnnouncementCropMath.frameSize(width: 300), frame)
    }

    // MARK: cover / clamp / center

    func testCoverScalePicksLargerAxisRatio() {
        XCTAssertEqual(AnnouncementCropMath.coverScale(natural: CGSize(width: 3000, height: 3000), frame: frame), 0.1, accuracy: 1e-9)
        XCTAssertEqual(AnnouncementCropMath.coverScale(natural: CGSize(width: 6000, height: 1000), frame: frame), 0.1, accuracy: 1e-9)
        XCTAssertEqual(AnnouncementCropMath.coverScale(natural: CGSize(width: 600, height: 200), frame: frame), 0.5, accuracy: 1e-9)
    }

    func testCenteredOffsetForTallPhotoCentersVerticallyAndCovers() {
        let nat = CGSize(width: 1000, height: 4000)
        let o = AnnouncementCropMath.centeredOffset(natural: nat, frame: frame)
        let d = AnnouncementCropMath.displaySize(natural: nat, frame: frame, zoom: 1)
        XCTAssertEqual(o.x, 0, accuracy: 1e-9)
        XCTAssertEqual(o.y, (frame.height - d.height) / 2, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(d.height + o.y, frame.height - 1e-9)
    }

    func testClampOffsetNeverLeavesEmptyEdges() {
        let nat = CGSize(width: 1000, height: 1000)
        let d = AnnouncementCropMath.displaySize(natural: nat, frame: frame, zoom: 1)
        XCTAssertEqual(AnnouncementCropMath.clampOffset(CGPoint(x: 50, y: 50), natural: nat, frame: frame, zoom: 1), .zero)
        let far = AnnouncementCropMath.clampOffset(CGPoint(x: -9999, y: -9999), natural: nat, frame: frame, zoom: 1)
        XCTAssertEqual(far.x, frame.width - d.width, accuracy: 1e-9)
        XCTAssertEqual(far.y, frame.height - d.height, accuracy: 1e-9)
    }

    func testExactAspectImageAtZoomOneHasNoPanRange() {
        let o = AnnouncementCropMath.clampOffset(CGPoint(x: -40, y: 30), natural: CGSize(width: 600, height: 200), frame: frame, zoom: 1)
        XCTAssertEqual(o.x, 0, accuracy: 1e-9); XCTAssertEqual(o.y, 0, accuracy: 1e-9)
    }

    // MARK: zoom

    func testClampZoomBounds() {
        XCTAssertEqual(AnnouncementCropMath.clampZoom(0.2), 1)
        XCTAssertEqual(AnnouncementCropMath.clampZoom(99), AnnouncementLimits.cropZoomMax)
        XCTAssertEqual(AnnouncementCropMath.clampZoom(2.5), 2.5)
    }

    func testZoomAroundKeepsAnchorOverSameImagePixelAndStaysCovering() {
        let nat = CGSize(width: 2000, height: 1000)
        let start = AnnouncementCropMath.centeredOffset(natural: nat, frame: frame)
        let anchor = CGPoint(x: 220, y: 40)
        let base = AnnouncementCropMath.coverScale(natural: nat, frame: frame)
        let before = CGPoint(x: (anchor.x - start.x) / base, y: (anchor.y - start.y) / base)
        let r = AnnouncementCropMath.zoomAround(zoom: 1, offset: start, to: 2, anchor: anchor, natural: nat, frame: frame)
        XCTAssertEqual(r.zoom, 2)
        XCTAssertEqual((anchor.x - r.offset.x) / (base * 2), before.x, accuracy: 1e-6)
        XCTAssertEqual((anchor.y - r.offset.y) / (base * 2), before.y, accuracy: 1e-6)
        XCTAssertEqual(r.offset, AnnouncementCropMath.clampOffset(r.offset, natural: nat, frame: frame, zoom: r.zoom))
        XCTAssertEqual(AnnouncementCropMath.zoomAround(zoom: 1, offset: start, to: 50, anchor: anchor, natural: nat, frame: frame).zoom,
                       AnnouncementLimits.cropZoomMax)
    }

    func testOutputDrawRectScalesFrameToCanonicalWidth() {
        let nat = CGSize(width: 1000, height: 1000)
        let off = AnnouncementCropMath.centeredOffset(natural: nat, frame: frame, zoom: 2)
        let r = AnnouncementCropMath.outputDrawRect(natural: nat, frame: frame, zoom: 2, offset: off, outputWidth: 1536)
        let f: CGFloat = 1536 / 300
        let d = AnnouncementCropMath.displaySize(natural: nat, frame: frame, zoom: 2)
        XCTAssertEqual(r.width, d.width * f, accuracy: 1e-6)
        XCTAssertEqual(r.minX, off.x * f, accuracy: 1e-6)
        // The draw rect fully covers the 1536x512 canvas.
        XCTAssertLessThanOrEqual(r.minX, 1e-6); XCTAssertLessThanOrEqual(r.minY, 1e-6)
        XCTAssertGreaterThanOrEqual(r.maxX, 1536 - 1e-6); XCTAssertGreaterThanOrEqual(r.maxY, 512 - 1e-6)
    }

    // MARK: decode / encode

    private func solidPNG(size: CGSize, color: UIColor, alpha: Bool = false) -> Data {
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = !alpha
        return UIGraphicsImageRenderer(size: size, format: fmt).pngData { ctx in
            color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testDecodeGarbageThrowsDecodeError() {
        XCTAssertThrowsError(try AnnouncementCropMath.decode(data: Data([0, 1, 2, 3]))) {
            XCTAssertEqual($0 as? AnnouncementCropError, .decode)
        }
        XCTAssertThrowsError(try AnnouncementCropMath.decode(data: Data()))
    }

    func testDecodeDownsamplesHugeImageToMaxPixel() throws {
        let img = try AnnouncementCropMath.decode(data: solidPNG(size: CGSize(width: 2000, height: 1000), color: .red), maxPixel: 500)
        XCTAssertLessThanOrEqual(max(img.size.width, img.size.height), 500)
        XCTAssertEqual(img.size.width / img.size.height, 2, accuracy: 0.02)
    }

    func testRenderJPEGIsCanonical1536x512ForTallPhoto() throws {
        let img = try AnnouncementCropMath.decode(data: solidPNG(size: CGSize(width: 900, height: 3600), color: .systemTeal))
        let off = AnnouncementCropMath.centeredOffset(natural: img.size, frame: frame)
        let data = try AnnouncementCropMath.renderJPEG(image: img, frame: frame, zoom: 1, offset: off)
        XCTAssertEqual(data.prefix(3), Data([0xFF, 0xD8, 0xFF])) // JPEG magic
        let out = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(out.size.width * out.scale, 1536, accuracy: 0.5)
        XCTAssertEqual(out.size.height * out.scale, 512, accuracy: 0.5)
        XCTAssertLessThan(data.count, AnnouncementLimits.bannerMaxBytes)
    }

    func testRenderJPEGFlattensTransparencyOntoDarkGround() throws {
        let img = try AnnouncementCropMath.decode(data: solidPNG(size: CGSize(width: 600, height: 200), color: .clear, alpha: true))
        let data = try AnnouncementCropMath.renderJPEG(image: img, frame: frame, zoom: 1, offset: .zero)
        let cg = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -cg.width / 2, y: -cg.height / 2, width: cg.width, height: cg.height))
        XCTAssertLessThan(Int(px[0]), 60) // dark, not white/transparent-black artifact
        XCTAssertEqual(px[3], 255)
    }

    // MARK: layout regression (widget clipping)

    private func fitted(_ view: some View, width: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    func testTallPhotoCannotGrowTheBannerBox() {
        let tall = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 1200)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 1200))
        }
        let size = fitted(AnnouncementBannerImage(source: .image(tall)), width: 360)
        XCTAssertEqual(size.width, 360, accuracy: 1)
        XCTAssertEqual(size.height, 120, accuracy: 1, "3:1 box must stay 120pt high at 360pt wide, not the photo's natural height")
    }

    func testWidgetCardBodyIsThreeToOneRegardlessOfBannerURL() {
        for banner in [nil, "https://cdn.example/tall-3000x6000.jpg"] {
            let item = FSGroupAnnouncement(id: "p", group_id: "g", creator_id: nil, creator_username: "sam", title: "Youth night moved to Friday",
                                           description: "", banner_url: banner, publish_at: "2026-09-29T12:00:00Z",
                                           created_at: "2026-09-29T12:00:00Z", updated_at: "2026-09-29T12:00:00Z",
                                           published: true, can_edit: false)
            let size = fitted(AnnouncementWidgetCardBody(item: item), width: 360)
            XCTAssertEqual(size.height, 120, accuracy: 1)
            XCTAssertEqual(size.width, 360, accuracy: 1)
        }
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testWidgetSourceStacksBannerAndScrimUnderTextInsideClip() throws {
        let src = try readSource("FellowScript/Chat/GroupAnnouncementWidgetView.swift")
        let base = try XCTUnwrap(src.range(of: "Color.clear")).lowerBound
        let img = try XCTUnwrap(src.range(of: "AsyncImage(url: url)")).lowerBound
        let scrim = try XCTUnwrap(src.range(of: "black.opacity(0.78)")).lowerBound
        let text = try XCTUnwrap(src.range(of: ".overlay(alignment: .bottomLeading) { cardText }")).lowerBound
        let clip = try XCTUnwrap(src.range(of: ".clipShape(RoundedRectangle(cornerRadius: Theme.radius))")).lowerBound
        XCTAssertTrue(base < img && img < scrim && scrim < text && text < clip)
        XCTAssertTrue(src.contains(".aspectRatio(AnnouncementLimits.bannerAspect, contentMode: .fit)"))
        XCTAssertTrue(src.contains("Text(\"View\")") && src.contains("Text(\"ANNOUNCEMENT\")"))
        XCTAssertFalse(src.contains("minHeight: height"), "old fixed 72pt height frame must be gone")
    }

    func testListRowUsesNotesGlassCardStyle() throws {
        let list = try readSource("FellowScript/Chat/GroupAnnouncementsView.swift")
        let notes = try readSource("FellowScript/Notes/NotesRowViews.swift")
        XCTAssertTrue(list.contains(".glassCard(cornerRadius: 20)"))
        XCTAssertTrue(notes.contains(".glassCard(cornerRadius: 20)"))
        XCTAssertTrue(list.contains(".padding(.horizontal, 16)") && list.contains(".padding(.vertical, 15)"))
        XCTAssertTrue(list.contains("top: 6, leading: 20, bottom: 6, trailing: 20"))
        XCTAssertFalse(list.contains(".background(Theme.cardBg)"), "old outline-less row background must be gone")
    }
}
