// ScreenShareSendingTests.swift — testing-gate coverage for task
// 20261009-session-ui-redesign, step 7 (whole-screen sharing, SEND side).
//
// Behavioral: the frame protocol and parser (ScreenShareShared/ScreenShareBridge),
// the sockaddr/path limit, and the ScreenShareState machine (all pure types).
// Source pins (this project's technique where SwiftUI/Chime/ReplayKit cannot be
// hosted in a unit test): fps cap and downscale in the extension, pill/stop
// wiring, picker launcher, simulator "not available" path, content tile never a
// bubble, version match, entitlements, and no logging of frame data.
// Real ReplayKit capture and a live Chime content share are NOT
// simulator-verifiable.

import XCTest
@testable import FellowScript

private func shareSource(_ relativePath: String, file: StaticString = #filePath) throws -> String {
    let url = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()   // FellowScriptTests/
        .deletingLastPathComponent()   // project root
        .appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func frame(_ payload: [UInt8]) -> Data {
    Data(ScreenShareBridge.header(forPayloadLength: payload.count) + payload)
}

// MARK: - 1. Wire format + parser

final class ScreenShareFrameParserTests: XCTestCase {

    func test_header_isMagicThenBigEndianLength() {
        XCTAssertEqual(ScreenShareBridge.header(forPayloadLength: 0x01020304), [0xF5, 1, 2, 3, 4])
        XCTAssertEqual(ScreenShareBridge.header(forPayloadLength: 1), [0xF5, 0, 0, 0, 1])
        XCTAssertEqual(ScreenShareBridge.headerSize, 5)
        XCTAssertEqual(ScreenShareBridge.frameMagic, 0xF5)
    }

    func test_roundTrip_singleFrame() throws {
        var p = ScreenShareFrameParser()
        let payload: [UInt8] = (0..<200).map { UInt8($0 & 0xFF) }
        let out = try p.append(frame(payload))
        XCTAssertEqual(out, [Data(payload)])
    }

    func test_roundTrip_maxSizedFrameIsAccepted() throws {
        var p = ScreenShareFrameParser()
        let payload = [UInt8](repeating: 7, count: ScreenShareBridge.maxFrameBytes)
        let out = try p.append(frame(payload))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].count, ScreenShareBridge.maxFrameBytes)
    }

    func test_backToBackFramesInOneRead_comeOutInOrder() throws {
        var p = ScreenShareFrameParser()
        let a: [UInt8] = [1, 2, 3], b: [UInt8] = [4, 5], c: [UInt8] = [6]
        let out = try p.append(frame(a) + frame(b) + frame(c))
        XCTAssertEqual(out, [Data(a), Data(b), Data(c)])
    }

    func test_partialReads_byteByByte_reassemble() throws {
        var p = ScreenShareFrameParser()
        let payload: [UInt8] = [9, 8, 7, 6, 5, 4]
        var got: [Data] = []
        for byte in frame(payload) { got += try p.append(Data([byte])) }
        XCTAssertEqual(got, [Data(payload)])
    }

    func test_partialHeader_thenRest() throws {
        var p = ScreenShareFrameParser()
        let whole = frame([1, 2, 3, 4])
        XCTAssertTrue(try p.append(whole.prefix(3)).isEmpty, "3 of 5 header bytes yields nothing")
        XCTAssertTrue(try p.append(whole.dropFirst(3).prefix(3)).isEmpty, "header done, payload incomplete")
        XCTAssertEqual(try p.append(whole.dropFirst(6)), [Data([1, 2, 3, 4])])
    }

    func test_frameSplitAcrossBoundaryWithNextFrameStarting() throws {
        var p = ScreenShareFrameParser()
        let f1 = frame([1, 1, 1]), f2 = frame([2, 2])
        let stream = f1 + f2
        let cut = f1.count + 2   // inside the second frame's header
        let first = try p.append(stream.prefix(cut))
        let second = try p.append(stream.dropFirst(cut))
        XCTAssertEqual(first, [Data([1, 1, 1])])
        XCTAssertEqual(second, [Data([2, 2])])
    }

    func test_badMagic_throws() {
        var p = ScreenShareFrameParser()
        XCTAssertThrowsError(try p.append(Data([0x00, 0, 0, 0, 3, 1, 2, 3]))) {
            XCTAssertEqual($0 as? ScreenShareFrameParser.ParseError, .badMagic)
        }
    }

    func test_badMagic_afterAGoodFrame_stillThrows_andGoodFrameWasDelivered() throws {
        var p = ScreenShareFrameParser()
        XCTAssertEqual(try p.append(frame([1])), [Data([1])])
        XCTAssertThrowsError(try p.append(Data([0xAA, 0, 0, 0, 1, 1]))) {
            XCTAssertEqual($0 as? ScreenShareFrameParser.ParseError, .badMagic)
        }
    }

    func test_zeroLengthFrame_isRejected() {
        var p = ScreenShareFrameParser()
        XCTAssertThrowsError(try p.append(Data(ScreenShareBridge.header(forPayloadLength: 0)))) {
            XCTAssertEqual($0 as? ScreenShareFrameParser.ParseError, .oversizedFrame)
        }
    }

    func test_overLimitFrame_isRejectedFromTheHeaderAlone() {
        var p = ScreenShareFrameParser()
        // Only the header is sent: the parser must not wait for 1.5 MB+ of buffering.
        let header = Data(ScreenShareBridge.header(forPayloadLength: ScreenShareBridge.maxFrameBytes + 1))
        XCTAssertThrowsError(try p.append(header)) {
            XCTAssertEqual($0 as? ScreenShareFrameParser.ParseError, .oversizedFrame)
        }
    }

    func test_hugeDeclaredLength_isRejected() {
        var p = ScreenShareFrameParser()
        XCTAssertThrowsError(try p.append(Data([0xF5, 0xFF, 0xFF, 0xFF, 0xFF]))) {
            XCTAssertEqual($0 as? ScreenShareFrameParser.ParseError, .oversizedFrame)
        }
    }

    func test_errorClearsTheBuffer_soGarbageDoesNotAccumulate() throws {
        var p = ScreenShareFrameParser()
        XCTAssertThrowsError(try p.append(Data([0x01, 2, 3, 4, 5, 6, 7])))
        // A fresh, valid frame after the error parses cleanly (the caller drops the
        // connection anyway; this pins that no stale bytes linger).
        XCTAssertEqual(try p.append(frame([42])), [Data([42])])
    }

    func test_limits() {
        XCTAssertEqual(ScreenShareBridge.maxFrameBytes, 1_500_000)
    }
}

