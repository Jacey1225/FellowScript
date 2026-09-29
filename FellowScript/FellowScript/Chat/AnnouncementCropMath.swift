// AnnouncementCropMath.swift — pure crop geometry + encode helpers for the
// announcement banner cropper (task 20260929-announcement-banner-crop-list-style).
// No SwiftUI state here so the math is unit-testable. Offset is the top-left of
// the displayed image relative to the crop frame's top-left, in frame points.
// Every failure throws; callers must never upload an uncropped fallback.

import UIKit
import ImageIO

enum AnnouncementCropError: LocalizedError {
    case decode
    case encode
    var errorDescription: String? {
        switch self {
        case .decode: return "Couldn't read that photo. Choose a JPG, PNG, or WebP."
        case .encode: return "Couldn't save the crop. Please try again."
        }
    }
}

enum AnnouncementCropMath {
    static func frameSize(width: CGFloat) -> CGSize {
        CGSize(width: width, height: width / AnnouncementLimits.bannerAspect)
    }

    /// Scale at which the image exactly covers the frame (zoom 1).
    static func coverScale(natural: CGSize, frame: CGSize) -> CGFloat {
        max(frame.width / natural.width, frame.height / natural.height)
    }

    static func displaySize(natural: CGSize, frame: CGSize, zoom: CGFloat) -> CGSize {
        let s = coverScale(natural: natural, frame: frame) * zoom
        return CGSize(width: natural.width * s, height: natural.height * s)
    }

    /// Clamp so the image always covers the frame (no empty edges).
    static func clampOffset(_ offset: CGPoint, natural: CGSize, frame: CGSize, zoom: CGFloat) -> CGPoint {
        let d = displaySize(natural: natural, frame: frame, zoom: zoom)
        return CGPoint(x: min(0, max(frame.width - d.width, offset.x)),
                       y: min(0, max(frame.height - d.height, offset.y)))
    }

    static func centeredOffset(natural: CGSize, frame: CGSize, zoom: CGFloat = 1) -> CGPoint {
        let d = displaySize(natural: natural, frame: frame, zoom: zoom)
        return clampOffset(CGPoint(x: (frame.width - d.width) / 2, y: (frame.height - d.height) / 2),
                           natural: natural, frame: frame, zoom: zoom)
    }

    static func clampZoom(_ z: CGFloat) -> CGFloat {
        min(AnnouncementLimits.cropZoomMax, max(1, z))
    }

    /// Change zoom keeping the frame-space `anchor` fixed over the same image pixel.
    static func zoomAround(zoom: CGFloat, offset: CGPoint, to newZoom: CGFloat, anchor: CGPoint,
                           natural: CGSize, frame: CGSize) -> (zoom: CGFloat, offset: CGPoint) {
        let z = clampZoom(newZoom)
        let base = coverScale(natural: natural, frame: frame)
        let oldScale = base * zoom, newScale = base * z
        let ix = (anchor.x - offset.x) / oldScale
        let iy = (anchor.y - offset.y) / oldScale
        let o = clampOffset(CGPoint(x: anchor.x - ix * newScale, y: anchor.y - iy * newScale),
                            natural: natural, frame: frame, zoom: z)
        return (z, o)
    }

    /// Where to draw the full image inside an output canvas of `outputWidth`.
    static func outputDrawRect(natural: CGSize, frame: CGSize, zoom: CGFloat, offset: CGPoint,
                               outputWidth: CGFloat) -> CGRect {
        let f = outputWidth / frame.width
        let d = displaySize(natural: natural, frame: frame, zoom: zoom)
        return CGRect(x: offset.x * f, y: offset.y * f, width: d.width * f, height: d.height * f)
    }

    /// Decode with EXIF orientation applied (and HEIC handled by ImageIO),
    /// downsampled so a huge photo can't exhaust memory.
    static func decode(data: Data, maxPixel: CGFloat = 4096) throws -> UIImage {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { throw AnnouncementCropError.decode }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary),
              cg.width > 0, cg.height > 0 else { throw AnnouncementCropError.decode }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// Bake the current crop into a canonical-size JPEG. Re-encoding drops
    /// EXIF/location and flattens transparency onto a dark ground.
    static func renderJPEG(image: UIImage, frame: CGSize, zoom: CGFloat, offset: CGPoint) throws -> Data {
        let outW = AnnouncementLimits.bannerOutputWidth
        let size = CGSize(width: outW, height: (outW / AnnouncementLimits.bannerAspect).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = true
        let rect = outputDrawRect(natural: image.size, frame: frame, zoom: zoom, offset: offset, outputWidth: outW)
        let data = UIGraphicsImageRenderer(size: size, format: fmt).jpegData(withCompressionQuality: AnnouncementLimits.bannerJpegQuality) { ctx in
            UIColor(white: 0.08, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: rect)
        }
        guard !data.isEmpty else { throw AnnouncementCropError.encode }
        return data
    }
}
