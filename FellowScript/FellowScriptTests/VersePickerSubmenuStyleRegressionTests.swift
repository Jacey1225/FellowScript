// VersePickerSubmenuStyleRegressionTests.swift — coverage for task
// 20260921-verse-picker-submenu-style (testing gate, final step of the
// lightweight pipeline).
//
// Proves the acceptance criteria the design gate implemented directly in
// NoteEditorView.swift:
//
//   1. VersePicker is no longer presented via `.sheet` — it's an inline
//      conditional overlay (`showVersePicker` / `openVersePicker()` /
//      `closeVersePicker()` / `versePickerOverlay`), mirroring
//      ChatThreadView.swift's `showSessionsMenu` / `openSessionsMenu()` /
//      `closeSessionsMenu()` / `sessionsMenuOverlay` convention exactly.
//   2. The submenu card uses the Ember Glass glass-surface language
//      (`.regularMaterial`, `topEdgeHighlight`, gold border/capsule accents)
//      in place of the old opaque `Form`/system `Picker` chrome.
//   3. The "+ Verse" trigger opens the submenu via `openVersePicker()`, not
//      a raw `showVersePicker = true` assignment.
//   4. Cancel (xmark button or tap-outside) dismisses without adding;
//      Add commits the exact same `VerseRef` (dedup'd) as before.
//   5. Reduced-motion users get an opacity-only transition, and
//      open/close both route through `withMotionAwareAnimation`.
//
// `VersePicker`/`versePickerOverlay`/`openVersePicker`/`closeVersePicker` are
// either a free-standing view struct or private computed properties/methods
// of NoteEditorView, which (per ChatSessionsSubmenuRegressionTests'
// established precedent) can't be hosted directly in a unit test without a
// live EnvironmentObject/measured-screen-size round trip, so this suite reads
// the real shipped source directly, scoped to the specific region under
// test, rather than driving a live render.

import XCTest
@testable import FellowScript

final class VersePickerSubmenuStyleRegressionTests: XCTestCase {

