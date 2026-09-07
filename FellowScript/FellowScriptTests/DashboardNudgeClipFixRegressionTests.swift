// DashboardNudgeClipFixRegressionTests.swift — coverage for task
// 20260906-nudge-clip-fix (testing gate).
//
// Proves the real defect this task fixed (nudge control's 3pt corner-overhang
// clipped by avatarStackRow's ScrollView, per the user's on-device screenshot
// and design-notes.md §1) against the actual shipped source, so a regression
// fails here rather than only being caught by a future manual screenshot
// comparison. ViewInspector can't cheaply assert *clip-bounds* facts (SwiftUI
// doesn't expose a resolved clip rect to introspect), so this follows this
// project's established technique (see DashboardBackgroundConsistencyRegression
// Tests.swift / BibleReaderConsistencyRegressionTests.swift) of pinning
// render-tree facts -- an exact modifier's presence, or its absence -- by
// reading the real shipped source directly.

import XCTest
import SwiftUI
@testable import FellowScript

final class DashboardNudgeClipFixRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - 1. The actual fix: avatarStackRow's LazyHStack grows the
    // ScrollView's measured bounds by exactly the nudge control's 3pt
    // corner-overhang, on exactly the top and trailing edges.

    func test_source_avatarStackRow_growsScrollViewMeasuredBounds_byOverhangAmount() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardComponents.swift")

        // Isolate avatarStackRow's own body so this test can't accidentally
        // pass by matching padding somewhere unrelated in the file.
        guard let start = source.range(of: "private var avatarStackRow: some View {"),
              let end = source.range(of: "// Rendered friend set:") else {
            XCTFail("could not locate avatarStackRow in DashboardComponents.swift")
            return
        }
        let rowBody = String(source[start.upperBound..<end.lowerBound])

        XCTAssertTrue(
            rowBody.contains("ScrollView(.horizontal, showsIndicators: false) {"),
            "avatarStackRow must still be a horizontal ScrollView -- this fix must not change scroll axis/indicator behavior"
        )
        XCTAssertTrue(
            rowBody.contains("LazyHStack(spacing: 10) {"),
            "avatarStackRow's inter-tile spacing (10pt gap, load-bearing for the hit-target pull-back math) must be untouched"
        )
        XCTAssertTrue(
            rowBody.contains(".padding(.top, 3)"),
            "avatarStackRow must grow its content's measured top bound by 3pt so the nudge badge's -3pt top overhang lands inside the ScrollView's clip instead of outside it"
        )
        XCTAssertTrue(
            rowBody.contains(".padding(.trailing, 3)"),
            "avatarStackRow must grow its content's measured trailing/scroll-content bound by 3pt so the last tile's badge trailing overhang is reachable within the ScrollView's scrollable content instead of being clipped at the end of the row"
        )
    }

    // MARK: - 2. Guard against reintroducing the rejected fix: architecture.json
    // explicitly rejected a wholesale `.scrollClipDisabled()` because it would
    // let up to ~46 off-screen tiles bleed past the card's own 20pt padding.

    func test_source_avatarStackRow_doesNotUse_scrollClipDisabled() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardComponents.swift")
        XCTAssertFalse(
            source.contains("scrollClipDisabled"),
            "avatarStackRow must not use .scrollClipDisabled() -- architecture.json rejected this because it disables clipping on all edges, letting off-screen tiles bleed past the card's own padding during horizontal scroll. The fix must instead grow the ScrollView's own measured content bounds by exactly the overhang amount."
        )
    }

    // MARK: - 3. This is a clip-bounds fix, not a repositioning -- the nudge
    // control's own geometry (verified safe by 20260906-nudge-icon-resize)
    // must be byte-identical to before this task.

    func test_source_nudgeControl_geometryUnchangedByClipFix() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardComponents.swift")

        guard let start = source.range(of: "private func nudgeControl(for entry: FSFriendActivityEntry) -> some View {"),
              let end = source.range(of: "@ViewBuilder\n    private func nudgeGlyph") else {
            XCTFail("could not locate nudgeControl in DashboardComponents.swift")
            return
        }
        let controlBody = String(source[start.upperBound..<end.lowerBound])

        XCTAssertTrue(
            controlBody.contains(".frame(width: 28, height: 28)"),
            "nudge control's 28pt visual circle must be unchanged -- this task fixes a clip boundary, not the control's own size"
        )
        XCTAssertTrue(
            controlBody.contains(".contentShape(Circle().inset(by: -8).offset(x: -3, y: 0))"),
            "nudge control's 44pt hit target (pulled back 3pt on x to clear the 10pt inter-tile gap) must be unchanged"
        )
        XCTAssertTrue(
            controlBody.contains(".padding(-3)"),
            "nudge control's negative padding producing the corner-overhang must be unchanged -- this task fixes the container that was clipping it, not the overhang itself"
        )
        XCTAssertTrue(
            controlBody.contains(".accessibilityLabel(nudgeAccessibilityLabel(for: entry, state: state))"),
            "nudge control's accessibility label wiring must survive this clip fix untouched"
        )
    }

    // MARK: - 4. friendTile's fixed 68x68 frame (the measured bound the clip
    // problem traces back to) must be unchanged -- confirms this fix grows the
    // *ScrollView's* bounds, not the tile's own frame, per design-notes.md §1-2.

    func test_source_friendTile_fixedFrameUnchanged_andChatButtonAccessibilityIntact() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardComponents.swift")

        guard let start = source.range(of: "private func friendTile(_ entry: FSFriendActivityEntry) -> some View {"),
              let end = source.range(of: "private func tileContent(_ entry: FSFriendActivityEntry)") else {
            XCTFail("could not locate friendTile in DashboardComponents.swift")
            return
        }
        let tileBody = String(source[start.upperBound..<end.lowerBound])

        XCTAssertTrue(
            tileBody.contains(".frame(width: 68, height: 68)"),
            "friendTile's own 68x68 frame must be unchanged -- the clip fix works by growing the ScrollView's bounds around this fixed frame, not by resizing the frame itself"
        )
        XCTAssertTrue(
            tileBody.contains("ZStack(alignment: .topTrailing) {"),
            "chat button / nudge control must remain ZStack siblings (not nested) so VoiceOver still exposes them as independent elements"
        )
        XCTAssertTrue(
            tileBody.contains(".accessibilityActionIfEnabled(nudgeIsInteractive(state), named: Text(\"Nudge\")) {"),
            "chat button's belt-and-braces nudge accessibility action must remain intact after this clip fix"
        )
    }
}
