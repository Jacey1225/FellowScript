// Source pins for task 20261024-chat-chips-edge-blur: message bubbles fade to zero alpha at the
// clip line under the group chip row (alpha mask on the scroll area, no material overlay).

import XCTest

final class ChipRowEdgeFadeRegressionTests: XCTestCase {
    private func chatThreadViewSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Chat/ChatThreadView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_source_chipRowEdgeAlphaMask_startsClearAndRampsToOpaque_noMaterialOverlay() throws {
        let source = try chatThreadViewSource()
        guard let start = source.range(of: "private var chipRowEdgeAlphaMask: some View {"),
              let end = source.range(of: "// ── Sessions submenu (task 20260920-chat-sessions-submenu)") else {
            return XCTFail("chipRowEdgeAlphaMask not found")
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(".init(color: .black.opacity(0.0), location: 0)"))
        XCTAssertTrue(body.contains(".init(color: .black, location: 1)"))
        XCTAssertTrue(body.contains(".frame(height: 36)"))
        XCTAssertTrue(body.contains(".ignoresSafeArea()"))
        XCTAssertFalse(body.contains("Material"))
        XCTAssertFalse(source.contains("chipRowEdgeFade"))
    }

    func test_source_alphaMask_isAppliedToMessageList_onlyWhenChipRowShows() throws {
        let source = try chatThreadViewSource()
        XCTAssertTrue(source.contains("""
                .mask {
                    if GroupInfoCategory.rowShows(isGroup: contact.type == .group, isThreadOpen: vm.isThreadOpen) {
                        chipRowEdgeAlphaMask
                    } else {
"""))
    }
}