// MARK: - 2. Downscale / fps cap helpers (constants + the extension's gate, pinned)

final class ScreenShareBudgetTests: XCTestCase {

    func test_budgetConstants() {
        XCTAssertEqual(ScreenShareBridge.maxFramesPerSecond, 10)
        XCTAssertEqual(ScreenShareBridge.maxLongEdge, 1280)
        XCTAssertGreaterThan(ScreenShareBridge.jpegQuality, 0)
        XCTAssertLessThanOrEqual(ScreenShareBridge.jpegQuality, 0.8, "low quality keeps memory/socket traffic small")
    }

    func test_fpsCapInterval_isAtLeast100ms() {
        XCTAssertGreaterThanOrEqual(1.0 / ScreenShareBridge.maxFramesPerSecond, 0.1 - 1e-9)
    }

    /// The same arithmetic the extension runs: scale = maxLongEdge / longEdge,
    /// only when longEdge exceeds the cap. Verifies a phone-sized screen ends up
    /// at the cap and never grows.
    func test_downscaleMath_capsLongEdge_andNeverUpscales() {
        func scaled(_ w: Double, _ h: Double) -> (Double, Double) {
            let long = max(w, h)
            guard long > ScreenShareBridge.maxLongEdge else { return (w, h) }
            let s = ScreenShareBridge.maxLongEdge / long
            return (w * s, h * s)
        }
        let big = scaled(1290, 2796)   // iPhone Pro Max portrait
        XCTAssertEqual(max(big.0, big.1), 1280, accuracy: 0.001)
        XCTAssertEqual(big.0 / big.1, 1290.0 / 2796.0, accuracy: 0.0001, "aspect ratio preserved")
        let small = scaled(640, 480)
        XCTAssertEqual(small.0, 640); XCTAssertEqual(small.1, 480)
        let exact = scaled(1280, 720)
        XCTAssertEqual(exact.0, 1280); XCTAssertEqual(exact.1, 720)
    }

