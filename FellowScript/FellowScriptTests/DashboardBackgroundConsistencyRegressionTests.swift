// DashboardBackgroundConsistencyRegressionTests.swift — coverage for task
// 20260901-dashboard-background-consistency (frontend gate; Lightweight spec,
// no separate testing gate in this workflow, so this file is the minimal
// regression coverage the frontend gate itself is responsible for).
//
// Proves the real defect this task fixed, against the actual shipped source,
// so a regression fails here rather than only being caught by a future manual
// screenshot comparison:
//
//   1. DashboardView's background no longer uses the bespoke, top-anchored
//      five-stop LinearGradient "hero" backdrop — it now uses the same
//      two-RadialGradient "bloom" treatment (identical hex/opacity/anchor/
//      radius) every other screen (Account/Notes/Chat/Bible) already uses.
//   2. HeroHeader's greeting text, which used to rely on that removed
//      gradient's strong warm fill for contrast, was updated from a dark ink
//      to Theme.parchment — the same token every other headline sitting
//      directly on this exact bgPage+bloom background already uses — so
//      legibility holds against the new, subtler background.
//
// Following this project's established technique (see
// BibleReaderConsistencyRegressionTests.swift) for pinning render-tree facts
// that ViewInspector can't cheaply assert on (an *absent* modifier, an exact
// Color token identity) by reading the real shipped source directly rather
// than re-deriving them from a hosted view.

import XCTest
import SwiftUI
@testable import FellowScript

final class DashboardBackgroundConsistencyRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - 1. Background now uses the shared bgPage + radial-bloom treatment

    func test_source_dashboardView_background_usesSharedRadialBloomTreatment_notBespokeLinearHero() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardView.swift")
        XCTAssertTrue(
            source.contains("Theme.bgPage.ignoresSafeArea()"),
            "DashboardView's full-page background must use the same Theme.bgPage token every other screen uses"
        )
        XCTAssertFalse(
            source.contains("LinearGradient"),
            "DashboardView must no longer render the bespoke top-anchored linear 'hero' gradient at all"
        )
        XCTAssertTrue(
            source.contains(##"RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],"##) &&
            source.contains("center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)"),
            "expected the first ambient RadialGradient bloom (top-left, #D4922A @ 0.20) with the exact anchor/radius every other screen uses"
        )
        XCTAssertTrue(
            source.contains(##"RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],"##) &&
            source.contains("center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)"),
            "expected the second ambient RadialGradient bloom (bottom-right, #B8761D @ 0.12) with the exact anchor/radius every other screen uses"
        )
    }

    func test_source_dashboardView_oldLinearHeroStops_areFullyRemoved() throws {
        // Narrow-scope guard: confirms none of the retired gradient's five
        // specific stop colors linger anywhere in the file.
        let source = try readSource("FellowScript/Dashboard/DashboardView.swift")
        for retiredHex in ["#C98420", "#A0641A", "#6B4315", "#3A2612"] {
            XCTAssertFalse(
                source.contains(retiredHex),
                "the retired linear hero gradient's stop color \(retiredHex) must no longer appear in DashboardView"
            )
        }
    }

    // MARK: - 2. HeroHeader's greeting text now uses Theme.parchment, not the
    // old dark ink that relied on the removed gradient's warmth for contrast.

    func test_source_heroHeader_greetingText_usesParchment_notOldDarkInk() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardComponents.swift")
        XCTAssertTrue(
            source.contains(##"Text("\(greeting), \(username)")"##),
            "sanity check: the greeting Text call site must still exist"
        )
        // The greeting Text's foregroundColor must be Theme.parchment.
        XCTAssertTrue(
            source.contains("Text(\"\\(greeting), \\(username)\")\n                    .font(.system(size: 27, weight: .heavy))\n                    .foregroundColor(Theme.parchment)"),
            "HeroHeader's greeting text must use Theme.parchment (matching every other headline on this bgPage+bloom background), not the old dark ink that relied on the now-removed gradient for contrast"
        )
    }

    func test_source_heroHeader_avatarCircle_stillHasItsOwnFixedDarkFill_untouched() throws {
        // Out-of-bounds guard: the avatar's own solid dark circle fill is
        // independent of the page background (it's always dark, always
        // paired with gold text) and must not have been collaterally changed.
        let source = try readSource("FellowScript/Dashboard/DashboardComponents.swift")
        XCTAssertTrue(
            source.contains(##"Circle()"##) &&
            source.contains(##".fill(Color(hex: "#2A1B0B"))"##) &&
            source.contains(##".foregroundColor(Color(hex: "#F0AE40"))"##),
            "HeroHeader's avatar circle (fixed dark fill + gold initial) must be unaffected by the page-background/greeting-text fix"
        )
    }
}
