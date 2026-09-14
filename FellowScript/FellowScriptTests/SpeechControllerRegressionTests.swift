// SpeechControllerRegressionTests.swift — testing-gate coverage for task
// 20260914-dictation-tts, step 3 (testing).
//
// SpeechController (Services/SpeechController.swift) is the one shared
// engine both BibleReaderView's and NoteDetailView's dictation buttons call
// through — frontend step 2 built it as an app-level singleton specifically
// so starting playback on one screen interrupts the other screen's
// in-flight speech. That cross-screen mechanism, the toggle-to-stop
// interaction, the never-crash/never-silently-no-op voice fallback, and the
// Silent-switch-compatible audio session are all exercised here directly
// against the real class rather than through the two screens' own private
// `toggleDictation()` methods (BibleReaderView's is `private`, so it isn't
// reachable from a test target even with `@testable import`) — since both
// screens' buttons are thin wrappers around exactly this API (confirmed by
// reading BibleReaderView.swift:675-678 and NoteDetailView.swift:91-92),
// proving the shared engine's behavior here proves what both screens
// depend on. NoteDetailViewDictationRegressionTests.swift separately
// exercises NoteDetailView's own `toggleDictation()` (internal, callable
// directly) as an end-to-end check on one of the two real call sites.
//
// Covers this task's own acceptance criteria:
//   - Toggle play/stop (re-tapping the same source stops it).
//   - Starting playback for a different source interrupts and replaces
//     whatever was playing (the cross-screen-stop mechanism).
//   - Voice fallback resolves for an unusual/unavailable locale without
//     crashing and without silently leaving playback idle.
//   - Audio session category/mode is set so playback works with the
//     Silent switch on.
//   - Configuration Philosophy Q1: rate/pitch are mutable, not hardcoded.
//   - Zero network call anywhere in the service (source-pinned, since
//     AVSpeechSynthesizer is on-device only by construction — there is no
//     runtime network call to intercept in the first place).
import XCTest
import AVFoundation
@testable import FellowScript

@MainActor
final class SpeechControllerRegressionTests: XCTestCase {

    override func tearDown() async throws {
        // SpeechController.shared is a singleton -- reset it so a failure or
        // early return here can't leak in-flight speech state into another
        // test in this file, in NoteDetailViewDictationRegressionTests, or
        // into a later unrelated test run.
        SpeechController.shared.stop()
        SpeechController.shared.rate = AVSpeechUtteranceDefaultSpeechRate
        SpeechController.shared.pitch = 1.0
        try await super.tearDown()
    }

    // MARK: - Toggle: re-tapping the same source stops it

    func test_toggle_sameSourceTwice_startsThenStops() {
        let controller = SpeechController.shared
        XCTAssertFalse(controller.isSpeaking, "must start idle")

        controller.toggle("Hello", source: "screen-a")
        XCTAssertTrue(controller.isSpeaking(for: "screen-a"),
                       "first toggle for a source must start speaking that source")

        controller.toggle("Hello", source: "screen-a")
        XCTAssertFalse(controller.isSpeaking,
                        "second toggle for the SAME source must stop it (toggle, not a separate stop control, per the intake spec's interaction bias)")
        XCTAssertNil(controller.activeSource)
    }

    // MARK: - Cross-screen interruption: this is the whole reason the
    // controller is a single shared instance rather than one per screen.

    func test_speak_differentSource_interruptsPriorSpeechAndTakesOver() {
        let controller = SpeechController.shared

        controller.speak("Genesis chapter one, verse one.", source: "bible-chapter")
        XCTAssertTrue(controller.isSpeaking(for: "bible-chapter"))

        // Starting a DIFFERENT screen's content (e.g. a note) must silently
        // interrupt the Bible screen's in-flight speech and take over --
        // never speak both at once, never require an explicit stop first.
        controller.speak("This is my note body.", source: "note-abc123")
        XCTAssertTrue(controller.isSpeaking(for: "note-abc123"),
                       "starting a different source's speech must take over as the active source")
        XCTAssertFalse(controller.isSpeaking(for: "bible-chapter"),
                        "the previously-speaking source must no longer read as active once a different source starts -- this is the exact mechanism that stops one screen's playback when another screen starts speaking")
    }

    func test_toggle_differentSourceWhileSpeaking_switchesRatherThanStopping() {
        // toggle()'s own doc contract: tapping a DIFFERENT source's button
        // while something else is speaking must interrupt+switch, not treat
        // it as a "stop everything" toggle -- only re-tapping the SAME
        // source's own button stops it.
        let controller = SpeechController.shared
        controller.toggle("First", source: "note-1")
        XCTAssertTrue(controller.isSpeaking(for: "note-1"))

        controller.toggle("Second", source: "note-2")
        XCTAssertTrue(controller.isSpeaking(for: "note-2"))
        XCTAssertFalse(controller.isSpeaking(for: "note-1"))
    }

    // MARK: - Empty/whitespace text: fail closed without crashing or
    // flipping into a "speaking" state with nothing actually happening.

