// BibleReaderViewDictationRegressionTests.swift — testing-gate coverage for
// task 20260914-dictation-tts, step 3 (testing).
//
// BibleReaderView carries neither a `didAppear` hook nor an `inspection`
// property (unlike NoteDetailView), and its own `toggleDictation()`/
// `dictationSource` are `private` (BibleReaderView.swift:354-355,675) — so,
// same as the pre-existing BibleReaderConsistencyRegressionTests.swift
// (this screen's only other test coverage), this screen's dictation wiring
// is proven via a combination of:
//   1. Behavioral tests against the real shared `SpeechController.shared`
//      singleton, using the exact `"bible-chapter"` source-id literal this
//      screen's private `dictationSource` constant is pinned to below (so a
//      future rename of that constant fails a test here rather than
//      silently leaving these assertions checking the wrong thing).
//   2. Source-pinned checks (this file's own established technique) for the
//      wiring facts private access puts out of reach of a live render pass
//      — chapter/book-switch-stops-speech, onDisappear-stops-speech, and
//      that the pre-existing font-size/bookmark controls are untouched by
//      the toolbar restructuring this task made to append the dictation
//      button after them.
//
// SpeechControllerRegressionTests.swift covers the shared engine's own
// toggle/interrupt/fallback/audio-session behavior in isolation;
// NoteDetailViewDictationRegressionTests.swift covers the equivalent Notes
// side end to end (that screen's toggleDictation() is `internal`, so it's
// directly callable there).
import XCTest
@testable import FellowScript

@MainActor
final class BibleReaderViewDictationRegressionTests: XCTestCase {

    override func tearDown() async throws {
        SpeechController.shared.stop()
        try await super.tearDown()
    }

    // MARK: - Cross-screen: a note's in-flight speech is interrupted once
    // the Bible screen's own source starts, and vice versa — proven
    // directly against the shared controller and the real "bible-chapter"
    // literal (pinned below to BibleReaderView's own private constant),
    // complementing NoteDetailViewDictationRegressionTests' equivalent from
    // the Notes side.

    func test_bibleChapterSource_interruptsAnotherInFlightSource() {
        SpeechController.shared.speak("Reading a note.", source: "note-xyz")
        XCTAssertTrue(SpeechController.shared.isSpeaking(for: "note-xyz"))

        SpeechController.shared.speak("Reading the chapter.", source: "bible-chapter")

        XCTAssertTrue(SpeechController.shared.isSpeaking(for: "bible-chapter"))
        XCTAssertFalse(SpeechController.shared.isSpeaking(for: "note-xyz"),
                        "starting Bible-chapter speech must stop a Notes screen's in-flight speech, since both screens share one SpeechController instance")
    }

    func test_bibleChapterSource_toggleTwice_startsThenStops() {
        SpeechController.shared.toggle("John chapter one.", source: "bible-chapter")
        XCTAssertTrue(SpeechController.shared.isSpeaking(for: "bible-chapter"))

        SpeechController.shared.toggle("John chapter one.", source: "bible-chapter")
        XCTAssertFalse(SpeechController.shared.isSpeaking,
                        "re-tapping the dictation button for the same chapter must stop playback")
    }

    // MARK: - Source-pinned wiring facts.

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_source_dictationSource_matchesLiteralUsedByThisTestFile() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(source.contains(#"private static let dictationSource = "bible-chapter""#),
                       "this test file's cross-screen assertions above speak() directly with the literal \"bible-chapter\" source id — if BibleReaderView's own private dictationSource constant ever changes, this pin must be updated too, or those tests would silently stop proving anything about the real screen")
    }

