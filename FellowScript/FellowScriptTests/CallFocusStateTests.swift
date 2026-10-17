// CallFocusStateTests.swift -- testing gate for task 20261016-call-maximize-tiles
// (iOS). Behavioral tests drive the pure CallFocusLogic; view wiring that cannot
// be hosted without the Chime SDK is pinned against shipped source.

import XCTest
@testable import FellowScript

private func focusSource(_ relativePath: String, file: StaticString = #filePath) throws -> String {
    let url = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

final class CallFocusStateTests: XCTestCase {

    private let names = ["a1": "Maya", "a2": "Eli"]
    private func roster(local: Int? = 1, camOn: Bool = true, remote: [Int] = [10, 11],
                        audio: [String] = []) -> [CallBubbleItem] {
        var att = [Int: String](); var ext = [String: String](); var nm = [String: String]()
        for (i, t) in remote.enumerated() { att[t] = "a\(i + 1)"; ext["a\(i + 1)"] = "u\(i + 1)"; nm["u\(i + 1)"] = ["Maya", "Eli"][i % 2] }
        for a in audio { ext[a] = "x\(a)"; nm["x\(a)"] = "Sam" }
        return CallBubbleRoster.items(localTileId: local, cameraOn: camOn, remoteTileIds: remote,
                                      tileAttendee: att, remoteAttendeeIds: remote.indices.map { "a\($0 + 1)" } + audio,
                                      externalUserIds: ext, names: nm)
    }
    private func valid(_ t: FocusedTile, _ items: [CallBubbleItem], share: Int? = nil, self_: Bool = false) -> Bool {
        CallFocusLogic.isValid(t, items: items, shareTileId: share, sharerIsSelf: self_)
    }

    // MARK: maximizable

    func test_ownAndRemoteCameraWithVideo_areMaximizable() {
        let items = roster()
        XCTAssertTrue(CallFocusLogic.isMaximizable(items[0]), "own camera on")
        XCTAssertTrue(CallFocusLogic.isMaximizable(items[1]))
        XCTAssertTrue(CallFocusLogic.isMaximizable(items[2]))
    }

    func test_audioOnlyAndOwnCameraOff_notMaximizable() {
        let items = roster(camOn: false, remote: [10], audio: ["z9"])
        XCTAssertFalse(CallFocusLogic.isMaximizable(items[0]), "own camera off")
        XCTAssertFalse(CallFocusLogic.isMaximizable(items.last!), "audio only")
        XCTAssertEqual(items.last!.accessibilityText, "Sam, audio only")
    }

    // MARK: validity / switching / auto-restore

    func test_focusOwnAndRemoteCamera_valid() {
        let items = roster()
        XCTAssertTrue(valid(.camera("self"), items))
        XCTAssertTrue(valid(.camera("tile-10"), items))
    }

    func test_switchFocus_isJustAnotherTileValue_onlyOneAtATime() {
        let items = roster()
        var f: FocusedTile = .camera("tile-10")
        f = .camera("tile-11")
        XCTAssertTrue(valid(f, items))
        XCTAssertNotEqual(f, .camera("tile-10"))
        f = .share
        XCTAssertNotEqual(f, .camera("tile-11"), "share replaces camera focus")
    }

    func test_participantLeaves_focusBecomesInvalid() {
        XCTAssertFalse(valid(.camera("tile-11"), roster(remote: [10])))
    }

    func test_remoteCameraOff_tileGone_focusInvalid() {
        // camera off -> tile removed from roster; attendee stays as audio-only
        let items = roster(remote: [10], audio: ["a2"])
        XCTAssertFalse(valid(.camera("tile-11"), items))
    }

    func test_ownCameraOff_focusInvalid() {
        XCTAssertFalse(valid(.camera("self"), roster(camOn: false)))
    }

    func test_audioOnlyItem_cannotHoldFocus() {
        let items = roster(remote: [10], audio: ["z9"])
        XCTAssertFalse(valid(.camera("att-z9"), items))
    }

    func test_shareFocus_validOnlyWhileRemoteShareExists() {
        let items = roster()
        XCTAssertTrue(valid(.share, items, share: 99))
        XCTAssertFalse(valid(.share, items, share: nil), "sharer stopped")
    }

    func test_ownShare_isNeverEnlargeable() {
        XCTAssertFalse(valid(.share, roster(), share: 99, self_: true))
    }

    func test_newShareStarting_doesNotChangeCameraFocus() {
        let items = roster()
        XCTAssertTrue(valid(.camera("tile-10"), items, share: nil))
        XCTAssertTrue(valid(.camera("tile-10"), items, share: 99), "camera stays focused")
    }

    // MARK: loss reason + announcements

    func test_loss_reasons() {
        let cam = CallFocus(tile: .camera("tile-11"), name: "Eli", attendeeId: "a2")
        XCTAssertEqual(CallFocusLogic.loss(of: cam, remoteAttendeeIds: ["a1", "a2"]), .cameraOff)
        XCTAssertEqual(CallFocusLogic.loss(of: cam, remoteAttendeeIds: ["a1"]), .left)
        XCTAssertEqual(CallFocusLogic.loss(of: CallFocus(tile: .camera("self"), name: "You", attendeeId: nil),
                                           remoteAttendeeIds: []), .ownCameraOff)
        XCTAssertEqual(CallFocusLogic.loss(of: CallFocus(tile: .share, name: "Maya", attendeeId: nil),
                                           remoteAttendeeIds: ["a1"]), .shareEnded)
    }

    func test_announcements_areWarm_andNameFallbackWorks() {
        XCTAssertEqual(CallFocusLogic.announcement(for: .left, name: "Eli"), "Eli left the call. Back to everyone.")
        XCTAssertEqual(CallFocusLogic.announcement(for: .cameraOff, name: "Eli"), "Eli turned their camera off. Back to everyone.")
        XCTAssertEqual(CallFocusLogic.announcement(for: .ownCameraOff, name: nil), "Your camera is off. Back to everyone.")
        XCTAssertEqual(CallFocusLogic.announcement(for: .shareEnded, name: "Maya"), "Maya stopped sharing. Back to everyone.")
        XCTAssertEqual(CallFocusLogic.announcement(for: .left, name: nil), "Someone left the call. Back to everyone.")
    }

    // MARK: strip

    func test_strip_hidesEnlargedCameraOnly() {
        let items = roster()
        XCTAssertEqual(CallFocusLogic.stripItems(items, focused: .camera("tile-10")).map(\.id), ["self", "tile-11"])
        XCTAssertEqual(CallFocusLogic.stripItems(items, focused: .share).count, items.count)
        XCTAssertEqual(CallFocusLogic.stripItems(items, focused: nil).count, items.count)
    }

    func test_showsStrip_collapsesWhenTooShort() {
        XCTAssertTrue(CallFocusLogic.showsStrip(focused: false, containerHeight: 100, headerEstimate: 80, stripHeight: 100, dockZone: 100))
        XCTAssertTrue(CallFocusLogic.showsStrip(focused: true, containerHeight: 800, headerEstimate: 140, stripHeight: 112, dockZone: 120))
        XCTAssertFalse(CallFocusLogic.showsStrip(focused: true, containerHeight: 400, headerEstimate: 80, stripHeight: 112, dockZone: 120))
    }

    // MARK: accessibility copy

    func test_accessibilityLabelsAndHints() {
        let items = roster()
        XCTAssertEqual(items[0].accessibilityText, "You, video on")
        XCTAssertEqual(CallFocusLogic.enlargedCameraLabel(for: items[0]), "You, enlarged video")
        XCTAssertEqual(CallFocusLogic.enlargedCameraLabel(for: items[1]), "Maya, enlarged video")
        XCTAssertEqual(CallFocusLogic.shareLabel(sharerName: "Maya"), "Shared screen from Maya")
        XCTAssertEqual(CallFocusLogic.shareLabel(sharerName: nil), "Shared screen")
        XCTAssertEqual(CallFocusLogic.enlargeHint, "Double tap to enlarge")
        XCTAssertEqual(CallFocusLogic.returnHint, "Double tap to return to everyone")
        XCTAssertEqual(CallFocusLogic.backLabel, "Back to everyone")
    }

    // MARK: source pins (view wiring)

    func test_noShareHeadingText_remainsInCallContentArea() throws {
        let s = try focusSource("FellowScript/Chat/ChimeCallView+Session.swift")
        func code(_ t: String) -> [Substring] { t.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") } }
        XCTAssertTrue(code(s).filter { $0.contains("is sharing\"") }.isEmpty, "no 'is sharing' text in code")
        XCTAssertFalse(s.contains("You are sharing"))
        XCTAssertTrue(s.contains("if kind != .share { header }"))
        let v = try focusSource("FellowScript/Chat/CallFocusViews.swift")
        XCTAssertTrue(code(v).filter { $0.contains("is sharing\"") }.isEmpty)
        // Interactions menu caption stays.
        XCTAssertTrue(try focusSource("FellowScript/Chat/ChimeCallView.swift").contains("is sharing\""))
    }

    func test_returnPaths_tapButtonEscape() throws {
        let v = try focusSource("FellowScript/Chat/CallFocusViews.swift")
        XCTAssertTrue(v.contains("Button(action: onReturn)"), "tap the stage returns")
        XCTAssertTrue(v.contains("CallFocusBackButton(onTap: onReturn)"))
        XCTAssertTrue(v.contains(".accessibilityAction(.escape, onReturn)"))
        XCTAssertTrue(v.contains(".frame(minHeight: 44)"), "Back button 44pt")
        XCTAssertTrue(v.contains(".frame(width: 44, height: 44)"), "expand glyph 44pt")
        XCTAssertTrue(v.contains(".accessibilityHint(CallFocusLogic.returnHint)"))
    }

    func test_bubbles_areButtonsOnlyWhenMaximizable() throws {
        let s = try focusSource("FellowScript/Chat/ChimeCallView+Session.swift")
        XCTAssertTrue(s.contains("if let onEnlarge, CallFocusLogic.isMaximizable(item)"))
        XCTAssertTrue(s.contains(".accessibilityHint(CallFocusLogic.enlargeHint)"))
        let f = try focusSource("FellowScript/Chat/ChimeCallView+RemoteField.swift")
        XCTAssertTrue(f.contains("onEnlarge"))
    }

    func test_ownShareNotEnlargeable_inWiring() throws {
        let f = try focusSource("FellowScript/Chat/ChimeCallView+Focus.swift")
        XCTAssertTrue(f.contains("guard manager.contentShareTileId != nil, !manager.sharerIsSelf else { return }"))
    }

    func test_roomSwitchAndDisappear_clearFocusSilently() throws {
        let v = try focusSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(v.contains(".onChange(of: rooms.state) { _, _ in focus = nil }"))
        XCTAssertTrue(v.contains(".onDisappear { focus = nil }"))
        // reconcileFocus (the announcing path) is not what the room switch calls.
        XCTAssertFalse(v.contains(".onChange(of: rooms.state) { _, _ in reconcileFocus() }"))
    }

    func test_reconcile_announcesViaVoiceOver_andAvoidsDuplicateShareStopped() throws {
        let f = try focusSource("FellowScript/Chat/ChimeCallView+Focus.swift")
        XCTAssertTrue(f.contains("AccessibilityNotification.Announcement(CallFocusLogic.announcement(for: loss, name: lost.name)).post()"))
        let v = try focusSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(v.contains("focus?.tile != .share"))
    }

    func test_reduceMotionPath() throws {
        let f = try focusSource("FellowScript/Chat/ChimeCallView+Focus.swift")
        XCTAssertTrue(f.contains("withMotionAwareAnimation(.easeInOut"))
        XCTAssertTrue(f.contains("reduceMotion: reduceMotion"))
        let v = try focusSource("FellowScript/Chat/CallFocusViews.swift")
        XCTAssertTrue(v.contains("reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))"))
    }

    func test_fieldLayoutSwappedOutWhileEnlarged() throws {
        let f = try focusSource("FellowScript/Chat/ChimeCallView+Focus.swift")
        XCTAssertTrue(f.contains("var showsFieldLayout: Bool { layoutMode == .field && activeFocus == nil }"))
    }
}