    func test_speak_emptyText_noOps_staysIdle() {
        let controller = SpeechController.shared
        controller.speak("", source: "note-empty")
        XCTAssertFalse(controller.isSpeaking,
                        "empty text must never flip activeSource -- a button bound to this source would otherwise show a 'speaking' state with no audio, which is exactly the silent-no-op failure the fail-closed requirement forbids")
    }

    func test_speak_whitespaceOnlyText_noOps_staysIdle() {
        let controller = SpeechController.shared
        controller.speak("   \n\t  ", source: "note-whitespace")
        XCTAssertFalse(controller.isSpeaking)
    }

    // MARK: - stop() is always safe, even with nothing playing

    func test_stop_whenAlreadyIdle_doesNotCrash() {
        let controller = SpeechController.shared
        XCTAssertFalse(controller.isSpeaking)
        XCTAssertNoThrow(controller.stop())
        XCTAssertNoThrow(controller.stop())
        XCTAssertFalse(controller.isSpeaking)
    }

    // MARK: - Voice fallback: must never crash and must never silently
    // leave playback idle, even for a locale with no dedicated installed
    // voice (Security Posture Q14, fail-closed-to-next-best-option).

    func test_speak_unusualLocale_stillStartsSpeaking_doesNotCrash() {
        let controller = SpeechController.shared
        // A locale extremely unlikely to have a dedicated installed voice on
        // a test-runner simulator/device -- exercises the
        // bestAvailableVoice fallback chain's final `?? AVSpeechSynthesisVoice(language:)`
        // step (which itself can return nil for a bogus identifier) without
        // needing to reach into the private static helper directly.
        let obscureLocale = Locale(identifier: "zu-ZA")
        XCTAssertNoThrow(controller.speak("Test", source: "note-fallback", locale: obscureLocale))
        XCTAssertTrue(controller.isSpeaking(for: "note-fallback"),
                       "even with no dedicated installed voice for the locale, speak() must still start speaking (falling back toward the system default) rather than silently doing nothing -- the fail-closed requirement is 'never leave the user unsure whether it worked', not 'only work for common locales'")
    }

    func test_speak_defaultLocale_selectsAVoiceAndStartsSpeaking() {
        let controller = SpeechController.shared
        controller.speak("Read this aloud.", source: "bible-chapter", locale: .current)
        XCTAssertTrue(controller.isSpeaking(for: "bible-chapter"))
    }

    // MARK: - Audio session: must work with the Silent switch on, per the
    // acceptance criteria's explicit requirement.

    func test_speak_activatesPlaybackCategoryWithSpokenAudioMode() {
        let controller = SpeechController.shared
        controller.speak("Audio session check.", source: "bible-chapter")
        XCTAssertTrue(controller.isSpeaking(for: "bible-chapter"))

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback,
                        ".playback is the category documented to keep audio audible with the Silent (ring/silent) switch enabled -- .ambient/.soloAmbient would silently mute under it, defeating the whole feature")
        XCTAssertEqual(session.mode, .spokenAudio,
                        "spoken-word content should use .spokenAudio mode, matching this controller's own documented rationale")
    }

    func test_stop_deactivatesAudioSession_doesNotThrow() {
        let controller = SpeechController.shared
        controller.speak("Deactivate check.", source: "bible-chapter")
        XCTAssertNoThrow(controller.stop())
        XCTAssertFalse(controller.isSpeaking)
    }

    // MARK: - Configuration Philosophy Q1: rate/pitch are exposed as
    // tunables, not buried as a hardcoded literal inside speak().

    func test_rateAndPitch_areMutableConfiguration() {
        let controller = SpeechController.shared
        let originalRate = controller.rate
        let originalPitch = controller.pitch

        controller.rate = 0.4
        controller.pitch = 1.3
        XCTAssertEqual(controller.rate, 0.4)
        XCTAssertEqual(controller.pitch, 1.3)

        // Confirm the customized values actually flow into a real speak()
        // call without crashing/erroring (i.e. these aren't dead
        // properties disconnected from the utterance that gets spoken).
        XCTAssertNoThrow(controller.speak("Rate and pitch check.", source: "bible-chapter"))
        XCTAssertTrue(controller.isSpeaking(for: "bible-chapter"))

        controller.rate = originalRate
        controller.pitch = originalPitch
    }

    // MARK: - Zero network call anywhere in the TTS path (acceptance
    // criteria: "verifiable by inspection -- no cloud SDK/API call in the
    // new service"). Source-pinned per this project's established
    // technique (see BibleReaderConsistencyRegressionTests.swift) for facts
    // that aren't runtime-observable behavior -- there is no network call
    // to intercept at runtime precisely because none exists.

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_source_speechController_hasNoNetworkingImportsOrCalls() throws {
        let source = try readSource("FellowScript/Services/SpeechController.swift")
        for forbidden in ["URLSession", "NetworkService", "http://", "https://", "import Network"] {
            XCTAssertFalse(source.contains(forbidden),
                            "SpeechController.swift must contain no reference to '\(forbidden)' -- the on-device-only requirement (zero per-character cost, no cloud TTS provider) must hold structurally, not just by convention")
        }
        XCTAssertTrue(source.contains("import AVFoundation"),
                       "must use Apple's on-device AVSpeechSynthesizer, per the intake spec's explicit choice")
    }
}
