// DEPENDENCY: Theme.swift, ContentView.swift, StartupCoordinator.swift
// SOURCE: .claude/design/20260910-loading-screen-star/design-spec.md (rev 2,
//         post-critique) + critique.md (pass 2, verdict: pass) — task
//         20260910-loading-screen-star.
//
// Replaces the prior video-backed (`LoopingVideoPlayer`/`AVPlayerLayer` +
// bundled `loading-screen.mov`) implementation with a zero-dependency,
// procedural native draw: a single 96×96 pt gold star mark (no inner
// diamond -- removed at the user's explicit request; a single shape only),
// stroked with `Theme.goldGradient`, animated by one continuous underdamped
// spring turn per 1.5 s beat.
//
// This task's FIRST implementation action (done before any of the code
// below was written, not represented in this diff) was reverting a separate,
// unfinished, uncommitted "liquid-gel blob" redesign attempt (task
// 20260909-loading-screen-fullscreen) that had been left dirty in this same
// file plus Theme.swift (a `loaderGrey` token, now gone again) and the test
// tree — the user confirmed that direction is abandoned in favor of this
// star design, so the revert restored this file (and Theme.swift, and
// LoadingScreenAssetTransparencyTests.swift) to their last-committed state
// before this rewrite began, and deleted the blob-specific
// LoadingScreenNativeChoreographyTests.swift outright. None of the blob
// task's geometry, tokens, or tests carry forward.
//
// Motion: `LoadingScreenMotion` below holds every timing/geometry constant
// and all pure geometry math, kept outside any `Canvas`/`GraphicsContext`
// draw closure specifically so it's directly unit-testable via `@testable
// import FellowScript` — this project's own established pattern for this
// screen (Q18, testability-by-default) and the same reason the prior blob
// draft separated its choreography math from its draw closure.
//
// Rotation is an UNBOUNDED ratchet (`beatCount`, incremented by +1 — i.e.
// +180° — every beat, never reset to 0), not a resetting keyframe loop —
// critique.md issue #1. A resetting loop would pop `goldGradient`'s rotated
// sweep at the loop boundary if the pre-approved 90°-per-beat fallback is
// ever substituted for the default 180°; the unbounded ratchet is correct
// under either variant and costs nothing extra under the default.
//
// Palette is `Theme.swift` shipped tokens only (`bgPage` via
// `warmBloomBackground()`, `goldGradient`, `gold`) — no `loaderGrey`, no
// reference-image colors, per design-spec.md's "Consistency notes."
//
// No asset-load-failure fallback: a procedural draw has nothing that can
// fail to load, so the old `FellowScriptMark` + `ProgressView` + "Loading…"
// fallback stack this screen inherited from the video-backed version is
// deleted outright, not carried forward.
//
// `loading-screen.mov` is intentionally left in the bundle, untouched, by
// this change — its removal awaits the user's own nod (open question, not
// resolved by this task). This view no longer references it at all (it
// didn't before this task either), so it is simply unreferenced, not
// dangling-but-still-called.
//
// Whether this star mark should visually align with / become the app's
// `FellowScriptMark` icon asset is an explicitly out-of-scope brand-system
// question (Q15.2 leans toward strict brand consistency in general, but
// this specific call was deliberately left open by the design pipeline) —
// nothing here silently decides it either way.
//
// Purely presentational — has no readiness or timing logic of its own.
// ContentView owns the startup-readiness gate (StartupCoordinator) and the
// crossfade transition into mainTabView (`.motionAwareAnimation(.easeOut(
// duration: 0.35), value: startup.isReady, …)` + `.transition(.opacity)`);
// this view only ever needs to loop indefinitely and disappear cleanly when
// swapped out. Exit is not authored here.

import SwiftUI

/// Pure timing and geometry constants/math for `LoadingScreenView`'s mark,
/// deliberately kept out of any `Canvas`/`GraphicsContext` draw closure so
/// every value here is directly assertable from `@testable import
/// FellowScript` (this screen's established pattern; Q18 testability).
enum LoadingScreenMotion {
    // MARK: — Timing (design-spec.md "Motion language" / shot list)

    /// One beat: a single continuous underdamped spring turn (0–1,050 ms)
    /// followed by a mandatory 450 ms hard rest — 1,500 ms total.
    static let beatDuration: Double = 1.5

    /// Two beats make one visually-seamless loop (four-fold star symmetry
    /// means every beat lands on an identical silhouette). This is a
    /// documentation constant only — the rotation ratchet below never
    /// actually resets at this boundary; see the type's own doc comment.
    static let loopDuration: Double = beatDuration * 2 // 3.0 s

    /// First-appearance-only hold before the very first spring fires.
    /// Applies once per app launch, never once per loop — every later
    /// beat's spring starts immediately at the prior beat's rest boundary.
    static let entryHoldDuration: Double = 0.4

