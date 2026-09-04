// InteractionPolishSharedMechanismsTests.swift — testing-gate coverage for
// task 20260831-interaction-polish-conventions, step 2.
//
// The frontend gate (step 1) built three shared, reusable app-wide
// mechanisms in Theme/Theme.swift rather than per-screen bespoke logic:
//   1. Pull-to-refresh — no new shared modifier needed (native `.refreshable`
//      wired directly to each screen's existing reload method); covered by
//      PullToRefreshRegressionTests.swift, not this file.
//   2. `View.dismissesKeyboardOnScrollAndTap()` — scroll-interactive keyboard
//      dismissal + a tap-to-resign-first-responder gesture, applied at 18+
//      call sites across 12+ screens/sheets. (Task
//      20260904-notes-keyboard-dismiss-fix later replaced the tap side with
//      a UIKit-backed `UIGestureRecognizerRepresentable` so it can exclude
//      taps landing on an active text-input control — see
//      NotesKeyboardDismissFixRegressionTests.swift.)
//   3. `TapOutsideDismissCatcher` — an invisible full-screen tap target for
//      this app's one custom ZStack-based overlay (BibleReaderView's
//      BibleNavDropdown).
//
// This file proves:
//   A. TapOutsideDismissCatcher actually dismisses on tap when live-rendered
//      (ViewInspector direct-hosting, matching this project's
//      ChipToggleTests precedent) and stays VoiceOver-hidden.
//   B. The shared modifier's own exact implementation (Theme.swift) —
//      source-pinned, since a SwiftUI environment modifier + simultaneous
//      gesture can't be cheaply asserted on by ViewInspector for an
//      arbitrary host view (see AgentChatBubbleRemovalRegressionTests'
//      documented "source-text pinning for facts ViewInspector can't cheaply
//      assert on" precedent).
//   C. Representative in-scope screens across every domain (Auth, Notes,
//      Chat, Account) actually call the shared modifier — proving "one
//      consistent, shared mechanism... not duplicated per-screen" rather
//      than three divergent one-offs.
//   D. Regression coverage: NoteEditorView's prior one-off
//      `.scrollDismissesKeyboard(.interactively)` was reconciled away (no
//      longer present as its own bespoke call), and BibleReaderView's
//      TapOutsideDismissCatcher is layered strictly behind BibleNavDropdown
//      in z-order and doesn't disturb the screen's pre-existing
//      chapter-change drag gesture or Reduce Motion handling.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - A. TapOutsideDismissCatcher — live render

final class TapOutsideDismissCatcherRenderTests: XCTestCase {

    func test_tap_invokesOnDismiss() throws {
        var dismissed = false
        let sut = TapOutsideDismissCatcher { dismissed = true }

        try sut.inspect().find(ViewType.Color.self).callOnTapGesture()

        XCTAssertTrue(dismissed, "tapping anywhere on the catcher must invoke its onDismiss closure")
    }

    func test_isHiddenFromAccessibility() throws {
        // The catcher is a purely visual/gesture plumbing layer with no
        // content of its own -- VoiceOver users must not land on it.
        let sut = TapOutsideDismissCatcher {}
        XCTAssertTrue(try sut.inspect().find(ViewType.Color.self).accessibilityHidden(),
                      "the invisible tap-catcher must be hidden from accessibility, not read as an unlabeled element")
    }
}

// MARK: - B. Shared modifier — source-pinned exact implementation

final class SharedInteractionModifierSourceTests: XCTestCase {

