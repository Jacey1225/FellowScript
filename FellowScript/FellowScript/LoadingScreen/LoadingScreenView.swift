// DEPENDENCY: Theme.swift, ContentView.swift, StartupCoordinator.swift
// SOURCE: data/loading-screen.mov (ProRes 4444, real per-pixel alpha),
//         re-transcoded to this folder's loading-screen.mov via `avconvert
//         --preset PresetHEVCHighestQualityWithAlpha` (AVFoundation's own
//         export pipeline, not ffmpeg) — HEVC + alpha, 1440x1440, ~9.7s @
//         24fps. Task 20260824-loading-screen-visual-fix found the prior
//         ffmpeg-produced derivative decoded correctly for a single
//         high-quality frame grab (AVAssetImageGenerator) but showed a
//         faint, uniform, real-device-reproducible whitish haze over
//         Theme.bgPage during live AVPlayerLayer playback specifically —
//         alpha-plane compression noise in that transcode's real-time decode
//         path that only ffmpeg's own (non-live) decode was lenient enough
//         to mask. Re-exporting through AVFoundation's own alpha-aware
//         preset (the same framework family that plays it back) removed the
//         haze entirely, confirmed via on-simulator screenshot + pixel
//         sampling against Theme.bgPage before/after.
//
// Purely presentational — has no readiness or timing logic of its own.
// ContentView owns the startup-readiness gate (StartupCoordinator) and the
// crossfade transition into mainTabView; this view just plays (or, under
// Reduce Motion, holds a still frame of) the bundled loading video, muted,
// looping, over Theme.bgPage, with a static branded fallback if the asset
// itself fails to load or decode.

import SwiftUI
import AVFoundation
import UIKit

struct LoadingScreenView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playerFailed = false

    var body: some View {
        Group {
            if playerFailed {
                fallback
            } else {
                ZStack {
                    Theme.bgPage.ignoresSafeArea()
                    LoopingVideoPlayer(reduceMotion: reduceMotion, onFailure: { playerFailed = true })
                        .aspectRatio(1, contentMode: .fit)
                        // Icon/mark scale, not full-bleed (was effectively
                        // filling the whole screen at .frame(maxWidth/maxHeight:
                        // .infinity) before this fix) — centered over
                        // Theme.bgPage with no other layout change.
                        .frame(width: 180, height: 180)
                }
                // The animation itself is the loading indicator — no
                // spinner/progress chrome stacked on top of it. One
                // meaningful label on the container; the decorative
                // video layer stays out of the accessibility tree.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading FellowScript")
            }
        }
    }

    // ── Static branded fallback (video asset failed to load/decode) ──────
    private var fallback: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()
            VStack(spacing: Theme.spacingMD) {
                Image("FellowScriptMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)

                ProgressView()
                    .tint(Theme.gold)
                    .accessibilityHidden(true)

                // The real sighted+VoiceOver-readable status in this state —
                // unlike the decorative layers above, this stays in the
                // accessibility tree.
                Text("Loading…")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }
}

// ── AVPlayer-backed looping video, muted, no controls ─────────────────────
private struct LoopingVideoPlayer: UIViewRepresentable {
    let reduceMotion: Bool
    let onFailure: () -> Void

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(reduceMotion: reduceMotion, onFailure: onFailure)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {}
}

private final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var looper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var statusObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        playerLayer.backgroundColor = UIColor.clear.cgColor
        // Explicit belt-and-suspenders alongside the UIView-level isOpaque
        // above — AVPlayerLayer's own isOpaque isn't guaranteed to inherit
        // from the hosting UIView on every OS version, and this is the
        // most commonly cited real-device gotcha for HEVC-with-alpha
        // content rendering opaque despite a correctly-alpha-tagged asset.
        playerLayer.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(reduceMotion: Bool, onFailure: @escaping () -> Void) {
        // Bundled directly (not in an .xcassets catalog) — same pattern as
        // Bible/bible.json, loaded via Bundle.main.url(forResource:).
        guard let url = Bundle.main.url(forResource: "loading-screen", withExtension: "mov") else {
            onFailure()
            return
        }

        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { onFailure() }
        }

        let player = AVQueuePlayer()
        player.isMuted = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect

        if reduceMotion {
            // Never start playback — seek to a representative held frame
            // (a fraction of a second in, not the blank/black lead-in at 0)
            // and hold it as a static image at rate 0.
            player.replaceCurrentItem(with: item)
            let holdTime = CMTime(seconds: 1.0, preferredTimescale: 600)
            player.seek(to: holdTime, toleranceBefore: .zero, toleranceAfter: .zero)
            player.rate = 0
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.play()
        }
        queuePlayer = player
    }
}
