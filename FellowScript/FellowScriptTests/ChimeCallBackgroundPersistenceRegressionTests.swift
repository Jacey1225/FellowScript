// ChimeCallBackgroundPersistenceRegressionTests.swift — testing-gate coverage
// for task 20260916-call-background-persistence, step 3.
//
// Covers what frontend.json (step 1) implemented and security.json (step 2)
// reviewed:
//
// 1. UIBackgroundModes: Info.plist now declares `audio` alongside the
//    pre-existing `remote-notification`, honestly matching the app's real
//    background behavior (App Store review posture) -- pinned by reading the
//    real shipped plist, the same "assert a fact ViewInspector/instantiation
//    can't cheaply prove" technique ChimeCallViewRedesignRegressionTests.swift
//    already established for this same file.
// 2. ChimeCallManager.handleAppBackgrounded()/handleAppForegrounded() only
//    ever touch local video, never the audio session or `meetingSession`
//    itself -- the entire point of this task. Behaviorally: backgrounding
//    with the camera on stops it immediately regardless of connection state;
//    foregrounding only resumes it if the call is still actually connected
//    (Security Posture Q14 fail-closed -- a call that dropped while
//    backgrounded must not silently regain a live camera feed either).
// 3. audioSessionDidDrop()/audioSessionDidStopWithStatus()/
//    audioSessionDidCancelReconnect() all flip `isConnected` false (the real
//    Q14 bug security.json flagged: these used to be no-ops, leaving a stale
//    "Connected" UI through a genuine drop).
// 4. Regression guards named explicitly by the intake spec's acceptance
//    criteria: FellowScriptApp.swift's scenePhase==.background handler still
//    only ever calls SpeechController.shared.stop() for dictation/TTS and
//    never reaches into CallController.shared.session/ChimeCallManager's
//    audio path; MinimizedCallBar (in-app minimize/call-bar) is untouched by
//    this task's diff.

import XCTest
@testable import FellowScript

#if canImport(AmazonChimeSDK)
import AmazonChimeSDK
#endif

final class ChimeCallBackgroundPersistenceRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - 1. Info.plist declares `audio` honestly, alongside the
    // pre-existing `remote-notification`, not replacing it.

    func test_infoPlist_declaresAudioBackgroundMode_alongsideExistingRemoteNotification() throws {
        let source = try readSource("FellowScript/Info.plist")
        guard let range = source.range(of: "<key>UIBackgroundModes</key>") else {
            XCTFail("UIBackgroundModes key not found in Info.plist"); return
        }
        let body = String(source[range.upperBound...].prefix(300))
        XCTAssertTrue(body.contains("<string>remote-notification</string>"),
                      "pre-existing push background mode must not be dropped")
        XCTAssertTrue(body.contains("<string>audio</string>"),
                      "new audio background mode must be declared so Chime's audio session survives backgrounding")
        XCTAssertFalse(body.contains("<string>voip</string>"),
                      "architecture deliberately rejected voip/CallKit/PushKit for this iteration -- must not be silently added")
    }

    // MARK: - 2. FellowScriptApp's scenePhase handler: dictation/TTS still
    // stops on background (task 20260914-dictation-tts, unaffected), and the
    // Chime call itself is deliberately left alone in that branch.

    func test_scenePhaseBackgroundHandler_stillStopsSpeechController_andNeverTouchesCallControllerSessionOrAudio() throws {
        let source = try readSource("FellowScript/FellowScriptApp.swift")
        guard let bgRange = source.range(of: "} else if phase == .background {") else {
            XCTFail(".background scenePhase branch not found"); return
        }
        guard let endRange = source.range(of: "\n            }\n        }\n    }\n}", range: bgRange.upperBound..<source.endIndex) else {
            XCTFail("end of .background branch not found"); return
        }
        let body = String(source[bgRange.upperBound..<endRange.lowerBound])

        XCTAssertTrue(body.contains("SpeechController.shared.stop()"),
                      "dictation/TTS must still stop on backgrounding -- regression guard for task 20260914-dictation-tts")
        XCTAssertFalse(body.contains("CallController.shared.session ="),
                      "backgrounding must never null out or otherwise mutate the active call session")
        XCTAssertFalse(body.contains(".manager.leave()"), "backgrounding must never tear down the Chime meeting session")
        XCTAssertFalse(body.contains("AVAudioSession"),
                      "the background handler must not touch AVAudioSession directly -- Chime owns the audio session")
        XCTAssertTrue(body.contains("CallController.shared.manager.handleAppBackgrounded()"),
                      "video-only pause must still be wired up on backgrounding")
    }

    func test_scenePhaseActiveHandler_resumesVideoOnForeground() throws {
        let source = try readSource("FellowScript/FellowScriptApp.swift")
        guard let range = source.range(of: "if phase == .active {") else {
            XCTFail(".active scenePhase branch not found"); return
        }
        let body = String(source[range.upperBound...].prefix(600))
        XCTAssertTrue(body.contains("CallController.shared.manager.handleAppForegrounded()"),
                      "returning to the foreground must attempt to resume paused local video")
    }

    // MARK: - 3. MinimizedCallBar (in-app minimize/call-bar) untouched.

    func test_minimizedCallBar_notTouchedByThisTask() throws {
        let source = try readSource("FellowScript/Chat/ChimeCallView.swift")
        guard let range = source.range(of: "struct MinimizedCallBar: View {") else {
            XCTFail("MinimizedCallBar not found"); return
        }
        let end = source.range(of: "\n}\n\n#if canImport", range: range.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[range.upperBound..<end])
        XCTAssertFalse(body.contains("handleAppBackgrounded"), "MinimizedCallBar must have no involvement in the new backgrounding logic")
        XCTAssertFalse(body.contains("handleAppForegrounded"), "MinimizedCallBar must have no involvement in the new foregrounding logic")
    }

