// SpeechController.swift — app-level "read aloud" (dictation/TTS) service
// (task 20260914-dictation-tts, step 2/frontend). Wraps AVSpeechSynthesizer
// for the Bible-chapter and note-body read-aloud buttons on
// BibleReaderView/NoteDetailView.
//
// On-device only, by construction: AVSpeechSynthesizer never makes a network
// call, so this file has zero cloud-TTS surface to audit — satisfies the
// intake spec's "zero per-character cost, zero cloud provider" requirement
// structurally rather than by convention alone.
//
// Singleton, following CallController's own established shape
// (ChimeCallView.swift: `@MainActor final class CallController:
// ObservableObject { static let shared = CallController(); private
// init() {} ... }`, consumed at each call site via `@ObservedObject`) rather
// than AppState's environmentObject-at-the-root style — this is a
// screen-agnostic service two independent screens each reach for on their
// own, not app-wide session state threaded through the whole view tree. One
// shared instance (not one per screen) is what makes starting playback on
// one screen automatically stop another screen's in-flight speech, per
// architecture step 2.
import Foundation
import AVFoundation
import Combine

@MainActor
final class SpeechController: NSObject, ObservableObject {
    static let shared = SpeechController()

    // nil when idle; the caller-supplied `source` identifier while actively
    // reading it. One piece of state answers two different questions each
    // screen's toolbar button needs:
    //   - `isSpeaking`            — is anything currently being read at all
    //   - `isSpeaking(for:)`      — is *this screen's own* content the thing
    //                               being read (drives that screen's own
    //                               idle/speaking icon + color, per design
    //                               step 1's spec)
    // Kept as one Published value (not two) so a screen can't observe a
    // torn/inconsistent combination of "isSpeaking but wrong source" or vice
    // versa mid-update.
    @Published private(set) var activeSource: String? = nil

    var isSpeaking: Bool { activeSource != nil }
    func isSpeaking(for source: String) -> Bool { activeSource == source }

    // Configuration Philosophy Q1 (intake spec preference profile): exposed
    // as tunables rather than buried inline in speak(_:source:) below, even
    // though no user-facing picker UI is in scope for this task.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitch: Float = 1.0

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Toggle helper matching both screens' "toggle, not a separate stop
    /// control" interaction bias: re-tapping the button for the content
    /// that's *currently* being read stops it; tapping a button for
    /// different content (idle, or another screen's speech in flight)
    /// interrupts whatever was playing and starts reading the new text.
    func toggle(_ text: String, source: String, locale: Locale = .current) {
        if isSpeaking(for: source) {
            stop()
        } else {
            speak(text, source: source, locale: locale)
        }
    }

    /// Speaks `text` tagged with `source`, always interrupting any
    /// in-flight speech first — same call path whether that prior speech
    /// came from this same screen or a different one, so no separate
    /// cross-screen coordination is needed beyond this one shared instance.
    /// No-ops (stays idle) on empty/whitespace-only text or a failed audio
    /// session activation, rather than flipping `activeSource` and then
    /// silently producing no sound.
    func speak(_ text: String, source: String, locale: Locale = .current) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activateAudioSession() else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.bestAvailableVoice(for: locale)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        activeSource = source
        synthesizer.speak(utterance)
    }

    /// Stops any in-flight speech regardless of its source — used for the
    /// toggle-to-stop case above, and also called directly by both screens
    /// on `.onDisappear`, on a Bible chapter/book switch mid-speech, and by
    /// FellowScriptApp's scenePhase handling on backgrounding.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if activeSource != nil {
            deactivateAudioSession()
        }
        activeSource = nil
    }

    // MARK: - Voice selection
    //
    // Fail-closed per the preference profile's Security Posture Q14: always
    // resolves to *some* installed voice for the locale (Premium > Enhanced
    // > any installed voice for that language > the system default for the
    // language), never throws, and never leaves speak(_:source:) silently
    // producing no sound just because Enhanced/Premium wasn't downloaded.
    private static func bestAvailableVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let full = locale.identifier
        let short = String(full.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == full || $0.language.hasPrefix(short) }
        return candidates.first(where: { $0.quality == .premium })
            ?? candidates.first(where: { $0.quality == .enhanced })
            ?? candidates.first
            ?? AVSpeechSynthesisVoice(language: full)
    }

    // MARK: - Audio session
    //
    // .playback + .spokenAudio plays through the Silent-switch (spoken
    // content is the entire point of this feature, per the intake spec's
    // acceptance criteria) and, via .duckOthers, behaves reasonably if
    // interrupted by a call or another app's audio instead of fighting it.
    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            return true
        } catch {
            print("SpeechController: failed to activate audio session: \(error.localizedDescription)")
            return false
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    // Natural end of an utterance (as opposed to an explicit stop() call,
    // which already clears activeSource/deactivates the session itself) —
    // mirrors this class's own default MainActor isolation (project-wide
    // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + approachable concurrency,
    // same as MessageAttachments.swift's PHPickerViewControllerDelegate
    // Coordinator), so no extra Task{@MainActor} hop is needed here.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        activeSource = nil
        deactivateAudioSession()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Only ever fires as a result of this class's own stop() calling
        // stopSpeaking(at:) — activeSource/the audio session are already
        // cleared synchronously by stop() itself, so there's nothing left
        // to do here.
    }
}
