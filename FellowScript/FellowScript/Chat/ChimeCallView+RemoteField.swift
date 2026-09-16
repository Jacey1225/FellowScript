// Remote camera field for the active-call screen (task 20260915-video-call-ui-redesign).
//
// Replaces the old `remoteGrid` `LazyVGrid`/`ScrollView` "grid box" with each
// active remote camera rendered as a medium circular tile at a randomized,
// non-overlapping position confined to the central ~70% of the screen. The
// translucent/blurred backdrop itself lives on `ChimeCallView.chimeBackground`
// (ChimeCallView.swift) -- this file only owns tile placement and rendering.
//
// Split into its own `ChimeCallView+`-suffixed file rather than growing
// ChimeCallView.swift further, matching this codebase's existing convention
// for extracting substantial view logic (NetworkService+Auth.swift,
// AccountView+Profile.swift, NotesListView+Toolbar.swift, ...).
//
// See design-notes.md (task 20260915-video-call-ui-redesign, §3) for the full
// placement spec this implements: diameter tiers by active-tile count, a
// rejection-sampling placer with a gap-relax -> size-shrink -> deterministic-
// scan fallback ladder, and join/leave-vs-rotation recompute rules.

import SwiftUI

#if canImport(AmazonChimeSDK)

extension ChimeCallView {

    struct RemoteCameraField: View {
        @ObservedObject var manager: ChimeCallManager
        let containerSize: CGSize

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        // Access relaxed from `private` to internal (default) on this state
        // pair plus the pure geometry helpers below -- task
        // 20260915-video-call-ui-redesign, testing step 3 -- so
        // FellowScriptTests can exercise the actual packing algorithm
        // directly via @testable import instead of only pattern-matching
        // source text. No behavioral change: still only ever mutated from
        // within this file's own `relayout`.
        @State var tilePositions: [Int: CGPoint] = [:]
        @State var diameter: CGFloat = 152

        // Chrome the layout zone must never render under (design-notes.md §3
        // "Layout zone" -- callHeader's/controlBar's approximate reserved height).
        private let topChrome: CGFloat = 140
        private let bottomChrome: CGFloat = 190
        private let floorDiameter: CGFloat = 64
        private let normalGap: CGFloat = 12
        private let relaxedGap: CGFloat = 6

        // Absolute last-resort diameter for the deterministic scan fallback
        // (task 20260915-video-call-ui-redesign, frontend step 2, bounce from
        // testing). design-notes.md §3 specs 64pt as a floor that should
        // "never shrink further" for the *random-placement* ladder, and that
        // remains true -- `packAll`'s rejection-sampling loop still always
        // tries 64pt before giving up. This constant only governs the
        // deterministic `scanPlace` fallback that runs once random placement
        // has failed even at 64pt, for the specific case where the zone
        // itself (central-70% band further constrained to stay clear of
        // `topChrome`/`bottomChrome`) is shorter than 64pt to begin with --
        // e.g. a realistic 844x390 landscape rotation, where
        // topChrome+bottomChrome (330pt) leaves only ~60pt of usable height
        // regardless of circle size. `topChrome`/`bottomChrome` can't be
        // relaxed further without rendering under the header/control bar
        // (a harder acceptance-criteria violation than a smaller circle), so
        // the tiles shrink to whatever the zone can actually hold instead of
        // silently collapsing onto a single point. Half the normal floor --
        // still unambiguously a circle, never a dot.
        private let absoluteMinDiameter: CGFloat = 32
        private let enterExitCurve = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)

        var body: some View {
            ZStack {
                ForEach(manager.remoteTileIds, id: \.self) { id in
                    if let center = tilePositions[id] {
                        tile(id: id)
                            .position(center)
                            .motionAwareAnimation(enterExitCurve, value: center, reduceMotion: reduceMotion)
                            .transition(tileTransition)
                    }
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .onAppear { relayout(for: manager.remoteTileIds, size: containerSize, full: true) }
            .onChange(of: manager.remoteTileIds) { _, newIds in
                relayout(for: newIds, size: containerSize, full: false)
            }
            .onChange(of: containerSize) { _, newSize in
                relayout(for: manager.remoteTileIds, size: newSize, full: true)
            }
        }

        // MARK: - Tile rendering (design-notes.md §5, no new colors/shapes)

        @ViewBuilder
        private func tile(id: Int) -> some View {
            ChimeVideoTileView(tileId: id, manager: manager)
                .frame(width: diameter, height: diameter)
                .background(Color.white.opacity(0.04))
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.gold.opacity(0.38), lineWidth: 1))
                .topEdgeHighlight(Circle())
                .shadow(color: .black.opacity(0.55), radius: 12)
        }

