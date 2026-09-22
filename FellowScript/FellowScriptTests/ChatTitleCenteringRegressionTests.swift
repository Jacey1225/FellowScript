// ChatTitleCenteringRegressionTests.swift — coverage for task
// 20260921-center-chat-title (testing gate, final step).
//
// Proves the specific centering construction this task's frontend gate made
// against the real, shipped Chat/ChatRootView.swift source, so a regression
// of any one of these facts fails here rather than only being caught by a
// future manual screenshot comparison:
//
//   1. `header` now contains an invisible leading placeholder: a
//      `Circle().fill(Color.clear)` sized 44x44 (matching the trailing "+"
//      button's own 44x44 frame) and marked `.accessibilityHidden(true)` so
//      it never becomes a focusable/announced element.
//   2. The "Chat" title sits between exactly two Spacers, flanked
//      symmetrically -- placeholder -> Spacer -> title -> Spacer -> add
//      button -- which is what actually balances the row's optical center
//      against the fixed-width trailing button, rather than only centering
//      the text between the two screen edges.
//   3. The trailing "+" add button (action, gradient fill, icon, shadow, and
//      its selectedSegment-dependent accessibility label) is completely
//      unaffected by the centering change.
//   4. The stale comment describing the previous leading-aligned/HeroHeader-
//      mirroring rationale (from task 20260921-remove-dead-chat-hamburger) no
//      longer describes `header`'s current behavior as its rationale -- the
//      comment now documents the centering approach itself.
//
// `header` is a private computed property of ChatRootView, which (per this
// project's established convention -- see
// ChatScheduleUICleanupIOSRegressionTests' HeaderAvatarBloomRemovalRegressionTests,
// and this file's own sibling ChatHeaderHamburgerRemovalRegressionTests)
// can't be hosted in a unit test without a live network round trip: its
// containing view requires a real `ChatViewModel` StateObject plus an
// `AppState` EnvironmentObject, and its own `.task` immediately calls
// `vm.load(service:userId:)`. So, consistent with that same precedent, this
// suite reads the real shipped source directly, scoped to just the `header`
// property so a change elsewhere in the file can't accidentally satisfy an
// assertion.

import XCTest
@testable import FellowScript

final class ChatTitleCenteringRegressionTests: XCTestCase {

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

    private func wholeFileSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Chat/ChatRootView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - 1. Invisible leading placeholder, sized to match the add button

    func test_source_header_hasInvisibleLeadingPlaceholderCircle() throws {
        let header = try headerSource()
        XCTAssertTrue(
            header.contains("Circle()") && header.contains(".fill(Color.clear)"),
            "expected an invisible (Color.clear-filled) placeholder Circle in `header` to balance the trailing add button"
        )
    }

    func test_source_header_placeholderPrecedesTitleAndIsFirstElement() throws {
        let header = try headerSource()
        guard let hstackRange = header.range(of: "HStack {"),
              let placeholderFillRange = header.range(of: ".fill(Color.clear)"),
              let titleRange = header.range(of: "Text(\"Chat\")") else {
            XCTFail("expected to find the HStack, the placeholder's Color.clear fill, and the title in `header`'s source")
            return
        }
        XCTAssertTrue(
            hstackRange.upperBound < placeholderFillRange.lowerBound &&
            placeholderFillRange.lowerBound < titleRange.lowerBound,
            "the invisible placeholder must be the first element in the header HStack, ahead of the title"
        )
    }

    func test_source_header_placeholderIs44x44_matchingAddButtonFrame() throws {
        let header = try headerSource()
        // The placeholder's own 44x44 frame, distinct from the add button's
        // separate 44x44 frame later in the source -- both must be present
        // and equal for the centering math to hold.
        let frameOccurrences = header.components(separatedBy: ".frame(width: 44, height: 44)").count - 1
        XCTAssertEqual(
            frameOccurrences, 2,
            "expected two separate 44x44 frames in `header` -- the invisible leading placeholder and the trailing add button -- so they balance each other"
        )
    }

    func test_source_header_placeholderIsAccessibilityHidden() throws {
        let header = try headerSource()
        guard let placeholderFillRange = header.range(of: ".fill(Color.clear)"),
              let accessibilityHiddenRange = header.range(of: ".accessibilityHidden(true)") else {
            XCTFail("expected to find the placeholder's fill and an accessibilityHidden modifier in `header`'s source")
            return
        }
        XCTAssertTrue(
            placeholderFillRange.lowerBound < accessibilityHiddenRange.lowerBound,
            "the placeholder Circle must carry .accessibilityHidden(true) so it's never announced or focusable"
        )
        // Exactly one such modifier -- it belongs only to the placeholder,
        // not duplicated elsewhere in the header.
        let hiddenCount = header.components(separatedBy: "accessibilityHidden").count - 1
        XCTAssertEqual(hiddenCount, 1,
                       "expected exactly one accessibilityHidden modifier in `header`, on the leading placeholder only")
    }

