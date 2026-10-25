// Source pins for task 20261024-chat-chips-bottom: the accessory slot (chips <-> attach
// buttons), the shared chip style, the plus swap and its reverse triggers.

import XCTest

final class ComposerAccessorySlotRegressionTests: XCTestCase {
    private func src(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/\(rel)"), encoding: .utf8)
    }

    func test_motionTokens() throws {
        let s = try src("Chat/ComposerAccessorySlot.swift")
        XCTAssertTrue(s.contains("Animation.spring(response: 0.32, dampingFraction: 0.86)"))
        XCTAssertTrue(s.contains("static let slide: CGFloat = 12"))
        XCTAssertTrue(s.contains("Animation.easeOut(duration: 0.2)"), "opacity leads the movement")
        XCTAssertTrue(s.contains("reduceMotion ? 0 : ComposerAccessoryMotion.slide"), "Reduce Motion: cross-fade only")
    }

    func test_slot_bothLayersMounted_drivenByOneBool_hiddenLayerInert() throws {
        let s = try src("Chat/ComposerAccessorySlot.swift")
        XCTAssertTrue(s.contains(".allowsHitTesting(!attachMode)"))
        XCTAssertTrue(s.contains(".allowsHitTesting(attachMode)"))
        XCTAssertTrue(s.contains(".accessibilityHidden(attachMode)"))
        XCTAssertTrue(s.contains(".accessibilityHidden(!attachMode)"))
        XCTAssertTrue(s.contains("max(48, chipHeight + 10)"), "stable 48pt slot")
        XCTAssertTrue(s.contains("showsChips || attachMode ? slotHeight : 0"), "DMs reserve nothing when idle")
    }

    func test_chipAndAttachButtonsShareOneStyle_pillButtonUntouched() throws {
        let row = try src("Chat/GroupInfoChipRow.swift")
        let attach = try src("Chat/MessageAttachments.swift")
        XCTAssertTrue(row.contains("ChipButtonStyle(isSelected: isSelected, compact: compact)"))
        XCTAssertTrue(attach.contains("ChipButtonStyle(compact: compact, hasIcon: true)"))
        let start = try XCTUnwrap(attach.range(of: "struct AttachPickerRow: View {")?.lowerBound)
        let end = try XCTUnwrap(attach.range(of: "// ── Native pickers")?.lowerBound)
        XCTAssertFalse(String(attach[start..<end]).contains("PillButton"))
        for label in ["Photo & Video", "File", "GIF"] { XCTAssertTrue(String(attach[start..<end]).contains("title: \"\(label)\"")) }
        let style = try src("Chat/ChipButtonStyle.swift")
        XCTAssertTrue(style.contains("Theme.parchment.opacity(pressed ? 0.14 : 0.07)"))
        XCTAssertTrue(style.contains("scaleEffect(pressed && !reduceMotion ? 0.97 : 1)"))
        XCTAssertTrue(style.contains("compact ? 12.5 : 13.5"))
    }

    func test_plusButton_rotatesAndKeepsItsLabel() throws {
        let s = try src("Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains(".rotationEffect(.degrees(showAttachSheet && !reduceMotion ? 45 : 0))"))
        XCTAssertTrue(s.contains(".accessibilityLabel(\"Attach a photo, video, file, or GIF\")"))
        XCTAssertTrue(s.contains("Button(action: { setAttachMode(!showAttachSheet) })"))
    }

    func test_setAttachMode_closesPanelAndSessionsInSameTransaction() throws {
        let s = try src("Chat/ChatThreadView.swift")
        let start = try XCTUnwrap(s.range(of: "private func setAttachMode(_ on: Bool) {")?.lowerBound)
        let body = String(s[start...].prefix(700))
        XCTAssertTrue(body.contains("withMotionAwareAnimation(ComposerAccessoryMotion.swap, reduceMotion: reduceMotion)"))
        XCTAssertTrue(body.contains("if on { infoCategory = nil; showSessionsMenu = false }"))
        XCTAssertTrue(body.contains("showAttachSheet = on"))
    }

    func test_reverseTriggers_tapOutside_focus_pick_send() throws {
        let s = try src("Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains(".collapsesAttachOnTap(showAttachSheet) { setAttachMode(false) }"))
        XCTAssertTrue(s.contains("onPickPhotoVideo: { setAttachMode(false); DispatchQueue.main.async { showPhotoVideoPicker = true } }"))
        XCTAssertTrue(s.contains("onPickFile:       { setAttachMode(false); DispatchQueue.main.async { showDocumentPicker = true } }"))
        XCTAssertTrue(s.contains("onPickGif:        { setAttachMode(false); DispatchQueue.main.async { showGifSheet = true } }"))
        XCTAssertTrue(s.contains("ComposerAttachCoordination(attachMode: $showAttachSheet"))
        let slot = try src("Chat/ComposerAccessorySlot.swift")
        XCTAssertTrue(slot.contains("if focused && attachMode { collapse() }"))
        let send = try XCTUnwrap(s.range(of: "private func sendMessage() {")?.lowerBound)
        XCTAssertTrue(String(s[send...].prefix(1800)).contains("setAttachMode(false)"))
    }

    func test_sessionsCard_headerOnlyAnchor() throws {
        let s = try src("Chat/ChatThreadView.swift")
        XCTAssertTrue(s.contains(".padding(.top, 76)"))
        XCTAssertFalse(s.contains("? 132 : 76"))
    }
}
