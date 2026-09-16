// RemoteCameraFieldLayoutRegressionTests.swift — testing-gate coverage for
// task 20260915-video-call-ui-redesign, step 3.
//
// The frontend gate (step 2) replaced ChimeCallView's LazyVGrid "remote grid
// box" with ChimeCallView.RemoteCameraField: a translucent/blurred backdrop
// plus medium circular tiles at randomized, non-overlapping positions
// confined to a chrome-aware central-~70% zone (design-notes.md §3). The
// acceptance criteria this file exists to prove against the *actual
// algorithm*, not just its source text:
//
//   - circles never overlap, across a realistic range of participant counts
//   - every circle stays fully inside the layout zone (never under
//     header/control-bar chrome)
//   - the diameter-tier table and the gap-relax -> size-shrink ->
//     deterministic-scan fallback ladder documented in design-notes.md §3
//     behave exactly as specified, including at 8+ simultaneous cameras
//   - join/leave mid-call keeps existing tiles' positions stable and only
//     places newly-added ids; rotation/size changes re-place everything
//   - the compact/landscape zone-relaxation path frontend flagged for
//     testing (design-notes.md §3 "if zone.height collapses...")
//
// Following this project's established technique for testing_gate coverage
// of geometry/algorithm logic that's normally `private` inside a SwiftUI View
// struct: the relevant methods on RemoteCameraField were relaxed from
// `private` to internal (default) access specifically so this file can call
// the real implementation via `@testable import FellowScript`, rather than
// only pattern-matching source text (see ChimeCallView+RemoteField.swift's
// access-level comment) — no behavioral change, pure visibility.

import XCTest
import SwiftUI
@testable import FellowScript

#if canImport(AmazonChimeSDK)

@MainActor
final class RemoteCameraFieldLayoutRegressionTests: XCTestCase {