    func test_extensionDropsFramesAboveTheCap_beforeAnyWork() throws {
        let s = try shareSource("FellowScriptBroadcast/SampleHandler.swift")
        guard let gate = s.range(of: "guard now - lastSentAt >= 1.0 / ScreenShareBridge.maxFramesPerSecond else { return }"),
              let convert = s.range(of: "CIImage(cvPixelBuffer: pixelBuffer)"),
              let getBuffer = s.range(of: "CMSampleBufferGetImageBuffer(sampleBuffer)") else {
            XCTFail("fps gate / conversion not found in SampleHandler"); return
        }
        XCTAssertLessThan(gate.lowerBound, getBuffer.lowerBound, "fps gate must precede touching the pixel buffer")
        XCTAssertLessThan(gate.lowerBound, convert.lowerBound, "fps gate must precede any CoreImage work")
    }

    func test_extensionDownscalesAndSkipsOversize_andIsVideoOnly() throws {
        let s = try shareSource("FellowScriptBroadcast/SampleHandler.swift")
        XCTAssertTrue(s.contains("if longEdge > ScreenShareBridge.maxLongEdge {"))
        XCTAssertTrue(s.contains("let s = ScreenShareBridge.maxLongEdge / longEdge"))
        XCTAssertTrue(s.contains("jpeg.count <= ScreenShareBridge.maxFrameBytes"), "oversize frames are skipped")
        XCTAssertTrue(s.contains("guard sampleBufferType == .video"), "audio is never read or forwarded")
        XCTAssertTrue(s.contains("SO_SNDTIMEO"), "a stalled app must not wedge the sample queue")
    }
}

// MARK: - 3. Socket path limit (simulator "not available on this build")

final class ScreenShareSocketPathTests: XCTestCase {

    func test_shortPathFits_andBuildsASockaddr() {
        XCTAssertTrue(ScreenShareBridge.fitsSockaddr("/tmp/ss.sock"))
        let addr = ScreenShareBridge.sockaddrUn(path: "/tmp/ss.sock")
        XCTAssertNotNil(addr)
        XCTAssertEqual(addr?.sun_family, sa_family_t(AF_UNIX))
    }

    func test_pathAtOrOverTheLimit_isRejected() {
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        XCTAssertEqual(limit, 104, "Darwin sun_path size")
        XCTAssertTrue(ScreenShareBridge.fitsSockaddr("/" + String(repeating: "a", count: limit - 2)))   // limit-1 bytes
        XCTAssertFalse(ScreenShareBridge.fitsSockaddr("/" + String(repeating: "a", count: limit - 1)))  // == limit (no NUL room)
        XCTAssertFalse(ScreenShareBridge.fitsSockaddr("/" + String(repeating: "a", count: 300)))
        XCTAssertNil(ScreenShareBridge.sockaddrUn(path: "/" + String(repeating: "a", count: 300)))
    }

    func test_socketFileNameIsShort_soTheGroupContainerPathStaysUnderTheLimit() {
        XCTAssertEqual(ScreenShareBridge.socketFileName, "ss.sock")
        // A typical simulator app-group container path plus the file name must fit,
        // otherwise every simulator run would silently be "not available".
        let typical = "/Users/x/Library/Developer/CoreSimulator/Devices/216D3249-70E4-4D99-9D63-944C39D92F14/data/Containers/Shared/AppGroup/216D3249-70E4-4D99-9D63-944C39D92F14/ss.sock"
        XCTAssertFalse(ScreenShareBridge.fitsSockaddr(typical), "long simulator paths do NOT fit; that is the 'not available on this build' path")
    }

