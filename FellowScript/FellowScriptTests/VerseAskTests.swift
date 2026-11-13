// VerseAskTests.swift -- task 20261112-verse-ask-ai (step 5).
// Placement rules (mirror of frontend/src/lib/verseAsk.test.js), wire frame,
// warm error copy and the view-model state machine. No network.

import XCTest
@testable import FellowScript

@MainActor
final class VerseAskPlacementTests: XCTestCase {
    private func place(verseTop: CGFloat, keyboardTop: CGFloat? = nil, bar: CGFloat = 0, panelH: CGFloat = 200) -> VerseAskPlacement.Result {
        VerseAskPlacement.place(verseTop: verseTop, viewportTop: 0, viewportBottom: 800,
                                keyboardTop: keyboardTop, bottomObstruction: bar,
                                pillHeight: 44, panelHeight: panelH)
    }

    func testPillSitsJustAboveVerseAndPanelBelow() {
        let r = place(verseTop: 300)
        XCTAssertEqual(r.pillTop, 300 - 6 - 44)
        XCTAssertEqual(r.panelTop, r.pillTop + 44 + 6)
        XCTAssertFalse(r.flipped)
    }

    func testTopVerseClampsPillOnScreen() {
        let r = place(verseTop: 10)
        XCTAssertEqual(r.pillTop, 8)
        XCTAssertGreaterThanOrEqual(r.panelTop, 8 + 44 + 6)
    }

    func testBottomVerseFlipsPanelAboveAndStaysOnScreen() {
        let r = place(verseTop: 760)
        XCTAssertTrue(r.flipped)
        XCTAssertGreaterThanOrEqual(r.panelTop, 8)
        XCTAssertLessThanOrEqual(r.pillTop + 44, 800 - 8)
        XCTAssertLessThanOrEqual(r.panelTop + 200, r.pillTop)
    }

    func testPillStaysAboveKeyboard() {
        let r = place(verseTop: 700, keyboardTop: 500)
        XCTAssertLessThanOrEqual(r.pillTop + 44, 500 - 8)
    }

    func testPillAndPanelStayClearOfTabBar() {
        let bar = FloatingTabBar.reservedHeight(inCallBarVisible: false)
        for top in [300, 600, 700, 760, 799] as [CGFloat] {
            let r = place(verseTop: top, bar: bar)
            XCTAssertLessThanOrEqual(r.pillTop + 44, 800 - bar - 8, "pill under bar at \(top)")
            if r.flipped { XCTAssertLessThanOrEqual(r.panelTop + 200, r.pillTop) }
            else { XCTAssertLessThanOrEqual(r.panelTop + min(200, r.panelMaxHeight), 800 - bar - 8 + 0.5) }
        }
    }

    func testTabBarAndKeyboardUseTheHigherEdge() {
        let bar = FloatingTabBar.reservedHeight(inCallBarVisible: false)
        let r = place(verseTop: 700, keyboardTop: 500, bar: bar)
        XCTAssertLessThanOrEqual(r.pillTop + 44, 500 - 8)
        let r2 = place(verseTop: 700, keyboardTop: 790, bar: bar)
        XCTAssertLessThanOrEqual(r2.pillTop + 44, 800 - bar - 8)
    }

    /// The tab bar is pinned under the keyboard (ignoresSafeArea(.keyboard)), so
    /// with the keyboard up the only bound is the keyboard top: a tall panel
    /// still ends above it and nothing is reserved for a raised bar.
    func testKeyboardUpBoundIsKeyboardTopNotRaisedBar() {
        let bar = FloatingTabBar.reservedHeight(inCallBarVisible: false)
        let r = place(verseTop: 200, keyboardTop: 450, bar: bar, panelH: 900)
        XCTAssertLessThanOrEqual(r.panelTop + min(900, r.panelMaxHeight), 450 - 8 + 0.5)
        XCTAssertLessThanOrEqual(r.pillTop + 44, 450 - 8)
    }

    func testInCallBarReservesMore() {
        XCTAssertGreaterThan(FloatingTabBar.reservedHeight(inCallBarVisible: true),
                             FloatingTabBar.reservedHeight(inCallBarVisible: false))
    }

    func testPanelCappedAt45PercentOfViewport() {
        XCTAssertLessThanOrEqual(place(verseTop: 100).panelMaxHeight, 360)
    }

    func testPureSameInputSameOutput() {
        XCTAssertEqual(place(verseTop: 321), place(verseTop: 321))
    }

    func testColumnCapsWidthAndClampsToMargin() {
        let wide = VerseAskPlacement.column(columnLeft: 24, columnWidth: 900, viewportWidth: 1000)
        XCTAssertEqual(wide.width, 520)
        let narrow = VerseAskPlacement.column(columnLeft: 0, columnWidth: 300, viewportWidth: 390)
        XCTAssertEqual(narrow.left, 16)
        XCTAssertEqual(narrow.width, 300)
    }

    // Close-on-resize rule: only a horizontal change closes; the iPad keyboard
    // shrinks the host height (641 -> 423.5) and must not.
    func testShouldCloseIgnoresHeightOnlyChange() {
        let base = CGRect(x: 0, y: 24, width: 738, height: 641)
        XCTAssertFalse(VerseAskPlacement.shouldClose(baseline: base, current: CGRect(x: 0, y: 24, width: 738, height: 423.5)))
    }

