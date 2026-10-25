// Source pins for task 20261024-chat-chips-bottom (supersedes the top fade of
// 20261024-chat-chips-edge-blur): message bubbles fade to zero alpha at the BOTTOM of the
// list, above the chip row (alpha mask on the scroll view only, no material overlay), and the
// chip row sits in the composer's accessory slot.

import XCTest

final class ChipRowEdgeFadeRegressionTests: XCTestCase {
    private func src(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/\(rel)"), encoding: .utf8)
    }

    func test_source_bottomEdgeAlphaMask_startsOpaqueAndRampsToClear_noMaterialOverlay() throws {
        let source = try src("Chat/ComposerAccessorySlot.swift")
        guard let start = source.range(of: "struct BottomEdgeAlphaMask: View {"),
              let end = source.range(of: "extension View {") else { return XCTFail("BottomEdgeAlphaMask not found") }
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(".init(color: .black, location: 0)"))
        XCTAssertTrue(body.contains(".init(color: .black.opacity(0.0), location: 1)"), "alpha reaches 0 at the list's bottom edge")
        XCTAssertTrue(body.contains("rampHeight: CGFloat = 36"))
        XCTAssertTrue(body.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertFalse(body.contains(".ignoresSafeArea()"), "bottom must not extend under the composer")
        XCTAssertFalse(body.contains("Material"))
        XCTAssertFalse(body.contains("Color.clear"), "no extra clear block below the ramp: the list already ends at the inset edge")
        XCTAssertFalse(body.contains("GeometryReader"), "inset must not be counted twice")
        XCTAssertFalse(body.contains("safeAreaInsets"))
    }

    func test_source_noTopFadeRemains() throws {
        let s = try src("Chat/ChatThreadView.swift")
        XCTAssertFalse(s.contains("chipRowEdgeAlphaMask"))
        XCTAssertFalse(s.contains("chipRowEdgeFade"))
        XCTAssertFalse(s.contains("                .mask {"), "the old whole-area mask is gone")
    }

    func test_source_bottomFade_wrapsScrollViewOnly_jumpButtonOutsideMask() throws {
        let s = try src("Chat/ChatThreadView.swift")
        let fade = try XCTUnwrap(s.range(of: ".bottomEdgeFade(GroupInfoCategory.rowShows(isGroup: contact.type == .group, isThreadOpen: vm.isThreadOpen))")?.lowerBound)
        let jump = try XCTUnwrap(s.range(of: "jumpToLatestButton(proxy: proxy)\n                                .padding(.bottom, Theme.spacingSM)")?.lowerBound)
        XCTAssertTrue(fade < jump, "the fade is applied before the jump-to-latest overlay so the button is not masked")
        let panel = try XCTUnwrap(s.range(of: ".overlay { groupInfoPanelHost }")?.lowerBound)
        XCTAssertTrue(jump < panel)
    }

    func test_source_composerBackdrop_usesFixedPointRampCoveringTheSlot() throws {
        let s = try src("Chat/ChatThreadView.swift")
        let start = try XCTUnwrap(s.range(of: "private var composer: some View {")?.lowerBound)
        let composer = String(s[start...].prefix(9000))
        XCTAssertTrue(composer.contains(".frame(height: 40)"))
        XCTAssertTrue(composer.contains(".padding(.top, -40)"))
        XCTAssertTrue(composer.contains(".ultraThinMaterial"))
    }

    func test_source_chipRowSitsInComposerAccessorySlot_notUnderTheHeader() throws {
        let s = try src("Chat/ChatThreadView.swift")
        let composerStart = try XCTUnwrap(s.range(of: "private var composer: some View {")?.lowerBound)
        let slot = try XCTUnwrap(s.range(of: "ComposerAccessorySlot(")?.lowerBound)
        let row = try XCTUnwrap(s.range(of: "GroupInfoChipRow(")?.lowerBound)
        let textRow = try XCTUnwrap(s.range(of: "HStack(spacing: 10) {\n                attachButton")?.lowerBound)
        XCTAssertTrue(composerStart < slot && slot < row && row < textRow, "slot sits directly above the text row")
        XCTAssertEqual(s.components(separatedBy: "GroupInfoChipRow(").count - 1, 1)
    }

    func test_source_dismissKeyboardStillPrecedesSafeAreaInset() throws {
        let s = try src("Chat/ChatThreadView.swift")
        let d = try XCTUnwrap(s.range(of: ".dismissesKeyboardOnScrollAndTap()")?.lowerBound)
        let i = try XCTUnwrap(s.range(of: ".safeAreaInset(edge: .bottom, spacing: 0) {\n                composer")?.lowerBound)
        XCTAssertTrue(d < i)
    }
}