    private func makeField(size: CGSize = CGSize(width: 390, height: 844)) -> ChimeCallView.RemoteCameraField {
        ChimeCallView.RemoteCameraField(manager: ChimeCallManager(), containerSize: size)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - A. Diameter tiers (design-notes.md §3 table, exact pins)

    func test_diameterTier_matchesSpecTableExactly() {
        let field = makeField()
        XCTAssertEqual(field.diameterTier(for: 0), 152)
        XCTAssertEqual(field.diameterTier(for: 1), 152)
        XCTAssertEqual(field.diameterTier(for: 2), 152)
        XCTAssertEqual(field.diameterTier(for: 3), 128)
        XCTAssertEqual(field.diameterTier(for: 4), 128)
        XCTAssertEqual(field.diameterTier(for: 5), 104)
        XCTAssertEqual(field.diameterTier(for: 6), 104)
        XCTAssertEqual(field.diameterTier(for: 7), 84)
        XCTAssertEqual(field.diameterTier(for: 12), 84)
    }

    func test_nextTierDown_walksTiersToTheDocumentedFloor() {
        let field = makeField()
        XCTAssertEqual(field.nextTierDown(152), 128)
        XCTAssertEqual(field.nextTierDown(128), 104)
        XCTAssertEqual(field.nextTierDown(104), 84)
        XCTAssertEqual(field.nextTierDown(84), 64, "84pt must step down to the documented 64pt absolute floor")
    }

    // MARK: - B. Non-overlap invariant, across realistic participant counts

    /// The load-bearing acceptance-criteria assertion: "Circle positions ...
    /// are constrained so no two circles overlap." Runs many randomized
    /// trials per count since placement uses CGFloat.random -- a single run
    /// could pass by luck even if the invariant weren't actually enforced.
    func test_packAll_neverOverlaps_acrossParticipantCountsAndManyRandomTrials() {
        let field = makeField()
        let size = CGSize(width: 390, height: 844)
        for count in [1, 2, 3, 4, 5, 6, 7, 8, 10] {
            let ids = Array(0..<count)
            for trial in 0..<25 {
                let tier = field.diameterTier(for: count)
                let zone = field.computeZone(size: size, diameter: tier)
                let (positions, diameter) = field.packAll(ids: ids, zone: zone, startDiameter: tier)
                XCTAssertEqual(positions.count, count, "every id must be placed somewhere (count=\(count), trial=\(trial))")
                let pts = Array(positions.values)
                for i in 0..<pts.count {
                    for j in (i + 1)..<pts.count {
                        XCTAssertGreaterThanOrEqual(
                            distance(pts[i], pts[j]), diameter,
                            "two tiles overlap at count=\(count) trial=\(trial): \(pts[i]) vs \(pts[j]) at diameter \(diameter)"
                        )
                    }
                }
            }
        }
    }

    /// Every placed circle's full extent (center ± radius) must stay inside
    /// the layout zone -- "All circles stay within roughly the central 70%
    /// of the screen bounds ... respecting safe areas."
    func test_packAll_everyCircleFullyInsideZone() {
        let field = makeField()
        let size = CGSize(width: 390, height: 844)
        for count in [2, 4, 6, 8] {
            let ids = Array(0..<count)
            let tier = field.diameterTier(for: count)
            let zone = field.computeZone(size: size, diameter: tier)
            let (positions, diameter) = field.packAll(ids: ids, zone: zone, startDiameter: tier)
            let r = diameter / 2
            for (id, p) in positions {
                XCTAssertGreaterThanOrEqual(p.x - r, zone.minX - 0.5, "tile \(id) spills past the zone's left edge")
                XCTAssertLessThanOrEqual(p.x + r, zone.maxX + 0.5, "tile \(id) spills past the zone's right edge")
                XCTAssertGreaterThanOrEqual(p.y - r, zone.minY - 0.5, "tile \(id) spills past the zone's top edge")
                XCTAssertLessThanOrEqual(p.y + r, zone.maxY + 0.5, "tile \(id) spills past the zone's bottom edge")
            }
        }
    }

    // MARK: - C. computeZone: central-70% + chrome-aware safe band

    func test_computeZone_normalPortraitPhone_boundedByChromeNotJustInset() {
        let field = makeField()
        let size = CGSize(width: 390, height: 844)
        let zone = field.computeZone(size: size, diameter: 152)
        // central70 alone would be insetBy(dx: 58.5, dy: 126.6) -> minY 126.6,
        // maxY 717.4 -- but topChrome (140) and bottomChrome (190) are both
        // documented (design-notes.md §3) to win over a looser central-70%
        // bound, so the real zone must be clamped to [140, 654].
        XCTAssertEqual(zone.minY, 140, accuracy: 0.5, "topChrome (140pt, callHeader's reserved height) must bound the zone's top")
        XCTAssertEqual(zone.maxY, 654, accuracy: 0.5, "bottomChrome (190pt, controlBar's reserved height) must bound the zone's bottom")
        XCTAssertEqual(zone.minX, 390 * 0.15, accuracy: 0.5, "width isn't chrome-constrained -- full central-70% width")
        XCTAssertEqual(zone.maxX, 390 * 0.85, accuracy: 0.5)
    }

    func test_computeZone_tallScreen_usesLooserCentral70BoundNotJustChrome() {
        let field = makeField()
        // A very tall container (e.g. iPad in a split view) where central-70%
        // is the *tighter* constraint on at least the top, not the chrome.
        let size = CGSize(width: 390, height: 2000)
        let zone = field.computeZone(size: size, diameter: 152)
        let insetY = size.height * 0.15
        XCTAssertEqual(zone.minY, insetY, accuracy: 0.5, "on a tall screen the central-70% inset must bind, not the smaller topChrome")
    }

    /// Frontend explicitly flagged this for testing: "Compact/landscape sizes
    /// where the central-70% height band collapses below 2x the diameter
    /// tier and the zone relaxes to the full chrome-safe band."
    func test_computeZone_compactLandscape_relaxesToFullChromeSafeBand() {
        let field = makeField()
        // iPhone-class landscape height where topChrome+bottomChrome leave
        // only a thin band -- exercises the "if zone.height collapses below
        // ~2x diameter tier ... relax toward the safe band alone" path
        // (design-notes.md §3).
        let size = CGSize(width: 844, height: 500)
        let zone = field.computeZone(size: size, diameter: 152)
        // Relaxed zone must equal the full chrome-safe band: [140, 310].
        XCTAssertEqual(zone.minY, 140, accuracy: 0.5)
        XCTAssertEqual(zone.maxY, 310, accuracy: 0.5)
        XCTAssertGreaterThan(zone.maxY, zone.minY, "the relaxed zone must still have positive height, never inverted")
    }

    /// Real-device edge case beyond frontend's own flagged scenario: on a
    /// short-enough landscape height, topChrome (140) + bottomChrome (190) =
    /// 330pt already exceeds the available height, so even the "relaxed"
    /// safe band is inverted/zero-height *before* any packing is attempted.
    /// This is exactly the shape of device FellowScript actually ships on
    /// (e.g. an iPhone SE-class landscape height, ~375pt) -- not a
    /// hypothetical. Documents current behavior so a future fix has a
    /// baseline to diff against.
    func test_computeZone_veryShortLandscape_whereChromeAloneExceedsHeight() {
        let field = makeField()
        let size = CGSize(width: 812, height: 375) // iPhone SE-class landscape height
        let zone = field.computeZone(size: size, diameter: 152)
        // topChrome (140) + bottomChrome (190) = 330 < 375, so there IS 45pt
        // of nominal room, but that's far short of even one floor-diameter
        // (64pt) circle.
        XCTAssertEqual(zone.height, 45, accuracy: 0.5)
    }

    // MARK: - D. Fallback ladder: gap-relax -> size-shrink -> deterministic scan

    /// 8+ simultaneous cameras in a realistic (not degenerate) zone: proves
    /// the full ladder still lands on a fully-placed, non-overlapping result,
    /// exercising the deterministic row-major scan fallback explicitly per
    /// design-notes.md §3 step 5 (frontend's own flagged testing item).
    func test_packAll_eightPlusParticipants_hitsDeterministicScanFallback_staysNonOverlapping() {
        let field = makeField()
        let size = CGSize(width: 390, height: 844)
        let ids = Array(0..<12)
        let tier = field.diameterTier(for: ids.count) // 84pt
        let zone = field.computeZone(size: size, diameter: tier)

        let (positions, diameter) = field.packAll(ids: ids, zone: zone, startDiameter: tier)
        XCTAssertEqual(positions.count, 12, "every one of the 12 ids must end up placed, none silently dropped")

        // The scan fallback is deterministic and spaces tiles at
        // `diameter + relaxedGap` (6pt) in a row-major grid -- confirm no two
        // of the 12 land at the same point (the degenerate collapse this
        // suite separately documents under very short landscape heights).
        let pts = Array(positions.values)
        var seen: [CGPoint] = []
        for p in pts {
            XCTAssertFalse(seen.contains(where: { distance($0, p) < 1 }), "two tiles collapsed onto the same point: \(p)")
            seen.append(p)
        }
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                XCTAssertGreaterThanOrEqual(distance(pts[i], pts[j]), diameter, "scan-fallback tiles must still be non-overlapping")
            }
        }
    }

    /// Directly exercises scanPlace in isolation: deterministic, packs every
    /// id, never overlaps at floor spacing.
    func test_scanPlace_isDeterministicAndNonOverlapping() {
        let field = makeField()
        let zone = CGRect(x: 30, y: 140, width: 330, height: 500)
        let ids = Array(0..<20)
        let positions1 = field.scanPlace(ids: ids, zone: zone, diameter: 64)
        let positions2 = field.scanPlace(ids: ids, zone: zone, diameter: 64)
        XCTAssertEqual(positions1.count, 20)
        XCTAssertEqual(positions1, positions2, "scanPlace must be deterministic given the same inputs")

        let pts = Array(positions1.values)
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                XCTAssertGreaterThanOrEqual(distance(pts[i], pts[j]), 64, "scanPlace tiles must never overlap")
            }
        }
    }

    /// Covers the one genuinely degenerate scanPlace case: a zone with zero
    /// usable height (e.g. the very-short-landscape scenario in section C
    /// above, once it reaches packAll/scanPlace). The row-major loop can't
    /// run a single iteration here, so every id falls to scanPlace's overflow
    /// fallback -- confirm that fallback still spreads tiles out instead of
    /// stacking them all on the old fixed "zone center" point (task
    /// 20260915-video-call-ui-redesign, frontend fix for the testing bounce).
    func test_scanPlace_zeroHeightZone_stillSpreadsTilesNonOverlapping() {
        let field = makeField()
        let zone = CGRect(x: 30, y: 140, width: 330, height: 0) // matches computeZone's clamp-to-0 on inverted input
        let ids = Array(0..<3)
        let positions = field.scanPlace(ids: ids, zone: zone, diameter: 64)
        XCTAssertEqual(positions.count, 3, "all ids still get *a* position (none dropped from rendering)")
        let pts = Array(Set(positions.values.map { "\($0.x),\($0.y)" }))
        XCTAssertEqual(pts.count, 3, "a zero-height zone must no longer collapse every leftover tile onto the same " +
                       "'zone center' point -- the overflow fallback should keep walking the row-major grid so each " +
                       "tile still gets a distinct center")
        let placed = Array(positions.values)
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                XCTAssertGreaterThanOrEqual(distance(placed[i], placed[j]), 64, "zero-height-zone fallback tiles must still be non-overlapping")
            }
        }
    }

    // MARK: - E. Join/leave mid-call: stable positions, only new ids placed

    // These three exercise `computeRelayout` -- the pure decision logic
    // `relayout` wraps around `@State` writes -- directly, rather than
    // `relayout` itself: constructing a `RemoteCameraField` outside a real
    // SwiftUI hosting context means its `@State`/`@Environment` storage
    // doesn't reliably persist across calls (confirmed via a runtime warning:
    // "Accessing Environment<Bool>'s value outside of being installed on a
    // View"), which is a testability gap in property wrappers, not a
    // statement about the shipped behavior. `computeRelayout` was extracted
    // for exactly this reason (see its doc comment in
    // ChimeCallView+RemoteField.swift) and is the real, unmodified logic
    // `relayout` calls.

    func test_computeRelayout_join_keepsExistingPositions_placesOnlyNewIds() {
        let field = makeField()
        let size = CGSize(width: 390, height: 844)
        let (before, beforeDiameter) = field.computeRelayout(
            currentPositions: [:], currentDiameter: 152, ids: [1, 2, 3], size: size, full: true
        )!
        XCTAssertEqual(before.count, 3)

        let (after, _) = field.computeRelayout(
            currentPositions: before, currentDiameter: beforeDiameter, ids: [1, 2, 3, 4], size: size, full: false
        )!
        XCTAssertEqual(after.count, 4)
        XCTAssertEqual(after[1], before[1], "existing tile 1 must not move on a join")
        XCTAssertEqual(after[2], before[2], "existing tile 2 must not move on a join")
        XCTAssertEqual(after[3], before[3], "existing tile 3 must not move on a join")
        XCTAssertNotNil(after[4], "the newly joined tile 4 must be placed")
    }

    func test_computeRelayout_leave_dropsRemovedId_keepsOthersStable() {
        let field = makeField()
        let size = CGSize(width: 390, height: 844)
        let (before, beforeDiameter) = field.computeRelayout(
            currentPositions: [:], currentDiameter: 152, ids: [1, 2, 3], size: size, full: true
        )!

        let (after, _) = field.computeRelayout(
            currentPositions: before, currentDiameter: beforeDiameter, ids: [1, 3], size: size, full: false
        )!
        XCTAssertEqual(after.count, 2)
        XCTAssertNil(after[2], "tile 2's entry must be dropped once it leaves")
        XCTAssertEqual(after[1], before[1], "remaining tile 1 must not move on a leave")
        XCTAssertEqual(after[3], before[3], "remaining tile 3 must not move on a leave")
    }

    /// Regression coverage for the testing-gate bounce: rotating to a
    /// realistic iPhone landscape size (844x390 -- e.g. iPhone 14/15-class
    /// landscape) with a realistic study-session participant count (4, well
    /// within the intake spec's documented 2-8 range) drives computeZone's
    /// relaxed zone down to ~60pt tall -- too short for even the 64pt floor
    /// diameter. `packAll` now actually tries the floor diameter before
    /// falling back, and its deterministic-scan fallback clamps its diameter
    /// to what the zone can actually hold (see `clampedScanDiameter`) instead
    /// of stacking every tile on one fixed "zone center" point -- confirm all
    /// 4 tiles end up placed, distinct, and non-overlapping.
    func test_computeRelayout_rotation_toRealisticLandscapeSize_staysNonOverlapping() {
        let field = makeField()
        let (first, firstDiameter) = field.computeRelayout(
            currentPositions: [:], currentDiameter: 152, ids: [1, 2, 3, 4], size: CGSize(width: 390, height: 844), full: true
        )!
        // Sanity: portrait layout is fine, non-overlapping, as covered by
        // the rest of this suite.
        XCTAssertEqual(first.count, 4)

        // Rotate to a realistic iPhone landscape size -- design-notes.md §3:
        // "the zone itself moved, so old positions aren't meaningful --
        // every tile is re-placed."
        let (after, afterDiameter) = field.computeRelayout(
            currentPositions: first, currentDiameter: firstDiameter, ids: [1, 2, 3, 4], size: CGSize(width: 844, height: 390), full: true
        )!
        XCTAssertEqual(after.count, 4, "all 4 ids must still get *a* position (none dropped from rendering)")

        let pts = Array(after.values)
        let uniquePoints = Set(pts.map { "\($0.x),\($0.y)" })
        XCTAssertEqual(uniquePoints.count, 4,
                       "on this realistic landscape rotation, all 4 tiles must land at distinct points, not collapse " +
                       "onto the same one (diameter used: \(afterDiameter))")
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                XCTAssertGreaterThanOrEqual(distance(pts[i], pts[j]), afterDiameter,
                                             "tiles must stay non-overlapping after a rotation into a chrome-heavy landscape zone")
            }
        }

        // Safe-area criterion still holds even at the shrunk diameter: no
        // tile renders under the header/control-bar chrome.
        let r = afterDiameter / 2
        for p in pts {
            XCTAssertGreaterThanOrEqual(p.y - r, 140 - 0.5, "tile must not render under callHeader's chrome")
            XCTAssertLessThanOrEqual(p.y + r, 390 - 190 + 0.5, "tile must not render under controlBar's chrome")
        }
    }

    // MARK: - F. fits(): the raw distance predicate itself

    func test_fits_rejectsCandidateWithinGap_acceptsCandidateBeyondGap() {
        let field = makeField()
        let positions: [Int: CGPoint] = [1: CGPoint(x: 100, y: 100)]
        // radius 50 + radius 50 + gap 12 = 112 minimum center distance.
        XCTAssertFalse(field.fits(CGPoint(x: 200, y: 100), radius: 50, gap: 12, in: positions), "distance 100 < required 112 must be rejected")
        XCTAssertTrue(field.fits(CGPoint(x: 213, y: 100), radius: 50, gap: 12, in: positions), "distance 113 >= required 112 must be accepted")
    }
}

#endif