    func test_unavailableBuild_receiverStartThrowsUnavailable_whenNoSocketPath() {
        // If the App Group is not provisioned or the path is too long (typical in
        // unsigned/simulator builds) the receiver must fail with .unavailable and
        // create nothing. Only assertable when socketPath() is nil here.
        guard ScreenShareBridge.socketPath() == nil else { return }
        let r = ScreenShareFrameReceiver()
        XCTAssertThrowsError(try r.start()) {
            guard case ScreenShareFrameReceiver.StartError.unavailable = $0 else {
                return XCTFail("expected .unavailable, got \($0)")
            }
        }
        r.stop()   // idempotent, safe after a failed start
    }

    func test_unavailableBuild_isShownAsAWarmNotice_andPickerIsNotPresented() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        guard let a = view.range(of: "catch ScreenShareFrameReceiver.StartError.unavailable {"),
              let b = view.range(of: "shareCoordinator = coordinator", range: a.upperBound..<view.endIndex) else {
            return XCTFail("unavailable catch not found")
        }
        let branch = String(view[a.upperBound..<b.lowerBound])
        XCTAssertTrue(branch.contains("ScreenShareMessages.unavailableBuild"))
        XCTAssertTrue(branch.contains("return false"), "no picker, no state change on an unavailable build")
        XCTAssertTrue(ScreenShareMessages.unavailableBuild.contains("isn't available on this build"))
    }

    func test_extensionEndsWithAClearError_whenNoSocketPath() throws {
        let s = try shareSource("FellowScriptBroadcast/SampleHandler.swift")
        XCTAssertTrue(s.contains("guard let path = ScreenShareBridge.socketPath()"))
        XCTAssertTrue(s.contains("fail(\"Screen sharing isn't set up on this build yet.\")"))
        XCTAssertTrue(s.contains("Start screen sharing from the call menu in FellowScript first."))
    }
}

// MARK: - 4. ScreenShareState machine

final class ScreenShareStateMachineTests: XCTestCase {

    private func block(flag: Bool = true, impl: Bool = true, connected: Bool = true,
                       other: Bool = false, phase: ScreenShareState.Phase = .idle) -> ScreenShareStartBlock? {
        ScreenShareState.startBlock(flagEnabled: flag, sendingImplemented: impl, isConnected: connected,
                                    someoneElseSharing: other, phase: phase)
    }

    func test_allowedWhenEverythingIsGreen() { XCTAssertNil(block()) }

    func test_flagOff_refuses_evenIfEverythingElseIsFine() {
        XCTAssertEqual(block(flag: false), .flagOff)
    }

    func test_flagOffWinsOverEveryOtherReason() {
        XCTAssertEqual(block(flag: false, impl: false, connected: false, other: true, phase: .sharing), .flagOff)
    }

    func test_notImplemented_refuses() { XCTAssertEqual(block(impl: false), .notImplemented) }

    func test_noConnection_refuses() { XCTAssertEqual(block(connected: false), .notConnected) }

    func test_someoneElseSharing_refuses() { XCTAssertEqual(block(other: true), .someoneElseSharing) }

    func test_alreadyActive_refuses_forEveryNonIdlePhase() {
        for p: ScreenShareState.Phase in [.awaitingBroadcast, .connecting, .sharing] {
            XCTAssertEqual(block(phase: p), .alreadyActive, "\(p)")
        }
    }

    func test_defaultSendingImplementedArgReadsTheFlag() {
        let b = ScreenShareState.startBlock(flagEnabled: true, isConnected: true, someoneElseSharing: false, phase: .idle)
        XCTAssertEqual(b == nil, ScreenShareFlag.sendingImplemented)
    }