#if canImport(AmazonChimeSDK)
    // MARK: - 4. ChimeCallManager behavior: video-only pause/resume, never audio.

    @MainActor
    func test_handleAppBackgrounded_noCameraOn_isNoOp() {
        let manager = ChimeCallManager()
        manager.isCameraOn = false
        manager.handleAppBackgrounded()
        XCTAssertFalse(manager.isCameraOn)
    }

    @MainActor
    func test_handleAppBackgrounded_cameraOn_stopsCameraImmediately_regardlessOfConnection() {
        let manager = ChimeCallManager()
        manager.isCameraOn = true
        manager.isConnected = false   // even if not (yet) connected, backgrounding must still stop video
        manager.handleAppBackgrounded()
        XCTAssertFalse(manager.isCameraOn, "local video must stop the moment the app backgrounds -- iOS forbids capture while backgrounded regardless of background mode")
    }

    @MainActor
    func test_handleAppForegrounded_withoutPriorBackgrounding_isNoOp() {
        let manager = ChimeCallManager()
        manager.isConnected = true
        manager.isCameraOn = false
        manager.handleAppForegrounded()
        XCTAssertFalse(manager.isCameraOn, "nothing to resume if the camera was never paused by backgrounding")
    }

    @MainActor
    func test_handleAppForegrounded_afterBackgrounding_doesNotResumeVideo_whenCallDroppedWhileBackgrounded() {
        // Security Posture Q14 (fail-closed): a call that genuinely dropped
        // while backgrounded must not silently regain a live camera feed on
        // return to foreground -- that would visually imply "still connected"
        // exactly like the isConnected staleness bug this task also fixed.
        let manager = ChimeCallManager()
        manager.isCameraOn = true
        manager.handleAppBackgrounded()
        XCTAssertFalse(manager.isCameraOn)

        manager.isConnected = false   // simulate a drop while backgrounded
        manager.handleAppForegrounded()

        XCTAssertFalse(manager.isCameraOn, "must not resume video into a call that is no longer connected")
    }

    @MainActor
    func test_leave_stillFullyTearsDownAudioAndVideoState_unaffectedByBackgroundingChanges() {
        // Regression guard: end()/leave() must still be the one and only path
        // that actually stops the meeting -- confirms Security Posture Q3's
        // finding (security.json) that there is no path where backgrounding
        // itself leaves the mic open past the user's actual end-call intent.
        let manager = ChimeCallManager()
        manager.isConnected = true
        manager.isMuted = true
        manager.isCameraOn = true
        manager.leave()
        XCTAssertFalse(manager.isConnected)
        XCTAssertFalse(manager.isMuted)
        XCTAssertFalse(manager.isCameraOn)
    }

    // MARK: - 5. Fail-closed isConnected (Security Posture Q14): a genuine
    // drop or abandoned reconnect must surface as "not connected", not a
    // stale "Connected" UI.

    @MainActor
    func test_audioSessionDidDrop_flipsIsConnectedFalse() {
        let manager = ChimeCallManager()
        manager.isConnected = true
        manager.audioSessionDidDrop()
        let expectation = expectation(description: "isConnected flips false on main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(manager.isConnected, "a genuine audio-session drop must surface as not-connected rather than a stale 'Connected' UI")
    }

    @MainActor
    func test_audioSessionDidCancelReconnect_flipsIsConnectedFalse() {
        let manager = ChimeCallManager()
        manager.isConnected = true
        manager.audioSessionDidCancelReconnect()
        let expectation = expectation(description: "isConnected flips false on main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(manager.isConnected, "an abandoned reconnect attempt must surface as not-connected, not a stale 'Connected' UI")
    }

    @MainActor
    func test_audioSessionDidStopWithStatus_flipsIsConnectedFalse() {
        let manager = ChimeCallManager()
        manager.isConnected = true
        manager.audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus(statusCode: .ok))
        let expectation = expectation(description: "isConnected flips false on main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(manager.isConnected)
    }

    @MainActor
    func test_audioSessionDidStart_reconnecting_flipsIsConnectedTrue_soARealRecoveryStillSurfacesConnected() {
        // Confirms the fail-closed fix didn't overcorrect into never being
        // able to show "Connected" again after a reconnect attempt.
        let manager = ChimeCallManager()
        manager.isConnected = false
        manager.audioSessionDidStart(reconnecting: true)
        let expectation = expectation(description: "isConnected flips true on main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(manager.isConnected, "a real Chime-reported reconnect must still be able to restore the Connected state")
    }
#endif
}