    private func readThemeSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()   // FellowScriptTests/
            .deletingLastPathComponent()   // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Theme/Theme.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_dismissesKeyboardOnScrollAndTap_usesInteractiveScrollDismissal() throws {
        let source = try readThemeSource()
        guard let range = source.range(of: "func dismissesKeyboardOnScrollAndTap() -> some View {") else {
            XCTFail("shared keyboard-dismiss modifier not found in Theme.swift")
            return
        }
        let body = String(source[range.upperBound...].prefix(600))
        XCTAssertTrue(body.contains(".scrollDismissesKeyboard(.interactively)"),
                      "the shared modifier must use interactive scroll-dismiss (the NoteEditorView precedent this task made the app-wide default), not .immediately or .never")
    }

    func test_dismissesKeyboardOnScrollAndTap_usesSimultaneousGesture_notPlainOnTapGesture() throws {
        // Updated for task 20260904-notes-keyboard-dismiss-fix: a plain
        // `.onTapGesture` would swallow taps meant for buttons/rows
        // underneath it, and SwiftUI's own `TapGesture` (even wrapped in
        // `.simultaneousGesture`) has no visibility into which UIKit view a
        // tap actually landed on -- which is exactly what let it dismiss the
        // keyboard when a tap landed inside an already-focused
        // UITextField/UITextView meant only to reposition the cursor (the
        // Notes bug this task fixed). The modifier now wraps a real
        // UITapGestureRecognizer via `UIGestureRecognizerRepresentable`
        // (`.gesture(KeyboardResignTapGesture())`), whose delegate
        // reproduces the old simultaneousGesture guarantee explicitly via
        // `cancelsTouchesInView = false` +
        // `shouldRecognizeSimultaneouslyWith` returning true, while adding a
        // `shouldReceive touch:` check that excludes text-input controls.
        let source = try readThemeSource()
        guard let range = source.range(of: "func dismissesKeyboardOnScrollAndTap() -> some View {") else {
            XCTFail("shared keyboard-dismiss modifier not found in Theme.swift")
            return
        }
        let body = String(source[range.upperBound...].prefix(600))
        XCTAssertTrue(body.contains(".gesture(KeyboardResignTapGesture())"),
                      "must wrap the UIKit-backed KeyboardResignTapGesture via .gesture(), not a plain SwiftUI TapGesture")
        XCTAssertFalse(body.contains(".onTapGesture {"),
                       "must not use a plain, gesture-stealing .onTapGesture for the dismiss tap")

        guard let structRange = source.range(of: "struct KeyboardResignTapGesture: UIGestureRecognizerRepresentable {") else {
            XCTFail("KeyboardResignTapGesture not found in Theme.swift")
            return
        }
        let structBody = String(source[structRange.upperBound...].prefix(2000))
        XCTAssertTrue(structBody.contains("resignFirstResponder"),
                      "the tap must resign first responder to actually dismiss the keyboard")
        XCTAssertTrue(structBody.contains("cancelsTouchesInView = false"),
                      "must not swallow touches meant for underlying controls (the prior simultaneousGesture guarantee)")
        XCTAssertTrue(structBody.contains("shouldRecognizeSimultaneouslyWith"),
                      "must explicitly allow simultaneous recognition with other gesture recognizers underneath it")
        XCTAssertTrue(structBody.contains("shouldReceive touch"),
                      "must gate recognition on which UIKit view the touch actually landed on")
    }

    func test_tapOutsideDismissCatcher_isHitTestable_nearZeroOpacity_notFullyClear() throws {
        // Color.clear is documented (in this same source file) as NOT
        // hit-testable in SwiftUI -- pins the near-zero-but-nonzero opacity
        // workaround so a future "simplify to .clear" edit doesn't silently
        // regress the catcher back into an untappable no-op.
        let source = try readThemeSource()
        XCTAssertTrue(source.contains("Color.black.opacity(0.0001)"),
                      "TapOutsideDismissCatcher must use a near-zero-but-nonzero opacity fill, not Color.clear, to stay tappable")
        XCTAssertFalse(source.contains("Color.clear\n            .ignoresSafeArea()\n            .contentShape(Rectangle())\n            .onTapGesture"),
                       "must not regress to a fully transparent (non-hit-testable) catcher")
    }
}

// MARK: - C. Representative screens actually apply the shared modifier

final class RepresentativeScreenKeyboardDismissSourceTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func assertUsesSharedModifier(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try readSource(relativePath)
        XCTAssertTrue(source.contains(".dismissesKeyboardOnScrollAndTap()"),
                      "\(relativePath) must apply the shared keyboard-dismiss convention, not a bespoke one-off",
                      file: file, line: line)
    }

    // One representative screen per domain named in the spec's candidate list.
    func test_authView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Auth/AuthView.swift") }
    func test_completeProfileView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Auth/CompleteProfileView.swift") }
    func test_mfaVerifyView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Auth/MfaVerifyView.swift") }
    func test_forgotPasswordView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Auth/ForgotPasswordView.swift") }
    func test_noteEditorView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Notes/NoteEditorView.swift") }
    func test_notesListView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Notes/NotesListView.swift") }
    func test_chatRootView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Chat/ChatRootView.swift") }
    func test_chatThreadView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Chat/ChatThreadView.swift") }
    func test_agentChatView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Chat/AgentChatView.swift") }
    func test_reportUserSheet_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Chat/ReportUserSheet.swift") }
    func test_accountView_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Account/AccountView.swift") }
    func test_eventSetupSheet_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Account/EventSetupSheet.swift") }
    func test_mfaSheets_usesSharedModifier() throws { try assertUsesSharedModifier("FellowScript/Account/MfaSheets.swift") }

    // D. Regression: NoteEditorView's prior one-off must be reconciled away,
    // not left as a second, divergent keyboard-dismiss mechanism alongside
    // the new shared one.
    func test_noteEditorView_noLongerHasItsOwnBespokeScrollDismissesKeyboardCall() throws {
        // Only counts an actual modifier CALL (a source line that, once
        // trimmed, starts with the modifier itself) -- the file's own
        // explanatory comment mentioning the old one-off by name (documenting
        // *why* it was reconciled away) must not itself trip this check.
        let source = try readSource("FellowScript/Notes/NoteEditorView.swift")
        let hasBespokeCallSite = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0.hasPrefix(".scrollDismissesKeyboard(") }
        XCTAssertFalse(hasBespokeCallSite,
                       "NoteEditorView must no longer carry its own one-off .scrollDismissesKeyboard call site -- that behavior must come exclusively from the shared .dismissesKeyboardOnScrollAndTap() modifier now")
        XCTAssertTrue(source.contains(".dismissesKeyboardOnScrollAndTap()"),
                      "NoteEditorView must be reconciled onto the shared modifier")
    }
}