    /// How long the spring itself takes to settle within ~±3° of its
    /// 180° target, per design-spec.md's Motion language table (recomputed
    /// independently in critique.md pass 2: settled by ≈1,050 ms).
    static let springSettleDuration: Double = 1.05

    /// The mandatory hard-still portion of every beat (the final 30%):
    /// `beatDuration - springSettleDuration` = 450 ms. Not optional polish —
    /// design-spec.md calls this out as load-bearing for the loop reading as
    /// "one confident snap" rather than perpetual motion.
    static let restDuration: Double = beatDuration - springSettleDuration // 0.45 s

    /// Degrees added to the unbounded rotation ratchet per beat. 180° is the
    /// shipped default (confirmed at critique on the math; unverified on a
    /// device build — critique.md issue #2). 90° is the pre-approved
    /// fallback if 180° reads as frantic on an actual device; if it's ever
    /// substituted here, the ratchet in `LoadingScreenView` already handles
    /// it correctly (unbounded, not resetting) with no other code change.
    static let beatAngleDegrees: Double = 180

    /// `withAnimation(.spring(response: springResponse, dampingFraction:
    /// springDampingFraction))` is the exact, load-bearing curve —
    /// design-spec.md explicitly forbids re-splitting this into a separate
    /// ease-in/burst stage, and the user's own standing motion preference
    /// (Q9/Q13) forbids ever substituting a linear or constant-rate
    /// rotation for it.
    static let springResponse: Double = 0.5
    static let springDampingFraction: Double = 0.35

    // MARK: — Geometry (style brief shape spec)

    /// Fixed on-screen bounding box for the mark, independent of device
    /// size. Deliberately smaller than design-spec.md's original 180×180 pt
    /// call — shrunk at the user's explicit request during the
    /// bounce-fix pass (roughly half the original footprint).
    static let markSize: CGFloat = 96

    /// Stroke width for the star's single contour: kept at the same ≈9%-
    /// of-`markSize` ratio the original 16 pt / 180 pt sizing used (96 ×
    /// 0.09 ≈ 8.6, rounded to a clean 9 pt), so the stroke keeps the same
    /// relative weight at the new, smaller mark size.
    static let strokeWidth: CGFloat = 9

    /// The star's waist (concave inner) radius as a fraction of its own tip
    /// radius — tuned so the four-point silhouette reads as genuinely
    /// concave (a "sparkle," not a plain diamond outline).
    static let starWaistRadiusFraction: CGFloat = 0.5