    func testShouldCloseOnWidthChange() {
        let base = CGRect(x: 0, y: 24, width: 738, height: 641)
        XCTAssertTrue(VerseAskPlacement.shouldClose(baseline: base, current: CGRect(x: 0, y: 24, width: 1024, height: 641)))
        XCTAssertTrue(VerseAskPlacement.shouldClose(baseline: base, current: CGRect(x: 0, y: 24, width: 1024, height: 423)))
    }

    func testShouldCloseOnHorizontalMove() {
        let base = CGRect(x: 0, y: 24, width: 738, height: 641)
        XCTAssertTrue(VerseAskPlacement.shouldClose(baseline: base, current: CGRect(x: 120, y: 24, width: 738, height: 641)))
    }

    func testShouldCloseToleratesSubpointJitter() {
        let base = CGRect(x: 0, y: 24, width: 738, height: 641)
        XCTAssertFalse(VerseAskPlacement.shouldClose(baseline: base, current: CGRect(x: 0.4, y: 24, width: 738.5, height: 641)))
    }
}

@MainActor
final class VerseAskViewModelTests: XCTestCase {
    private struct Stub: VerseAskTransport {
        var result: () async throws -> String
        func askVerse(userId: String, question: String, context: VerseAskContext) async throws -> String { try await result() }
    }
    private let ctx = VerseAskContext(reference: "John 3:16", translation: "WEB", text: "For God so loved the world")

    private func vm(_ result: @escaping () async throws -> String, copy: @escaping (String) -> Void = { _ in }) -> VerseAskViewModel {
        VerseAskViewModel(userId: "u1", verseNumber: 16, context: ctx, transport: Stub(result: result), copyToPasteboard: copy)
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }

    func testEmptyQuestionCannotSend() {
        let m = vm { "x" }
        m.draft = "   "
        XCTAssertFalse(m.canSend)
        m.send()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertFalse(m.hasPanel)
    }

    func testSendSuccessShowsAnswer() async {
        let m = vm { "Because of love." }
        m.draft = " Why? "
        m.send()
        XCTAssertEqual(m.phase, .loading(question: "Why?"))
        await settle()
        XCTAssertEqual(m.phase, .answer(question: "Why?", text: "Because of love."))
    }

    func testFailureKeepsQuestionAndRetries() async {
        var calls = 0
        let m = vm { calls += 1; if calls == 1 { throw VerseAskError.network }; return "ok" }
        m.draft = "Why?"
        m.send(); await settle()
        XCTAssertEqual(m.phase, .failed(question: "Why?", message: VerseAskCopy.generic))
        XCTAssertEqual(m.draft, "Why?")
        m.retry(); await settle()
        XCTAssertEqual(m.phase, .answer(question: "Why?", text: "ok"))
    }

    func testCancelIgnoresLateReply() async {
        let m = vm { try? await Task.sleep(nanoseconds: 30_000_000); return "late" }
        m.draft = "Why?"
        m.send()
        m.cancel()
        await settle()
        XCTAssertEqual(m.phase, .loading(question: "Why?"))   // never became an answer
    }

    func testCopyConfirmsAndCopiesPlainText() async {
        var copied: String?
        let m = vm({ "Answer" }, copy: { copied = $0 })
        m.draft = "Why?"; m.send(); await settle()
        m.copyAnswer()
        XCTAssertEqual(copied, "Answer")
        XCTAssertTrue(m.copied)
    }

    func testQuestionLimit() {
        let m = vm { "x" }
        m.draft = String(repeating: "a", count: 501)
        XCTAssertFalse(m.canSend)
        m.draft = String(repeating: "a", count: 450)
        XCTAssertTrue(m.showsCounter)
    }

    func testWarmErrorCopy() {
        XCTAssertEqual(VerseAskCopy.message(for: VerseAskError.offline), VerseAskCopy.offline)
        XCTAssertEqual(VerseAskCopy.message(for: VerseAskError.timeout), VerseAskCopy.generic)
        XCTAssertEqual(VerseAskCopy.message(for: VerseAskError.server("Too many messages")), VerseAskCopy.limit)
        XCTAssertEqual(VerseAskCopy.message(for: VerseAskError.server("Verse text is too long.")), "Verse text is too long.")
    }
}

final class VerseAskFrameTests: XCTestCase {
    func testRequestFrameCarriesVerseContext() throws {
        let ctx = VerseAskContext(reference: "John 3:16", translation: "WEB", text: "For God")
        let json = try VerseAskFrame.request(question: "Why?", context: ctx)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["content"] as? String, "Why?")
        XCTAssertNil(obj["chat_id"])
        let v = try XCTUnwrap(obj["verse_context"] as? [String: String])
        XCTAssertEqual(v, ["reference": "John 3:16", "translation": "WEB", "text": "For God"])
    }

    func testParseAssistantFrame() throws {
        XCTAssertEqual(try VerseAskFrame.parse(#"{"role":"assistant","content":"Hi","ephemeral":true,"chat_id":""}"#), "Hi")
    }

    func testParseThrowsOnErrorEmptyAndGarbage() {
        XCTAssertThrowsError(try VerseAskFrame.parse(#"{"role":"error","content":"Nope"}"#)) {
            XCTAssertEqual($0 as? VerseAskError, .server("Nope"))
        }
        XCTAssertThrowsError(try VerseAskFrame.parse(#"{"role":"assistant","content":"  "}"#))
        XCTAssertThrowsError(try VerseAskFrame.parse("not json"))
    }
}
