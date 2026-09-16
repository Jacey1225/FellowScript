// FloatingTabBarCallBarOverlapRegressionTests.swift — coverage for task
// 20260916-call-bar-nav-overlap (Lightweight spec, no dedicated testing gate
// for this task, per this repo's frontend-gate convention of adding a
// minimal test itself in that case).
//
// Pins the actual numeric layout contract between MinimizedCallBar
// (Chat/ChimeCallView.swift) and FloatingTabBar (Dashboard/FloatingTabBar.swift)
// so the two floating bottom overlays can never silently drift back into
// overlapping the way they did before this fix (MinimizedCallBar's real
// 56–106pt footprint vs. FloatingTabBar's old flat 60pt in-call bump, which
// only cleared 60–120pt -- almost total overlap). Asserts on the real
// compiled static constants (both types are internal, same module) rather
// than re-deriving the arithmetic, so a change to either type's own numbers
// is what would break this test -- not a copy of the formula.

import XCTest
import SwiftUI
@testable import FellowScript

final class FloatingTabBarCallBarOverlapRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - MinimizedCallBar's own footprint constants

    func test_minimizedCallBar_footprintConstants_matchItsActualLayout() {
        // 34pt circle (the tallest element in its HStack) + 8pt vertical padding on both edges.
        XCTAssertEqual(MinimizedCallBar.height, 50)
        // Matches ContentView's `.overlay(alignment: .bottom)` placement of MinimizedCallBar.
        XCTAssertEqual(MinimizedCallBar.bottomInset, 56)
    }

    // MARK: - FloatingTabBar's in-call clearance must fully clear MinimizedCallBar, with a real gap

    func test_floatingTabBar_inCallBottomPadding_clearsMinimizedCallBarWithVisibleGap() {
        let callBarTopEdge = MinimizedCallBar.bottomInset + MinimizedCallBar.height
        XCTAssertGreaterThan(
            FloatingTabBar.inCallBottomPadding, callBarTopEdge,
            "FloatingTabBar's in-call bottom padding must clear MinimizedCallBar's own top edge, not just its bottom inset"
        )
        let gap = FloatingTabBar.inCallBottomPadding - callBarTopEdge
        XCTAssertGreaterThanOrEqual(
            gap, Theme.spacingMD,
            "the two bars must have a real, non-crowded visual gap between them, not just non-overlapping hit targets"
        )
    }

    // MARK: - No regression to the no-call (normal) bottom position

    func test_floatingTabBar_noCallBottomPadding_unchangedAt26() throws {
        let source = try readSource("FellowScript/Dashboard/FloatingTabBar.swift")
        XCTAssertTrue(
            source.contains(".padding(.bottom, inCallBarVisible ? Self.inCallBottomPadding : 26)"),
            "the no-call branch of this ternary must remain the original literal 26pt, unaffected by the in-call clearance fix"
        )
    }
}