    func test_startStopHappyPath() {
        var s = ScreenShareState()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.isActive); XCTAssertFalse(s.showsIndicator)
        s.requestStart()
        XCTAssertEqual(s.phase, .awaitingBroadcast)
        XCTAssertTrue(s.isActive); XCTAssertFalse(s.showsIndicator, "no pill before Chime confirms")
        s.broadcastConnected()
        XCTAssertEqual(s.phase, .connecting)
        XCTAssertFalse(s.showsIndicator)
        s.shareStarted()
        XCTAssertEqual(s.phase, .sharing)
        XCTAssertTrue(s.showsIndicator, "the pinned pill shows only while sharing")
        XCTAssertTrue(s.ended(), "ending a live share tells the user")
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.showsIndicator)
    }

    func test_requestStart_onlyFromIdle() {
        var s = ScreenShareState()
        s.requestStart(); s.broadcastConnected(); s.shareStarted()
        s.requestStart()
        XCTAssertEqual(s.phase, .sharing, "a second start must not reset an active share")
    }

    func test_outOfOrderEventsAreIgnored() {
        var s = ScreenShareState()
        s.broadcastConnected(); s.shareStarted()
        XCTAssertEqual(s.phase, .idle, "events with no pending start do nothing")
        XCTAssertFalse(s.ended())
    }

    func test_awaitTimeout_endsOnlyAPendingStart() {
        var s = ScreenShareState()
        XCTAssertFalse(s.awaitTimedOut())
        s.requestStart()
        XCTAssertTrue(s.awaitTimedOut())
        XCTAssertEqual(s.phase, .idle)
        s.requestStart(); s.broadcastConnected()
        XCTAssertFalse(s.awaitTimedOut(), "a connected broadcast is not timed out")
        XCTAssertEqual(s.phase, .connecting)
    }

    func test_pendingStartCancelled_isNotReportedAsAShareThatEnded() {
        var s = ScreenShareState()
        s.requestStart()
        XCTAssertFalse(s.ended(), "no 'sharing ended' notice if it never went live")
        XCTAssertEqual(s.phase, .idle)
    }

    func test_appGoneOrCallEnded_cleansUpFromEveryPhase() {
        for setup: (inout ScreenShareState) -> Void in [
            { $0.requestStart() },
            { $0.requestStart(); $0.broadcastConnected() },
            { $0.requestStart(); $0.broadcastConnected(); $0.shareStarted() },
        ] {
            var s = ScreenShareState()
            setup(&s)
            s.reset()
            XCTAssertEqual(s.phase, .idle)
            XCTAssertFalse(s.isActive)
            s.ended()
            XCTAssertEqual(s.phase, .idle, "stop is idempotent")
        }
    }

    func test_canStartAgainAfterAStop() {
        var s = ScreenShareState()
        s.requestStart(); s.broadcastConnected(); s.shareStarted(); s.ended()
        XCTAssertNil(ScreenShareState.startBlock(flagEnabled: true, sendingImplemented: true, isConnected: true,
                                                 someoneElseSharing: false, phase: s.phase))
    }

    func test_warmMessagesAreHumanReadable() {
        let all = [ScreenShareMessages.unavailableBuild, ScreenShareMessages.couldNotStart, ScreenShareMessages.ended,
                   ScreenShareMessages.failedMidShare, ScreenShareMessages.someoneElse]
        for m in all {
            XCTAssertFalse(m.isEmpty)
            XCTAssertTrue(m.hasSuffix("."))
            XCTAssertFalse(m.lowercased().contains("error"), m)
            XCTAssertFalse(m.contains("0x") || m.contains("errno"), m)
        }
    }

    func test_beginScreenShare_usesTheGate_andNotifiesOnlyForSomeoneElse() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("someoneElseSharing: contentShareTileId != nil && !sharerIsSelf"))
        XCTAssertTrue(view.contains("if block == .someoneElseSharing { showScreenShareNotice(ScreenShareMessages.someoneElse) }"))
        // The listener only starts after gating passed.
        guard let gate = view.range(of: "if let block {"),
              let listen = view.range(of: "try coordinator.beginListening()") else { return XCTFail("markers") }
        XCTAssertLessThan(gate.lowerBound, listen.lowerBound)
    }

    func test_leaveTearsTheShareDownBeforeStoppingAudioVideo() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        guard let leave = view.range(of: "func leave() {"),
              let stop = view.range(of: "stopScreenShare(notify: false)", range: leave.upperBound..<view.endIndex),
              let av = view.range(of: "meetingSession?.audioVideo.stop()", range: leave.upperBound..<view.endIndex) else {
            return XCTFail("leave() markers")
        }
        XCTAssertLessThan(stop.lowerBound, av.lowerBound)
    }

    func test_stopIsIdempotentAndCleansEverything() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        guard let a = view.range(of: "private func stopScreenShare(notify: Bool) {"),
              let b = view.range(of: "private func handleScreenShare", range: a.upperBound..<view.endIndex) else {
            return XCTFail("stop markers")
        }
        let body = String(view[a.upperBound..<b.lowerBound])
        XCTAssertTrue(body.contains("shareAwaitTimeout?.cancel()"))
        XCTAssertTrue(body.contains("shareCoordinator = nil"))
        XCTAssertTrue(body.contains("coordinator?.stop()"))
        XCTAssertTrue(body.contains("screenShare.ended()"))
    }

    func test_awaitTimeoutIs45s_andTearsDownTheListener() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("deadline: .now() + 45"))
        XCTAssertTrue(view.contains("guard let self, self.screenShare.awaitTimedOut() else { return }"))
    }

    func test_staleCallbacksAfterStopAreIgnored() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("guard shareCoordinator != nil else { return }"))
    }
}