        // Enter/exit motion (design-notes.md §4): eased, asymmetric (exit faster
        // than enter), reduced-motion-first-class -- an opacity-only cross-fade,
        // no scale/position ramp, rather than a bolted-on afterthought. No idle/
        // ambient motion anywhere here: tiles are static once placed and only
        // move on an actual join/leave/rotation state change (`relayout`, below).
        private var tileTransition: AnyTransition {
            if reduceMotion {
                return .opacity.animation(.easeInOut(duration: 0.2))
            }
            let enter = AnyTransition.opacity.combined(with: .scale(scale: 0.85))
                .animation(enterExitCurve)
            let exit = AnyTransition.opacity.combined(with: .scale(scale: 0.9))
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.25))
            return .asymmetric(insertion: enter, removal: exit)
        }

        // MARK: - Layout recompute (design-notes.md §3 "State/lifecycle")

        func relayout(for ids: [Int], size: CGSize, full: Bool) {
            guard let (newPositions, newDiameter) = computeRelayout(
                currentPositions: tilePositions, currentDiameter: diameter, ids: ids, size: size, full: full
            ) else { return }

            withMotionAwareAnimation(enterExitCurve, reduceMotion: reduceMotion) {
                diameter = newDiameter
                tilePositions = newPositions
            }
        }

        /// Pure decision logic behind `relayout`, extracted so it can be
        /// exercised directly by FellowScriptTests (task
        /// 20260915-video-call-ui-redesign, testing step 3) without touching
        /// `@State`/`@Environment`, which don't behave reliably when a View
        /// struct is instantiated outside a real SwiftUI hosting context.
        /// `relayout` itself is the only caller -- no behavioral change, pure
        /// extraction of what was previously inline.
        func computeRelayout(
            currentPositions: [Int: CGPoint], currentDiameter: CGFloat,
            ids: [Int], size: CGSize, full: Bool
        ) -> (positions: [Int: CGPoint], diameter: CGFloat)? {
            guard size.width > 0, size.height > 0 else { return nil }
            let tier = diameterTier(for: ids.count)
            let zone = computeZone(size: size, diameter: tier)

            if full {
                // First layout, or a rotation/size change: the zone itself moved,
                // so old positions aren't meaningful -- every tile is re-placed.
                return packAll(ids: ids, zone: zone, startDiameter: tier)
            }
            // Join/leave mid-call: keep positions for ids still present, place
            // only newly-added ids against that existing set.
            var kept = currentPositions.filter { ids.contains($0.key) }
            let addedIds = ids.filter { currentPositions[$0] == nil }
            if addedIds.isEmpty {
                return (kept, currentDiameter)
            }
            if place(newIds: addedIds, into: &kept, zone: zone, diameter: currentDiameter) {
                return (kept, currentDiameter)
            }
            // The current diameter tier can't fit the new tile(s) even after
            // gap relaxation -- fall back to a full repack of every currently
            // active tile (design-notes.md §3, step 4).
            return packAll(ids: ids, zone: zone, startDiameter: tier)
        }

        func diameterTier(for count: Int) -> CGFloat {
            switch count {
            case 0...2: return 152
            case 3...4: return 128
            case 5...6: return 104
            default:    return 84
            }
        }

        func nextTierDown(_ current: CGFloat) -> CGFloat {
            switch current {
            case 152: return 128
            case 128: return 104
            case 104: return 84
            default:  return floorDiameter
            }
        }

        func computeZone(size: CGSize, diameter: CGFloat) -> CGRect {
            let insetX = size.width * 0.15
            let insetY = size.height * 0.15
            let safeMinY = topChrome
            let safeMaxY = size.height - bottomChrome
            var minY = max(insetY, safeMinY)
            var maxY = min(size.height - insetY, safeMaxY)
            if maxY - minY < diameter * 2 {
                // Compact/landscape phones: the literal central-70% height band
                // and the chrome-safe band don't leave room for even two tiles --
                // relax to the full safe band rather than forcing an infeasibly
                // thin zone. Still never renders under header/control bar.
                minY = safeMinY
                maxY = safeMaxY
            }
            return CGRect(x: insetX, y: minY, width: max(size.width - insetX * 2, 0), height: max(maxY - minY, 0))
        }

        // MARK: - Packing (design-notes.md §3 "Placement")

        func packAll(ids: [Int], zone: CGRect, startDiameter: CGFloat) -> (positions: [Int: CGPoint], diameter: CGFloat) {
            var d = startDiameter
            // Walk every tier down to (and including) the 64pt floor -- a
            // `while` rather than a fixed 3-pass `for` loop, since the tier
            // ladder (152/128/104/84 -> floor 64) can be up to 4 shrink steps
            // from the largest tier, and a 3-pass cap was silently skipping
            // the floor diameter itself in exactly that case (task
            // 20260915-video-call-ui-redesign, testing bounce). Always
            // terminates: `nextTierDown` strictly decreases and the loop
            // breaks the pass after it actually tries `floorDiameter`.
            while true {
                var placed: [Int: CGPoint] = [:]
                if place(newIds: ids, into: &placed, zone: zone, diameter: d) {
                    return (placed, d)
                }
                if d <= floorDiameter { break }
                d = nextTierDown(d)
            }
            // Still infeasible at the floor diameter with a relaxed gap. Two
            // distinct causes land here:
            //  - realistically only at 8+ simultaneous cameras in a
            //    width-constrained-but-tall-enough zone: `clampedScanDiameter`
            //    is a no-op (returns `floorDiameter` unchanged) and this is
            //    exactly the deterministic row-major scan design-notes.md §3
            //    step 5 describes.
            //  - a zone whose *height* is under 64pt to begin with (e.g. a
            //    compact/landscape rotation where chrome eats most of the
            //    screen) -- no diameter this loop tried could ever have fit,
            //    so shrink to what the zone can actually hold rather than
            //    letting every tile fall through to the same point.
            // Either way this subset is no longer "random" but stays
            // non-overlapping and on-screen -- a documented fallback, not an
            // unbounded retry loop.
            let scanDiameter = clampedScanDiameter(for: zone)
            return (scanPlace(ids: ids, zone: zone, diameter: scanDiameter), scanDiameter)
        }

        /// Diameter the deterministic `scanPlace` fallback should actually
        /// use: `floorDiameter` when the zone is tall enough to hold it,
        /// otherwise shrunk to the zone's real height (never below
        /// `absoluteMinDiameter`). See `absoluteMinDiameter`'s doc comment
        /// for why this only ever applies to the scan fallback, not the
        /// random-placement ladder above.
        func clampedScanDiameter(for zone: CGRect) -> CGFloat {
            max(min(floorDiameter, zone.height), absoluteMinDiameter)
        }

        /// Attempts to place every id in `newIds` into `positions` (which may
        /// already hold other tiles to avoid), using `positions`'s existing
        /// entries as obstacles. Returns `false` (leaving `positions` partially
        /// mutated) the moment any id can't be placed even at the relaxed gap.
        @discardableResult
        func place(newIds: [Int], into positions: inout [Int: CGPoint], zone: CGRect, diameter: CGFloat) -> Bool {
            let r = diameter / 2
            let sampleRect = zone.insetBy(dx: r, dy: r)
            guard sampleRect.width > 0, sampleRect.height > 0 else { return false }

            for id in newIds {
                var placedThis = false
                for gap in [normalGap, relaxedGap] {
                    let tries = gap == normalGap ? 80 : 40
                    for _ in 0..<tries {
                        let candidate = CGPoint(
                            x: CGFloat.random(in: sampleRect.minX...sampleRect.maxX),
                            y: CGFloat.random(in: sampleRect.minY...sampleRect.maxY)
                        )
                        if fits(candidate, radius: r, gap: gap, in: positions) {
                            positions[id] = candidate
                            placedThis = true
                            break
                        }
                    }
                    if placedThis { break }
                }
                if !placedThis { return false }
            }
            return true
        }

        func fits(_ point: CGPoint, radius: CGFloat, gap: CGFloat, in positions: [Int: CGPoint]) -> Bool {
            for (_, other) in positions {
                let dx = point.x - other.x
                let dy = point.y - other.y
                if (dx * dx + dy * dy).squareRoot() < radius + radius + gap { return false }
            }
            return true
        }

        /// Deterministic row-major fallback (design-notes.md §3, step 5) -- used
        /// only once random rejection-sampling has failed at the floor diameter.
        func scanPlace(ids: [Int], zone: CGRect, diameter: CGFloat) -> [Int: CGPoint] {
            let r = diameter / 2
            let spacing = diameter + relaxedGap
            var positions: [Int: CGPoint] = [:]
            var remaining = ids

            var y = zone.minY + r
            while y + r <= zone.maxY, !remaining.isEmpty {
                var x = zone.minX + r
                while x + r <= zone.maxX, !remaining.isEmpty {
                    positions[remaining.removeFirst()] = CGPoint(x: x, y: y)
                    x += spacing
                }
                y += spacing
            }
            // Any id the zone-bounded scan above still couldn't fit (e.g. a
            // zone shorter than even one row at this diameter, or more tiles
            // than the zone holds) still needs a distinct, non-overlapping
            // center rather than collapsing onto a single point (task
            // 20260915-video-call-ui-redesign, testing bounce -- the previous
            // "drop every leftover id at zone.mid" guard stacked all of them
            // on top of each other). Keep walking the same row-major grid
            // past the zone's own bounds as a last resort: every step is
            // still exactly `spacing` apart on at least one axis, so `fits`'s
            // non-overlap invariant holds even though tiles may render past
            // the intended zone in this genuinely pathological case (only
            // reachable when `clampedScanDiameter` already couldn't make the
            // zone-bounded scan above fit everyone; `computeZone`/`packAll`
            // keep the ordinary path well clear of this).
            if !remaining.isEmpty {
                let column = max(zone.width, spacing)
                var x = zone.minX + r
                var overflowY = max(y, zone.minY + r)
                for id in remaining {
                    positions[id] = CGPoint(x: x, y: overflowY)
                    x += spacing
                    if x + r > zone.minX + column {
                        x = zone.minX + r
                        overflowY += spacing
                    }
                }
            }
            return positions
        }
    }
}

#endif