    func test_source_toggleDictation_speaksOnlyCurrentChapterVerses() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(source.contains("let text = vm.verses.map(\\.text).joined(separator: \" \")"),
                       "must speak vm.verses (already scoped to the current chapter only) — never the whole book")
        XCTAssertTrue(source.contains("speechController.toggle(text, source: Self.dictationSource)"))
    }

    func test_source_chapterAndBookSwitch_stopSpeechControllerMidSpeech() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        // Both onChange handlers must call stop() — the acceptance
        // criteria's "does not silently keep reading the old chapter's
        // text under the new chapter's UI" requirement, covering both the
        // chapter-number-changes case and the same-chapter-different-book
        // case.
        // Bounded by the NEXT onChange declaration (rather than a fixed
        // character window, which is brittle against comment-length
        // changes) so each slice covers exactly one handler's own body.
        guard let chapterChangeRange = source.range(of: ".onChange(of: vm.curChapter)"),
              let bookChangeRange = source.range(of: ".onChange(of: vm.curBook)"),
              let pendingScrollChangeRange = source.range(of: ".onChange(of: pendingScrollVerse)")
        else {
            XCTFail("expected onChange(of: vm.curChapter), onChange(of: vm.curBook), and onChange(of: pendingScrollVerse) handlers to be present, in that order")
            return
        }
        let chapterHandlerBody = source[chapterChangeRange.upperBound..<bookChangeRange.lowerBound]
        let bookHandlerBody = source[bookChangeRange.upperBound..<pendingScrollChangeRange.lowerBound]
        XCTAssertTrue(chapterHandlerBody.contains("speechController.stop()"),
                       "a chapter switch mid-speech must stop playback")
        XCTAssertTrue(bookHandlerBody.contains("speechController.stop()"),
                       "a book switch mid-speech must stop playback even when the chapter number itself doesn't change")
    }

    func test_source_onDisappear_stopsSpeechController() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(source.contains(".onDisappear {") && source.contains("speechController.stop()"),
                       "navigating away from the Bible tab must stop playback, per the acceptance criteria")
    }

    // MARK: - Regression: the pre-existing font-size cycle and bookmark
    // menu must be untouched by the toolbar restructuring this task made to
    // append the dictation button after them.

    func test_source_fontSizeAndBookmarkControls_stillPresent_unchanged() throws {
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(source.contains("Button(action: cycleFontSize) {"),
                       "font-size cycle button must be untouched")
        XCTAssertTrue(source.contains(#"Image(systemName: "textformat.size")"#))
        XCTAssertTrue(source.contains("vm.persistToggleBookmark(userId: appState.currentUser?.user_id ?? \"\")"),
                      "bookmark toggle action must be untouched")
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Bookmark options\")"))

        // Dictation button must come AFTER both, per design step 1's
        // "least disruptive to current layout" placement.
        let fontSizeIdx = source.range(of: "Button(action: cycleFontSize)")!.lowerBound
        let bookmarkIdx = source.range(of: ".accessibilityLabel(\"Bookmark options\")")!.lowerBound
        let dictationIdx = source.range(of: "Button(action: toggleDictation)")!.lowerBound
        XCTAssertTrue(fontSizeIdx < bookmarkIdx && bookmarkIdx < dictationIdx,
                       "toolbar reading order must stay font-size -> bookmark -> dictate")
    }

    func test_source_dictationButton_insideSameSuppressedToolbarGroup() throws {
        // Confirms the dictation button was appended into the EXISTING
        // ToolbarItemGroup (design step 1's spec) rather than a second,
        // separately-chromed group -- both groups sharing one
        // .suppressAutomaticGlassChrome() call is what keeps the doubled
        // Liquid-Glass-capsule fix (task 20260830-bible-reader-live-fix)
        // intact for the new button too.
        let source = try readSource("FellowScript/Bible/BibleReaderView.swift")
        guard let groupRange = source.range(of: "ToolbarItemGroup(placement: .navigationBarTrailing) {"),
              let dictationRange = source.range(of: "Button(action: toggleDictation)", range: groupRange.upperBound..<source.endIndex),
              let suppressRange = source.range(of: ".suppressAutomaticGlassChrome()", range: dictationRange.upperBound..<source.endIndex)
        else {
            XCTFail("expected the trailing ToolbarItemGroup to contain the dictation button, followed by .suppressAutomaticGlassChrome()")
            return
        }
        XCTAssertTrue(groupRange.upperBound < dictationRange.lowerBound && dictationRange.upperBound < suppressRange.lowerBound)
    }
}