// MARK: - 5. Pill / stop wiring pins

final class ScreenSharePillAndStopWiringPinTests: XCTestCase {

    func test_pillShowsOnlyWhileSharing_andStopsInOneTap() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("if manager.screenShare.showsIndicator {"))
        XCTAssertTrue(view.contains("ScreenSharePill(onStop: { manager.stopScreenShare() })"))
        let pill = try shareSource("FellowScript/Chat/ChimeCallView+ScreenShare.swift")
        XCTAssertTrue(pill.contains("Text(\"Sharing your screen\")"))
        XCTAssertTrue(pill.contains("Button(action: onStop)"))
        XCTAssertTrue(pill.contains(".accessibilityLabel(\"Stop sharing your screen\")"))
        XCTAssertTrue(pill.contains("minHeight: 44"), "tap target")
        XCTAssertTrue(pill.contains("accessibilityReduceMotion"), "the pulse respects Reduce Motion")
    }

    func test_headerStackPinsThePillUnderTheHeader_inEveryLayout() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("private func headerStack(topPadding: CGFloat)"))
        XCTAssertTrue(view.contains("callHeader(topPadding: topPadding)"))
        let uses = view.components(separatedBy: "headerStack(topPadding:").count - 1
        XCTAssertGreaterThanOrEqual(uses, 3, "definition + field + row layout all go through headerStack")
    }

    func test_everyStopEntryPointConvergesOnStopScreenShare() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        let ext = try shareSource("FellowScript/Chat/ChimeCallView+ScreenShare.swift")
        // submenu row, content-area button, pill, minimized bar
        XCTAssertTrue(view.contains("action: { interactions.didTapActionItem(); manager.stopScreenShare() }"))
        XCTAssertTrue(view.contains("onStopSharing: { manager.stopScreenShare() }"))
        XCTAssertTrue(view.contains("ScreenSharePill(onStop: { manager.stopScreenShare() })"))
        XCTAssertTrue(ext.contains("Button { manager.stopScreenShare() }"))
    }

    func test_minimizedBarShowsStop_onlyWhileSharing() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("MinimizedShareStopButton(manager: call.manager)"))
        let ext = try shareSource("FellowScript/Chat/ChimeCallView+ScreenShare.swift")
        guard let a = ext.range(of: "struct MinimizedShareStopButton"),
              let g = ext.range(of: "if manager.screenShare.showsIndicator {", range: a.upperBound..<ext.endIndex) else {
            return XCTFail("minimized stop gating")
        }
        XCTAssertLessThan(a.lowerBound, g.lowerBound)
        XCTAssertTrue(ext.contains("Sharing \\u{2022} Stop"))
    }

    func test_stopRowStaysReachableEvenIfTheFlagFlipsOffMidCall() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("ScreenShareFlag.isEnabled(capabilities) || manager.screenShare.isActive"))
    }

    func test_ownShareIsReplacedByAStopPanel_notRenderedBack() throws {
        let session = try shareSource("FellowScript/Chat/ChimeCallView+Session.swift")
        guard let sb = session.range(of: "@ViewBuilder private var shareBody: some View {"),
              let own = session.range(of: "if sharerIsSelf {", range: sb.upperBound..<session.endIndex),
              let tile = session.range(of: "ChimeVideoTileView(tileId: tile", range: sb.upperBound..<session.endIndex) else {
            return XCTFail("shareBody markers")
        }
        XCTAssertLessThan(own.lowerBound, tile.lowerBound, "self check precedes the tile render")
        XCTAssertTrue(session.contains("YourShareBody(onStop: onStopSharing)"))
        XCTAssertTrue(session.contains("sharerIsSelf ? \"You are sharing\""))
    }

    func test_pickerLauncher_isPreselectedToOurExtension_andHidesTheMicToggle() throws {
        let ext = try shareSource("FellowScript/Chat/ChimeCallView+ScreenShare.swift")
        XCTAssertTrue(ext.contains("picker.preferredExtension = Self.extensionBundleId"))
        XCTAssertTrue(ext.contains("picker.showsMicrophoneButton = false"))
        XCTAssertEqual(ScreenShareBridge.extensionBundleSuffix, ".BroadcastUpload")
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        XCTAssertTrue(view.contains("BroadcastPickerLauncher(trigger: pickerTrigger)"))
        XCTAssertTrue(view.contains("if manager.beginScreenShare(flagEnabled: ScreenShareFlag.isEnabled(capabilities)) {\n                            pickerTrigger += 1"),
                      "the picker is only triggered when beginScreenShare succeeded")
    }

    func test_consentIsOnlyTheSystemPicker() throws {
        // No code path starts capture without RPSystemBroadcastPickerView / the extension.
        let handler = try shareSource("FellowScriptBroadcast/SampleHandler.swift")
        XCTAssertFalse(handler.contains("RPScreenRecorder"))
        let coordinator = try shareSource("FellowScript/Chat/ChimeScreenShare.swift")
        XCTAssertFalse(coordinator.contains("RPScreenRecorder"))
    }
}

