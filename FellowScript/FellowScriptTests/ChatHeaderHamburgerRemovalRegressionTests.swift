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
//   2. No dangling remnant of the removed element's own accessibility
//      modifier (`.accessibilityHidden(true)`) remains anywhere in `header`
//      -- that modifier existed only to mark the hamburger non-interactive,
//      so it must not survive the element it was attached to.
//   3. The remaining layout reads as intentional: the "Chat" title is
//      leading-aligned directly (no longer preceded by the removed circle's
//      implicit leading balance), followed by a single trailing Spacer and
//      the untouched "+" add button -- mirroring HeroHeader's leading-title
//      convention in DashboardComponents.swift, per the intake spec.
//   4. The add button itself (action, gradient fill, accessibility label
//      that switches on `selectedSegment`) is completely unaffected by the
//      removal -- explicitly out of scope for this task.
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

    func test_source_header_constructsExactlyOneCircle_theAddButton() throws {
        // Before this task, `header` built two Circles: the decorative
        // hamburger and the "+" add button. Only the add button's should
        // remain.
        let header = try headerSource()
        let circleCount = header.components(separatedBy: "Circle()").count - 1
        XCTAssertEqual(
            circleCount, 1,
            "expected exactly one Circle() left in `header` (the \"+\" add button) now that the hamburger's own Circle has been removed"
        )
    }

    // MARK: - 2. No dangling accessibility remnant of the removed element

    func test_source_header_hasNoAccessibilityHiddenModifier() throws {
        // The hamburger's own `.accessibilityHidden(true)` (what kept it a
        // non-interactive dead tap target rather than a focusable one) must
        // not survive now that the element itself is gone.
        let header = try headerSource()
        XCTAssertFalse(
            header.contains("accessibilityHidden"),
            "no accessibilityHidden modifier should remain in `header` -- it belonged only to the now-removed hamburger element"
        )
    }

    // MARK: - 3. Remaining layout: leading title, single trailing Spacer, untouched add button

    func test_source_header_titleIsLeadingText_beforeAnySpacer() throws {
        let header = try headerSource()
        guard let titleRange = header.range(of: "Text(\"Chat\")"),
              let firstSpacerRange = header.range(of: "Spacer()") else {
            XCTFail("expected to find the \"Chat\" title and a Spacer in `header`'s source")
            return
        }
        XCTAssertTrue(
            titleRange.lowerBound < firstSpacerRange.lowerBound,
            "the \"Chat\" title must lead the HStack, ahead of the trailing Spacer, now that the hamburger's implicit leading balance is gone"
        )
    }

    func test_source_header_hasExactlyOneSpacer() throws {
        // A single trailing Spacer pushes the add button to the far edge --
        // not two Spacers flanking a (now-removed) centered element.
        let header = try headerSource()
        let spacerCount = header.components(separatedBy: "Spacer()").count - 1
        XCTAssertEqual(
            spacerCount, 1,
            "expected exactly one Spacer() in `header`, separating the leading title from the trailing add button"
        )
    }

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
