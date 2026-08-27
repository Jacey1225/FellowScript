// LoadingScreenAssetTransparencyTests.swift — regression coverage for task
// 20260824-loading-screen-visual-fix, testing step, covering frontend's
// fix to the bundled FellowScript/LoadingScreen/loading-screen.mov asset.
//
// Background (see intake-spec.md / frontend.json for this task): the
// previously-bundled derivative was produced with a plain `ffmpeg
// hevc_videotoolbox` transcode. On desktop, a single offline frame grab via
// AVAssetImageGenerator decoded it with clean alpha (background fully
// transparent, blob fully opaque) — but that offline path is lenient and
// masked the real bug. Live, streaming decode of that same asset (the path
// AVPlayerLayer actually uses on-device) rendered the background as opaque
// (a whitish haze bleeding through / no transparency at all), which is what
// the user actually saw. The fix was re-transcoding via `avconvert --preset
// PresetHEVCHighestQualityWithAlpha` (AVFoundation's own export pipeline)
// instead of ffmpeg.
//
// This test proves the *fix*, not just the asset's container metadata: it
// decodes the real bundled asset through AVPlayerItemVideoOutput, which
// pulls CVPixelBuffers off the same VideoToolbox streaming-decode path
// AVPlayerLayer uses for on-screen compositing — deliberately NOT
// AVAssetImageGenerator, which this task's investigation found does not
// reproduce the bug. Verified empirically before writing this test: probing
// a freshly-regenerated plain-ffmpeg derivative of the same source with this
// exact technique reports corner alpha = 255 (fully opaque — reproduces the
// reported bug), while probing the currently-bundled avconvert-based
// derivative reports corner alpha = 0 (genuinely transparent) — i.e. this
// technique actually discriminates the buggy asset from the fixed one, so a
// regression back to a naive ffmpeg (or similarly alpha-lossy) transcode of
// this asset will fail this test.
//
// Also covers the "still icon/mark scale, not full-bleed" sizing acceptance
// criterion by asserting on LoopingVideoPlayer's fixed frame size, since
// that's a plain, cheap, non-flaky check worth keeping alongside the
// heavier asset-decode test above.

import XCTest
import AVFoundation
import CoreVideo
@testable import FellowScript

final class LoadingScreenAssetTransparencyTests: XCTestCase {