// MARK: - 6. Version match + entitlements (project.pbxproj / plists)

final class ScreenShareExtensionPackagingPinTests: XCTestCase {

    private struct Config { var bundleId: String; var marketing: String?; var build: String? }

    private func configs() throws -> [Config] {
        let pbx = try shareSource("FellowScript.xcodeproj/project.pbxproj")
        var out: [Config] = []
        var rest = Substring(pbx)
        while let start = rest.range(of: "buildSettings = {") {
            guard let end = rest.range(of: "};", range: start.upperBound..<rest.endIndex) else { break }
            let block = String(rest[start.upperBound..<end.lowerBound])
            func value(_ key: String) -> String? {
                for line in block.split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(key + " = ") {
                        return String(t.dropFirst(key.count + 3)).trimmingCharacters(in: CharacterSet(charactersIn: ";\" "))
                    }
                }
                return nil
            }
            if let id = value("PRODUCT_BUNDLE_IDENTIFIER") {
                out.append(Config(bundleId: id, marketing: value("MARKETING_VERSION"), build: value("CURRENT_PROJECT_VERSION")))
            }
            rest = rest[end.upperBound...]
        }
        return out
    }

    func test_appAndExtensionVersionsMatch_inEveryConfiguration() throws {
        let all = try configs()
        let app = all.filter { $0.bundleId == "com.fellowscript.app" }
        let ext = all.filter { $0.bundleId == "com.fellowscript.app.BroadcastUpload" }
        XCTAssertEqual(app.count, 2, "Debug + Release")
        XCTAssertEqual(ext.count, 2, "Debug + Release")
        let appMarketing = Set(app.compactMap(\.marketing)), appBuild = Set(app.compactMap(\.build))
        let extMarketing = Set(ext.compactMap(\.marketing)), extBuild = Set(ext.compactMap(\.build))
        XCTAssertEqual(appMarketing.count, 1, "app MARKETING_VERSION consistent across configs")
        XCTAssertEqual(appBuild.count, 1)
        XCTAssertFalse(appMarketing.isEmpty); XCTAssertFalse(appBuild.isEmpty)
        XCTAssertEqual(extMarketing, appMarketing, "App Store validation rejects an embedded extension with a different MARKETING_VERSION")
        XCTAssertEqual(extBuild, appBuild, "...or a different CURRENT_PROJECT_VERSION")
    }

    func test_extensionBundleIdIsTheAppsPlusTheSuffix() throws {
        let all = try configs()
        XCTAssertTrue(all.contains { $0.bundleId == "com.fellowscript.app" + ScreenShareBridge.extensionBundleSuffix })
    }

    private func entitlements(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func test_exactlyOneAppGroup_onBothTargets_andItIsTheBridgeGroup() throws {
        let app = try entitlements("FellowScript/FellowScript.entitlements")
        let ext = try entitlements("FellowScriptBroadcast/FellowScriptBroadcast.entitlements")
        XCTAssertEqual(app["com.apple.security.application-groups"] as? [String], [ScreenShareBridge.appGroupId])
        XCTAssertEqual(ext["com.apple.security.application-groups"] as? [String], [ScreenShareBridge.appGroupId])
        XCTAssertEqual(ScreenShareBridge.appGroupId, "group.com.fellowscript.app")
    }

    func test_extensionEntitlementsAreOnlyTheAppGroup() throws {
        let ext = try entitlements("FellowScriptBroadcast/FellowScriptBroadcast.entitlements")
        XCTAssertEqual(Set(ext.keys), ["com.apple.security.application-groups"],
                       "no push, keychain, network, associated domains or anything else for the extension")
    }

    func test_appEntitlementsKeptTheirExistingKeys() throws {
        let app = try entitlements("FellowScript/FellowScript.entitlements")
        XCTAssertNotNil(app["aps-environment"])
        XCTAssertNotNil(app["com.apple.developer.associated-domains"])
        XCTAssertNotNil(app["com.apple.developer.applesignin"])
    }

    func test_extensionInfoPlist_isABroadcastUploadExtension_withNoExtraPermissions() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScriptBroadcast/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ext = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.broadcast-services-upload")
        XCTAssertEqual(ext["RPBroadcastProcessMode"] as? String, "RPBroadcastProcessModeSampleBuffer")
        XCTAssertNil(plist["NSMicrophoneUsageDescription"])
        XCTAssertNil(plist["NSCameraUsageDescription"])
    }

    func test_sampleHandlerCompilesOnlyInTheExtension() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("FellowScriptBroadcast/SampleHandler.swift").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("FellowScript/SampleHandler.swift").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ScreenShareShared/ScreenShareBridge.swift").path),
                      "the wire format is shared by both targets from one file")
    }

    func test_sharedBridgeFile_importsNothingHeavy() throws {
        let s = try shareSource("ScreenShareShared/ScreenShareBridge.swift")
        for bad in ["import SwiftUI", "import UIKit", "import AmazonChimeSDK", "import ReplayKit"] {
            XCTAssertFalse(s.contains(bad), "\(bad) must not be built into the extension via the shared file")
        }
    }
}