    // MARK: - 2. Title symmetrically flanked by exactly two Spacers

    func test_source_header_hasExactlyTwoSpacers() throws {
        let header = try headerSource()
        let spacerCount = header.components(separatedBy: "Spacer()").count - 1
        XCTAssertEqual(
            spacerCount, 2,
            "expected exactly two Spacer()s in `header`, symmetrically flanking the \"Chat\" title between the placeholder and the add button"
        )
    }

    func test_source_header_order_placeholderThenSpacerThenTitleThenSpacerThenAddButton() throws {
        let header = try headerSource()
        guard let placeholderFillRange = header.range(of: ".fill(Color.clear)"),
              let firstSpacerRange = header.range(of: "Spacer()"),
              let titleRange = header.range(of: "Text(\"Chat\")"),
              let secondSpacerRange = header.range(of: "Spacer()", range: firstSpacerRange.upperBound..<header.endIndex),
              let addButtonRange = header.range(of: "Button(action: addAction)") else {
            XCTFail("expected to find the placeholder, both Spacers, the title, and the add button in `header`'s source")
            return
        }
        XCTAssertTrue(
            placeholderFillRange.lowerBound < firstSpacerRange.lowerBound &&
            firstSpacerRange.lowerBound < titleRange.lowerBound &&
            titleRange.lowerBound < secondSpacerRange.lowerBound &&
            secondSpacerRange.lowerBound < addButtonRange.lowerBound,
            "expected source order: placeholder -> Spacer -> \"Chat\" title -> Spacer -> add button, so the title is symmetrically centered"
        )
    }

    func test_source_header_titleStylingUnchangedByCentering() throws {
        let header = try headerSource()
        XCTAssertTrue(header.contains(".font(.system(size: 27, weight: .heavy))"),
                      "the \"Chat\" title's font must be unchanged by the centering change")
        XCTAssertTrue(header.contains(".foregroundColor(Theme.parchment)"),
                      "the \"Chat\" title's color must be unchanged by the centering change")
    }

    // MARK: - 3. Trailing add button completely unaffected

    func test_source_header_addButtonActionGradientIconShadowUnchanged() throws {
        let header = try headerSource()
        XCTAssertTrue(header.contains("Button(action: addAction)"),
                      "the add button's action must be unaffected by the centering change")
        XCTAssertTrue(
            header.contains(##"LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],"##),
            "the add button's gradient fill must be unaffected by the centering change"
        )
        XCTAssertTrue(header.contains(#"Image(systemName: "plus")"#),
                      "the add button's plus icon must be unaffected by the centering change")
        XCTAssertTrue(header.contains(".shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 6)"),
                      "the add button's shadow must be unaffected by the centering change")
    }

    func test_source_header_addButtonAccessibilityLabelUnchanged() throws {
        let header = try headerSource()
        XCTAssertTrue(
            header.contains(#".accessibilityLabel(selectedSegment == 0 ? "Add friend" : selectedSegment == 1 ? "New group" : "New agent")"#),
            "the add button's segment-dependent accessibility label must be unaffected by the centering change"
        )
    }

    // MARK: - 4. Stale leading-aligned/HeroHeader-mirroring rationale is gone

    func test_source_wholeFile_hasNoStaleLeadingAlignedRationaleComment() throws {
        let source = try wholeFileSource()
        // The old comment described `header` as "mirroring HeroHeader's
        // leading-title convention" -- i.e. presented leading-alignment as
        // the *current* rationale. The new comment may still name HeroHeader
        // (to explain why it now intentionally departs from it), but must not
        // claim this header still mirrors it.
        XCTAssertFalse(
            source.contains("mirroring HeroHeader's leading-title convention in DashboardComponents.swift, per the intake spec"),
            "the stale comment claiming `header` mirrors HeroHeader's leading-title convention must not remain -- the title is now centered"
        )
    }

    func test_source_header_commentDocumentsCenteringApproach() throws {
        let source = try wholeFileSource()
        guard let headerStart = source.range(of: "private var header: some View {") else {
            XCTFail("expected to find `header` in the shipped source")
            return
        }
        // Look at the comment block immediately preceding `header`.
        let precedingText = String(source[source.startIndex..<headerStart.lowerBound])
        guard let lastMarkerRange = precedingText.range(of: "// ── Header:", options: .backwards) else {
            XCTFail("expected to find the header's leading comment block marker")
            return
        }
        let commentBlock = String(precedingText[lastMarkerRange.lowerBound...])
        XCTAssertTrue(
            commentBlock.lowercased().contains("center"),
            "the comment above `header` must describe the current centered layout, not just the removed hamburger"
        )
    }
}