    private func noteEditorViewSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // repo-relative project root
            .appendingPathComponent("FellowScript/Notes/NoteEditorView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Isolates NoteEditorView's own verse-picker wiring (open/close funcs +
    /// the overlay computed property + the "+ Verse" trigger sits earlier in
    /// `body`, so that's checked separately below), ending before the header
    /// controls section begins.
    private func versePickerWiringSource() throws -> String {
        let source = try noteEditorViewSource()
        guard let start = source.range(of: "// ── Verse picker submenu (task 20260921-verse-picker-submenu-style) ───────"),
              let end = source.range(of: "// ── Header controls (Option C",
                                      range: start.upperBound..<source.endIndex) else {
            XCTFail("expected to find NoteEditorView's verse-picker wiring block in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    /// Isolates the standalone `VersePicker` struct definition itself (the
    /// restyled card/scrim), ending at end-of-file (it's the last thing
    /// declared in this file).
    private func versePickerStructSource() throws -> String {
        let source = try noteEditorViewSource()
        guard let start = source.range(of: "struct VersePicker: View {") else {
            XCTFail("expected to find the VersePicker struct definition in the shipped source")
            return ""
        }
        return String(source[start.lowerBound...])
    }

    /// The body of NoteEditorView's outer ZStack, where the conditional
    /// overlay insertion point lives, and where the "+ Verse" trigger button
    /// sits (earlier, in the verse bar).
    private func editorBodySource() throws -> String {
        let source = try noteEditorViewSource()
        guard let start = source.range(of: "var body: some View {"),
              let end = source.range(of: "// ── Verse picker submenu (task 20260921-verse-picker-submenu-style) ───────") else {
            XCTFail("expected to find NoteEditorView's body in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    // MARK: - 1. No longer a `.sheet` presentation

    func test_source_noteEditorView_noLongerPresentsVersePickerAsSheet() throws {
        let source = try noteEditorViewSource()
        XCTAssertFalse(source.contains(".sheet(isPresented: $showVersePicker)"),
                       "VersePicker must no longer be presented via .sheet -- it's an inline overlay so its transition can use withMotionAwareAnimation")
    }

    func test_source_editorBody_versePickerOverlayRendersConditionallyInZStack() throws {
        let source = try noteEditorViewSource()
        guard let overlayInsertRange = source.range(of: "if showVersePicker {") else {
            XCTFail("expected to find the conditional showVersePicker overlay insertion in the shipped source")
            return
        }
        let overlayBlock = String(source[overlayInsertRange.lowerBound...])
        XCTAssertTrue(overlayBlock.contains("versePickerOverlay"),
                      "the conditional block must actually render versePickerOverlay, mirroring ChatThreadView's `if showSessionsMenu { sessionsMenuOverlay }` convention")
    }

    // MARK: - 2. "+ Verse" trigger opens via openVersePicker(), not a raw flag flip

    func test_source_verseChip_actionOpensVersePicker() throws {
        let body = try editorBodySource()
        XCTAssertTrue(body.contains("Button(action: { openVersePicker() })"),
                      "the '+ Verse' chip must call openVersePicker(), not set showVersePicker = true directly")
        XCTAssertFalse(body.contains("showVersePicker = true }"),
                       "no raw showVersePicker = true assignment should remain as the chip's action")
    }

    // MARK: - 3. Open/close wiring mirrors ChatThreadView's motion-aware pattern

    func test_source_openVersePicker_usesMotionAwareSpringAnimation() throws {
        let wiring = try versePickerWiringSource()
        guard let openRange = wiring.range(of: "private func openVersePicker() {") else {
            XCTFail("expected to find openVersePicker() in the shipped source")
            return
        }
        let openFunc = String(wiring[openRange.lowerBound...])
        XCTAssertTrue(openFunc.contains("withMotionAwareAnimation(.spring(response: 0.35, dampingFraction: 0.82), reduceMotion: reduceMotion)"),
                      "openVersePicker() must use the same spring curve as ChatThreadView's openSessionsMenu()")
        XCTAssertTrue(openFunc.contains("showVersePicker = true"),
                      "openVersePicker() must set showVersePicker = true")
    }

    func test_source_closeVersePicker_usesMotionAwareEaseOutAnimation() throws {
        let wiring = try versePickerWiringSource()
        guard let closeRange = wiring.range(of: "private func closeVersePicker() {") else {
            XCTFail("expected to find closeVersePicker() in the shipped source")
            return
        }
        let closeFunc = String(wiring[closeRange.lowerBound...])
        XCTAssertTrue(closeFunc.contains("withMotionAwareAnimation(.easeOut(duration: 0.18), reduceMotion: reduceMotion)"),
                      "closeVersePicker() must use the same ease-out curve as ChatThreadView's closeSessionsMenu()")
        XCTAssertTrue(closeFunc.contains("showVersePicker = false"),
                      "closeVersePicker() must set showVersePicker = false")
    }

    // MARK: - 4. onSelect/onCancel wiring preserves selection + dedupe behavior

    func test_source_versePickerOverlay_onSelectAppendsDedupedVerseThenCloses() throws {
        let wiring = try versePickerWiringSource()
        guard let overlayRange = wiring.range(of: "private var versePickerOverlay: some View {") else {
            XCTFail("expected to find versePickerOverlay in the shipped source")
            return
        }
        let overlay = String(wiring[overlayRange.lowerBound...])
        XCTAssertTrue(overlay.contains("let ref = VerseRef(book: book, chapter: chapter, verse: verse)"),
                      "onSelect must construct the same VerseRef as before")
        XCTAssertTrue(overlay.contains("if !verseList.contains(where: { $0.book == book && $0.chapter == chapter && $0.verse == verse }) {"),
                      "onSelect must preserve the existing dedupe check before appending")
        XCTAssertTrue(overlay.contains("verseList.append(ref)"),
                      "onSelect must append the deduped VerseRef to verseList, same storage as before")
        XCTAssertTrue(overlay.contains("closeVersePicker()"),
                      "onSelect must close the submenu after appending")
    }

    func test_source_versePickerOverlay_onCancelJustCloses() throws {
        let wiring = try versePickerWiringSource()
        guard let overlayRange = wiring.range(of: "private var versePickerOverlay: some View {") else {
            XCTFail("expected to find versePickerOverlay in the shipped source")
            return
        }
        let overlay = String(wiring[overlayRange.lowerBound...])
        guard let onCancelRange = overlay.range(of: "onCancel: { closeVersePicker() }") else {
            XCTFail("expected onCancel to be wired to closeVersePicker() with no other side effect")
            return
        }
        _ = onCancelRange
        XCTAssertTrue(overlay.contains("onCancel: { closeVersePicker() }"),
                      "onCancel must dismiss without adding -- wired to closeVersePicker() only, no verseList mutation")
    }

    // MARK: - 5. VersePicker struct: Ember Glass card treatment

    func test_source_versePicker_scrimIsColorClearWithTapToDismiss() throws {
        let picker = try versePickerStructSource()
        XCTAssertTrue(picker.contains("Color.clear"),
                      "the scrim must be Color.clear, matching ChatThreadView's current (post task 20260920-sessions-menu-background-blur) sessionsMenuOverlay backdrop")
        XCTAssertFalse(picker.contains(".fill(.ultraThinMaterial)"),
                       "no full-bleed .ultraThinMaterial fill should back the scrim -- blur lives only on the card")
        XCTAssertTrue(picker.contains("onTapGesture { onCancel() }"),
                      "tapping the scrim outside the card must dismiss without adding")
        XCTAssertTrue(picker.contains(#".accessibilityLabel("Close verse picker")"#),
                      "the tap-outside-to-dismiss scrim must be accessible, not just a silent hit target")
    }

    func test_source_versePickerCard_usesRegularMaterialGlassSurfaceWithTopEdgeHighlight() throws {
        let picker = try versePickerStructSource()
        XCTAssertTrue(picker.contains(".background(.regularMaterial)"),
                      "the card must use the app's glass-surface material, matching the Ember Glass language")
        XCTAssertTrue(picker.contains("topEdgeHighlight("),
                      "the card must use the app's existing topEdgeHighlight elevation convention")
        XCTAssertTrue(picker.contains(".stroke(Theme.borderGoldDim, lineWidth: 1)"),
                      "the card must have a gold-bordered edge, matching sessionsMenuCard's treatment")
    }

    func test_source_versePickerCard_addActionIsGoldGradientCapsule() throws {
        let picker = try versePickerStructSource()
        XCTAssertTrue(picker.contains(".background(Theme.goldGradient)"),
                      "the Add action must use the app's gold gradient, matching sessionsMenuCard's 'Schedule new session' button")
        XCTAssertTrue(picker.contains(".clipShape(Capsule())"),
                      "the Add action must be capsule-shaped")
        XCTAssertTrue(picker.contains("onSelect(selectedBook, selectedChapter, selectedVerse)"),
                      "the Add button must call onSelect with the current selection")
    }

    func test_source_versePickerCard_noLongerUsesOpaqueFormOrNavigationStack() throws {
        let picker = try versePickerStructSource()
        XCTAssertFalse(picker.contains("Form {"),
                       "the old opaque system Form must be gone")
        XCTAssertFalse(picker.contains("NavigationStack {"),
                       "VersePicker itself no longer needs its own NavigationStack -- it's an inline overlay now, not a sheet")
    }

    func test_source_versePickerCard_keepsThreeWheelPickersForSelection() throws {
        // Per the intake spec's own open question, the design gate kept the
        // three system wheel Pickers as-is (lowest-risk) rather than
        // replacing them with custom rows -- selection logic itself must be
        // untouched.
        let picker = try versePickerStructSource()
        XCTAssertTrue(picker.contains(#"Picker("Book", selection: $selectedBook)"#))
        XCTAssertTrue(picker.contains(#"Picker("Chapter", selection: $selectedChapter)"#))
        XCTAssertTrue(picker.contains(#"Picker("Verse", selection: $selectedVerse)"#))
        XCTAssertTrue(picker.contains(".pickerStyle(.wheel)"))
        XCTAssertTrue(picker.contains("BibleData.bookNames"),
                      "book selection must still be driven by the existing BibleData.bookNames source")
        XCTAssertTrue(picker.contains("BibleData.sampleChapterCounts[selectedBook]"),
                      "chapter range must still be driven by the existing per-book chapter-count lookup")
    }

    // MARK: - Reduced motion

    func test_source_versePicker_hasReducedMotionFallback() throws {
        let picker = try versePickerStructSource()
        XCTAssertTrue(picker.contains("reduceMotion") && picker.contains("? .opacity"),
                      "the submenu's open/close transition must degrade to a plain opacity swap under reduced motion")
    }

    func test_source_versePicker_initializerTakesReduceMotionExplicitly() throws {
        // VersePicker is a free-standing struct (no longer presented via
        // .sheet, so it can't read @Environment(\.dismiss) as a real
        // presentation) -- confirms reduceMotion is threaded in from the
        // parent's own @Environment(\.accessibilityReduceMotion) rather than
        // read locally, which would silently diverge from
        // NoteEditorView.reduceMotion if the two were ever driven
        // independently.
        let picker = try versePickerStructSource()
        XCTAssertTrue(picker.contains("let reduceMotion: Bool"),
                      "VersePicker must take reduceMotion as an explicit stored property, threaded from its parent")
        let wiring = try versePickerWiringSource()
        XCTAssertTrue(wiring.contains("reduceMotion: reduceMotion"),
                      "versePickerOverlay must pass NoteEditorView's own reduceMotion through to VersePicker")
    }
}