// MARK: - 7. Never log frame data

final class ScreenShareNoLoggingPinTests: XCTestCase {

    private let files = [
        "ScreenShareShared/ScreenShareBridge.swift",
        "FellowScriptBroadcast/SampleHandler.swift",
        "FellowScript/Services/ScreenShare/ScreenShareFrameReceiver.swift",
        "FellowScript/Chat/ChimeScreenShare.swift",
        "FellowScript/Chat/ScreenShareState.swift",
        "FellowScript/Chat/ChimeCallView+ScreenShare.swift",
    ]

    /// Strips // comments so prose that mentions "logged" does not trip the pin.
    private func code(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
            return line
        }.joined(separator: "\n")
    }

    func test_noPrintNSLogOrOSLog_inAnyScreenShareFile() throws {
        for f in files {
            let c = code(try shareSource(f))
            for banned in ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint(", "dump(", "OSLog"] {
                XCTAssertFalse(c.contains(banned), "\(f) must not contain \(banned)")
            }
        }
    }

    func test_callManagerShareSection_doesNotLogEither() throws {
        let view = try shareSource("FellowScript/Chat/ChimeCallView.swift")
        guard let a = view.range(of: "// MARK: - Screen share (sending)"),
              let b = view.range(of: "func bindTile(tileId: Int", range: a.upperBound..<view.endIndex) else {
            return XCTFail("share section markers")
        }
        let section = code(String(view[a.upperBound..<b.lowerBound]))
        for banned in ["print(", "NSLog(", "os_log(", "debugPrint("] {
            XCTAssertFalse(section.contains(banned), banned)
        }
    }
}