    /// Half of the mark's own bounding box, inset by half the stroke width
    /// so the star's outer tip stroke — not just its path — sits flush
    /// inside the `markSize`×`markSize` frame rather than clipping past it.
    static func markRadius(in rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) / 2 - strokeWidth / 2
    }

    /// Outer star's tip (point) radius.
    static func starTipRadius(in rect: CGRect) -> CGFloat {
        markRadius(in: rect)
    }

    /// Outer star's waist (concave) radius.
    static func starWaistRadius(in rect: CGRect) -> CGFloat {
        markRadius(in: rect) * starWaistRadiusFraction
    }

    /// `count` points evenly spaced around `center`, alternating between
    /// `tipRadius` and `waistRadius` every other point (used for the
    /// concave 4-point star: 8 points, tip/waist/tip/waist…). The first
    /// point sits straight up (`-π/2`) so the mark's rest pose points to
    /// twelve o'clock.
    static func alternatingRadiusPoints(center: CGPoint, tipRadius: CGFloat, waistRadius: CGFloat, count: Int) -> [CGPoint] {
        (0..<count).map { i in
            let angle = -CGFloat.pi / 2 + CGFloat(i) * (2 * .pi / CGFloat(count))
            let radius = i.isMultiple(of: 2) ? tipRadius : waistRadius
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    static func closedPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// The outer concave four-point star, sized to `rect`.
    static func starPath(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let points = alternatingRadiusPoints(
            center: center,
            tipRadius: starTipRadius(in: rect),
            waistRadius: starWaistRadius(in: rect),
            count: 8
        )
        return closedPath(points: points)
    }
}

// MARK: — Shape wrapper (so the plain `Path` math above can be `.stroke`d)

private struct StarMarkShape: Shape {
    func path(in rect: CGRect) -> Path { LoadingScreenMotion.starPath(in: rect) }
}

struct LoadingScreenView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beatCount: Int = 0
    @State private var loopTask: Task<Void, Never>?

    var body: some View {
        // Applying `warmBloomBackground()` BEFORE the accessibility
        // modifiers on this same outermost container is required, not
        // incidental: the now-abandoned blob task bounced once on
        // `.ignoresSafeArea()` (nested inside `warmBloomBackground()`'s own
        // `.background(...)`) landing in the wrong order relative to
        // `.accessibilityElement`/`.accessibilityLabel`, which broke
        // ViewInspector's ability to find the label. design-spec.md's
        // "Implementation note — modifier order" calls this out explicitly
        // so it isn't rebuilt here.
        markContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .warmBloomBackground()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading FellowScript")
    }

    @ViewBuilder
    private var markContent: some View {
        if reduceMotion {
            reducedMotionLayer
        } else {
            standardLayer
        }
    }

    // MARK: — Standard motion path

    private var standardLayer: some View {
        markShape
            .rotationEffect(.degrees(Double(beatCount) * LoadingScreenMotion.beatAngleDegrees))
            .onAppear { startLoop() }
            .onDisappear { stopLoop() }
    }

    /// Schedules the entry hold, then the repeating beat ratchet, via plain
    /// Swift-concurrency sleeps rather than a `Timer` — cancelled outright
    /// in `onDisappear` so nothing keeps animating (or keeps a strong
    /// reference alive) after this view leaves the hierarchy.
    ///
    /// The beat's animation is applied via the project's own
    /// `withMotionAwareAnimation(_:reduceMotion:_:)` helper (`Theme.swift`)
    /// rather than a raw `withAnimation(...)` call — this screen's own
    /// standing house convention (see `ContentView`/`ChatRootView`/
    /// `FloatingTabBar` etc.) for gating any animated state change on
    /// Reduce Motion through one shared mechanism instead of a parallel,
    /// hand-rolled check. `startLoop()` itself only ever runs from
    /// `standardLayer`'s `onAppear` (Reduce Motion routes to
    /// `reducedMotionLayer` instead and never calls this), so `reduceMotion`
    /// is always `false` here in practice — but routing through the helper
    /// keeps this call site consistent with every other animated call site
    /// in the app, per design-spec.md's and intake-spec.md's explicit
    /// requirement to reuse the existing helpers rather than invent a
    /// parallel one.
    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(LoadingScreenMotion.entryHoldDuration * 1_000_000_000))
            while !Task.isCancelled {
                await MainActor.run {
                    withMotionAwareAnimation(.spring(response: LoadingScreenMotion.springResponse, dampingFraction: LoadingScreenMotion.springDampingFraction), reduceMotion: reduceMotion) {
                        beatCount += 1
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(LoadingScreenMotion.beatDuration * 1_000_000_000))
            }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: — Reduced Motion path (first-class, not a degraded fallback)

    /// Static rest-pose mark (no rotation, no spring) plus a real, non-
    /// spatial system `ProgressView` for loading feedback — a fully static
    /// screen for the duration of a startup gate that can run for seconds
    /// reads as a hang to a sighted reduce-motion user, per design-spec.md's
    /// "Reduced motion, corrected" note and this user's own standing Q14.2/
    /// Q14.3 preference. The spinner is `accessibilityHidden` so the
    /// container's single `"Loading FellowScript"` label (applied in `body`)
    /// remains the only VoiceOver element.
    ///
    /// The spinner is added via `.overlay(alignment: .center)` plus a
    /// downward offset — not a `VStack` — specifically so the mark's own
    /// on-screen center position is identical to the standard (motion)
    /// variant; a `VStack` here would shift the mark upward by half the
    /// spinner's height. critique.md issue #4.
    private var reducedMotionLayer: some View {
        markShape
            .overlay(alignment: .center) {
                ProgressView()
                    .tint(Theme.gold)
                    .accessibilityHidden(true)
                    .offset(y: LoadingScreenMotion.markSize / 2 + Theme.spacingMD)
            }
    }

    // MARK: — Shared mark

    /// The star mark, at rest orientation — a single shape only; the inner
    /// diamond originally paired with it was removed at the user's explicit
    /// request during the bounce-fix pass. Rotation is applied only by the
    /// standard path's `.rotationEffect` above — this view is reused,
    /// unrotated, by the reduced-motion path too, since `Theme.goldGradient`
    /// is a `LinearGradient` defined in view space: applying rotation here
    /// (rather than baking it into the path math) is what makes the
    /// gradient sweep a free side effect of the turn, per design-spec.md's
    /// "Gradient shimmer" note. Kept wrapped in a single-child `ZStack`
    /// (rather than flattened) so the view tree shape — and this screen's
    /// existing ViewInspector coverage that walks it — stays stable.
    private var markShape: some View {
        ZStack {
            StarMarkShape()
                .stroke(Theme.goldGradient, style: StrokeStyle(lineWidth: LoadingScreenMotion.strokeWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: LoadingScreenMotion.markSize, height: LoadingScreenMotion.markSize)
    }
}