// MARK: - D. BibleReaderView tap-outside-dismiss: wiring + no regressions

final class BibleReaderViewTapOutsideDismissRegressionTests: XCTestCase {

    private func readSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Bible/BibleReaderView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_tapOutsideDismissCatcher_sitsBehindBibleNavDropdown_inZOrder() throws {
        let source = try readSource()
        guard let catcherRange = source.range(of: "TapOutsideDismissCatcher {"),
              let dropdownRange = source.range(of: "BibleNavDropdown(", range: catcherRange.upperBound..<source.endIndex) else {
            XCTFail("could not locate both TapOutsideDismissCatcher and BibleNavDropdown in the real source")
            return
        }
        // The catcher must appear first (lower/behind in this ZStack), and
        // its own zIndex literal must be lower than the dropdown's, so a tap
        // on the dropdown's own opaque/blurred content lands on the
        // dropdown, not the catcher underneath it.
        let between = String(source[catcherRange.upperBound..<dropdownRange.lowerBound])
        XCTAssertTrue(between.contains(".zIndex(9)"), "TapOutsideDismissCatcher must carry the lower zIndex so it sits behind the panel")

        guard let dropdownZIndexRange = source.range(of: ".zIndex(", range: dropdownRange.upperBound..<source.endIndex) else {
            XCTFail("could not find BibleNavDropdown's own zIndex")
            return
        }
        let afterDropdownZIndex = String(source[dropdownZIndexRange.upperBound...].prefix(3))
        XCTAssertTrue(afterDropdownZIndex.hasPrefix("10)"),
                      "BibleNavDropdown must carry a higher zIndex (10) than the catcher (9) so panel taps are never swallowed by the catcher underneath")
    }

    func test_tapOutsideDismissCatcher_setsShowNavSheetFalse() throws {
        let source = try readSource()
        guard let range = source.range(of: "TapOutsideDismissCatcher {") else {
            XCTFail("TapOutsideDismissCatcher call site not found")
            return
        }
        let body = String(source[range.upperBound...].prefix(80))
        XCTAssertTrue(body.contains("showNavSheet = false"),
                      "tapping outside the nav dropdown must close it by setting showNavSheet false")
    }

    func test_existingChapterChangeDragGesture_isUnchanged() throws {
        // Regression guard: this task added a new gesture (tap-outside) to
        // the screen but must not have disturbed the pre-existing
        // horizontal-swipe chapter-change DragGesture.
        let source = try readSource()
        XCTAssertTrue(source.contains("DragGesture(minimumDistance: 30, coordinateSpace: .local)"),
                      "the existing chapter-change drag gesture's threshold must be unchanged")
        XCTAssertTrue(source.contains("guard !showNavSheet else { return }"),
                      "the drag gesture must still be suppressed while the nav panel is open, unaffected by the new tap-outside mechanism")
        XCTAssertTrue(source.contains("abs(dx) > abs(dy), abs(dx) > 50"),
                      "the existing horizontal-vs-vertical / 50pt drag threshold must be unchanged")
    }

    func test_navPanelAnimation_respectsReduceMotion() throws {
        // Preference profile Q14.3: any animation this task's new
        // interaction (tap-outside-close) drives must honor system Reduce
        // Motion.
        let source = try readSource()
        XCTAssertTrue(source.contains(".animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: showNavSheet)"),
                      "the nav panel's open/close animation (now also triggered by tap-outside-dismiss) must respect Reduce Motion")
    }
}