    /// Mirrors PlayerContainerView.configure(...)'s exact resource lookup —
    /// if this fails, the asset is missing from the bundle, which is itself
    /// a regression (the app's own onFailure() branch would fire).
    private func bundledAssetURL() throws -> URL {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "loading-screen", withExtension: "mov"),
            "loading-screen.mov must be bundled in the app target (same lookup PlayerContainerView.configure uses)"
        )
        return url
    }

    private func waitForItemReady(_ item: AVPlayerItem, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if item.status == .readyToPlay { return true }
            if item.status == .failed { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return item.status == .readyToPlay
    }

    private func seek(_ player: AVPlayer, to time: CMTime) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    /// Reads the alpha byte (BGRA layout) at (x, y) from a locked pixel buffer.
    private func alpha(in pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        return base[y * bytesPerRow + x * 4 + 3]
    }

    // MARK: — Live-decode background transparency

    func test_bundledAsset_liveDecode_backgroundCornersAreTransparent_blobStaysOpaque() async throws {
        let url = try bundledAssetURL()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let ready = await waitForItemReady(item, timeout: 15)
        XCTAssertTrue(ready, "bundled loading-screen.mov must load successfully — status=\(item.status.rawValue), error=\(String(describing: item.error))")
        guard ready else { return }

        // Sample across several points in the ~9.7s loop so this isn't
        // sensitive to exactly where the blob animation is at any one instant.
        let sampleTimes = [0.5, 2.0, 4.0, 6.0, 8.0]
        var sampledAnyFrame = false
        var everFullyOpaqueCenter = false

        for seconds in sampleTimes {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            await seek(player, to: time)

            // The output needs a short beat after seeking before a pixel
            // buffer is available for that item time.
            var pixelBuffer: CVPixelBuffer?
            let deadline = Date().addingTimeInterval(5)
            while pixelBuffer == nil && Date() < deadline {
                pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
                if pixelBuffer == nil { try? await Task.sleep(nanoseconds: 30_000_000) }
            }
            guard let pb = pixelBuffer else { continue }
            sampledAnyFrame = true

            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

            let width = CVPixelBufferGetWidth(pb)
            let height = CVPixelBufferGetHeight(pb)
            let margin = 8
            let corners = [
                alpha(in: pb, x: margin, y: margin),
                alpha(in: pb, x: width - 1 - margin, y: margin),
                alpha(in: pb, x: margin, y: height - 1 - margin),
                alpha(in: pb, x: width - 1 - margin, y: height - 1 - margin),
            ]
            let centerAlpha = alpha(in: pb, x: width / 2, y: height / 2)
            if centerAlpha == 255 { everFullyOpaqueCenter = true }

            // Tight tolerance: this is the exact regression this task fixed
            // -- a naive/alpha-lossy transcode reports corner alpha = 255
            // (fully opaque) via this same live-decode path, not just a
            // faint haze. Zero tolerance for "clearly not transparent";
            // small compression noise (a few LSBs) would still pass.
            for (i, a) in corners.enumerated() {
                XCTAssertLessThanOrEqual(
                    a, 4,
                    "t=\(seconds)s corner[\(i)] alpha=\(a) — background corner pixels must be transparent " +
                    "(<=4/255) under live streaming decode (AVPlayerItemVideoOutput, the same VideoToolbox " +
                    "path AVPlayerLayer uses on-device), not just under AVAssetImageGenerator's lenient " +
                    "offline decode. This is the exact opaque-background bug this task fixed."
                )
            }
        }

        XCTAssertTrue(sampledAnyFrame, "must have decoded at least one live frame from the bundled asset")
        XCTAssertTrue(everFullyOpaqueCenter,
                       "the animated blob itself must still render fully opaque (alpha=255) at its own pixels " +
                       "at least once across the sampled times -- proves this test isn't trivially passing by " +
                       "the whole frame being transparent")
    }

    // MARK: — Sizing regression (icon/mark scale, not full-bleed)

    /// LoopingVideoPlayer is `private` to LoadingScreenView.swift and
    /// UIViewRepresentable-backed, so its rendered frame isn't reachable
    /// through a public API or a clean ViewInspector path. Rather than skip
    /// this acceptance criterion entirely, pin it by reading the actual
    /// shipped source (this test file and LoadingScreenView.swift are
    /// checked out side by side on the same machine the simulator build
    /// runs on) and asserting the exact `.frame(width:height:)` call the
    /// fix introduced is still a small, square, in-range value -- not back
    /// to `.frame(maxWidth: .infinity, maxHeight: .infinity)` (the
    /// near-full-screen sizing this task fixed).
    func test_loadingScreenSource_frameSize_isIconScale_notFullBleed() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let viewFile = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/LoadingScreen/LoadingScreenView.swift")

        let source = try String(contentsOf: viewFile, encoding: .utf8)

        XCTAssertFalse(
            source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
            "LoopingVideoPlayer must not regress back to the pre-fix near-full-screen sizing"
        )

        // Lazily match from the LoopingVideoPlayer( call to the next
        // `.frame(width:height:)` call, tolerating the intervening
        // `.aspectRatio(...)` call and multi-line comments (which may
        // themselves contain periods, e.g. mentioning `.infinity`) in
        // between -- this is the only frame() call in that stretch of file.
        let pattern = #"LoopingVideoPlayer\([\s\S]*?\.frame\(width: (\d+(?:\.\d+)?), height: (\d+(?:\.\d+)?)\)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(source.startIndex..., in: source)
        let match = try XCTUnwrap(
            regex.firstMatch(in: source, options: [], range: range),
            "expected to find LoopingVideoPlayer(...).aspectRatio(1, contentMode: .fit).frame(width:height:) in LoadingScreenView.swift"
        )

        func number(_ groupIndex: Int) throws -> CGFloat {
            let r = try XCTUnwrap(Range(match.range(at: groupIndex), in: source))
            let doubleValue = try XCTUnwrap(Double(String(source[r])))
            return CGFloat(doubleValue)
        }

        let width = try number(1)
        let height = try number(2)

        XCTAssertEqual(width, height, "the display frame must stay square, matching the video's own 1:1 aspect ratio")
        XCTAssertGreaterThanOrEqual(width, 100, "must be noticeably smaller than full-bleed -- not shrunk to nothing either")
        XCTAssertLessThanOrEqual(width, 240, "must render at icon/mark scale per the spec's ~150-220pt ballpark, not near-full-screen")
    }
}
