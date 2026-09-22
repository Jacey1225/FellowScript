// ChatHeaderHamburgerRemovalRegressionTests.swift — coverage for task
// 20260921-remove-dead-chat-hamburger (testing gate, final step).
//
// Proves the specific removal this task's frontend gate made against the
// real, shipped Chat/ChatRootView.swift source, so a regression of any one
// of these facts fails here rather than only being caught by a future manual
// screenshot comparison:
//
//   1. The decorative, non-interactive `line.3.horizontal` hamburger circle
//      is gone from `header` entirely -- no lingering reference to that
//      systemImage, and `header` now constructs exactly one Circle (the
//      existing "+" add button), not two.
//   2. The add button itself (action, gradient fill, accessibility label
//      that switches on `selectedSegment`) is completely unaffected by the
//      removal -- explicitly out of scope for this task.
//
// Task 20260921-center-chat-title later replaced this header's leading-title
// layout with a three-region centered one (invisible leading placeholder
// Circle + two Spacers flanking the title + accessibilityHidden on that
// placeholder). That superseded three of this suite's original assertions,
// which pinned facts true only of the leading-aligned layout this task
// shipped (exactly one Circle/the add button; exactly one Spacer; the title
// leading before any Spacer; no accessibilityHidden modifier in `header`) --
// those are updated below to their current-layout equivalents, or retired
// where a later suite (ChatTitleCenteringRegressionTests) now owns the
// specific assertion. This file keeps the assertions that are still true
// regardless of which layout the header uses (no hamburger icon reference,
// title styling, add button wiring).
//
// `header` is a private computed property of ChatRootView, which (per this
// project's established convention -- see
// ChatScheduleUICleanupIOSRegressionTests' HeaderAvatarBloomRemovalRegressionTests)
// can't be hosted in a unit test without a live network round trip: its
// containing view requires a real `ChatViewModel` StateObject plus an
// `AppState` EnvironmentObject, and its own `.task` immediately calls
// `vm.load(service:userId:)`. So, consistent with that same precedent, this
// suite reads the real shipped source directly, scoped to just the `header`
// property so a change elsewhere in the file can't accidentally satisfy an
// assertion.

import XCTest
@testable import FellowScript

final class ChatHeaderHamburgerRemovalRegressionTests: XCTestCase {

    /// The `header` computed property's source, isolated from the rest of
    /// ChatRootView.swift.
    private func headerSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Chat/ChatRootView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        guard let start = source.range(of: "private var header: some View {"),
              let end = source.range(of: "// ── Friends / Groups / Agents pill toggle") else {
            XCTFail("expected to find ChatRootView's `header` property in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    // MARK: - 1. Hamburger circle + icon are gone

    func test_source_header_hasNoLineThreeHorizontalIconReference() throws {
        let header = try headerSource()
        XCTAssertFalse(
            header.contains("line.3.horizontal"),
            "the removed hamburger's systemImage must no longer be referenced anywhere in `header`"
        )
    }

    func test_source_header_constructsExactlyTwoCircles_placeholderAndAddButton() throws {
        // Before task 20260921-remove-dead-chat-hamburger, `header` built two
        // Circles: the decorative hamburger and the "+" add button. That task
        // dropped it back to one (just the add button). Task
        // 20260921-center-chat-title then added a second Circle back -- an
        // invisible leading placeholder used to balance the add button's own
        // width for true visual centering, not a reintroduction of the
        // hamburger. This asserts the count is exactly the current-layout
        // two (placeholder + add button), so a real regression (the
        // hamburger's decorative Circle coming back as a *third* Circle)
        // still fails here rather than being masked by the placeholder's
        // presence. See ChatTitleCenteringRegressionTests for the
        // placeholder's own dedicated coverage.
        let header = try headerSource()
        let circleCount = header.components(separatedBy: "Circle()").count - 1
        XCTAssertEqual(
            circleCount, 2,
            "expected exactly two Circle()s in `header` (the invisible centering placeholder and the \"+\" add button) -- a third would mean the removed hamburger's own Circle has come back"
        )
    }

    // MARK: - 2. Remaining layout: add button untouched by the hamburger removal
    //
    // The leading-alignment-specific assertions previously here (exactly one
    // Spacer; title leading before any Spacer; no accessibilityHidden
    // modifier in `header`) pinned facts only true of this task's own
    // leading-aligned layout. Task 20260921-center-chat-title intentionally
    // replaced that layout with a centered one that has two Spacers and an
    // accessibilityHidden placeholder -- those facts are now covered by
    // ChatTitleCenteringRegressionTests instead, which owns the current
    // layout's shape rather than this hamburger-removal-scoped suite.

    func test_source_header_titleStylingUnchanged() throws {
        let header = try headerSource()
        XCTAssertTrue(header.contains(".font(.system(size: 27, weight: .heavy))"),
                      "the \"Chat\" title's font must be unchanged by the hamburger removal")
        XCTAssertTrue(header.contains(".foregroundColor(Theme.parchment)"),
                      "the \"Chat\" title's color must be unchanged by the hamburger removal")
    }

    // MARK: - 4. Add button completely unaffected

    func test_source_header_addButtonActionAndGradientUnchanged() throws {
        let header = try headerSource()
        XCTAssertTrue(header.contains("Button(action: addAction)"),
                      "the add button's action must be unaffected by the hamburger removal")
        XCTAssertTrue(
            header.contains(##"LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],"##),
            "the add button's gradient fill must be unaffected by the hamburger removal"
        )
        XCTAssertTrue(header.contains(#"Image(systemName: "plus")"#),
                      "the add button's plus icon must be unaffected by the hamburger removal")
    }

    func test_source_header_addButtonAccessibilityLabelUnchanged() throws {
        let header = try headerSource()
        XCTAssertTrue(
            header.contains(#".accessibilityLabel(selectedSegment == 0 ? "Add friend" : selectedSegment == 1 ? "New group" : "New agent")"#),
            "the add button's segment-dependent accessibility label must be unaffected by the hamburger removal"
        )
    }

    // MARK: - Whole-file: no orphaned reference outside `header` either

    func test_source_wholeFile_hasNoRemainingLineThreeHorizontalCodeReference() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Chat/ChatRootView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        // The task's own explanatory comment legitimately still names
        // "line.3.horizontal" once, to document *why* it was removed -- that
        // is expected and is not a dangling code reference. Assert there is
        // no *second* occurrence (i.e. no actual `Image(systemName:
        // "line.3.horizontal")` construction anywhere else in the file).
        let occurrences = source.components(separatedBy: "line.3.horizontal").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "expected exactly one remaining occurrence of \"line.3.horizontal\" in ChatRootView.swift (the explanatory removal comment) -- any additional occurrence would mean the icon itself is still being constructed somewhere"
        )
        XCTAssertFalse(
            source.contains(#"Image(systemName: "line.3.horizontal")"#),
            "no Image(systemName: \"line.3.horizontal\") construction should remain anywhere in ChatRootView.swift"
        )
    }
}
