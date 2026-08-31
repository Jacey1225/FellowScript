// EmberGlassFidelityPassRegressionTests.swift — coverage for task
// 20260827-ember-glass-fidelity-pass, step 3 (testing).
//
// Proves each real defect this fidelity pass fixed, against the actual
// shipped source, so a regression of any one of them fails here rather than
// only being caught by a future manual screenshot comparison:
//
//   1. `SessionBanner`'s Join/Details buttons now render on their own
//      full-width row below the title/time row (design decision 1), and the
//      mechanism that stops "Join"'s label from text-wrapping at realistic
//      session-title lengths (`.fixedSize()` + the row no longer sharing
//      space with the title) is actually present, not just structurally
//      "probably fine".
//   2. The plain, unlabeled hairline divider between two consecutive
//      same-day message groups is gone (design decision 2) — replaced with
//      a pure spacing gap — while the day-boundary hairlines it was reversed
//      *against* (`DayDividerRow`) are untouched.
//   3. `ChipToggle`'s two Session-Options chips ("Repeat weekly" /
//      "Summarize with agent") render single-line and equal-height via
//      `.lineLimit(1)` + `.minimumScaleFactor(0.75)`.
//   4. `FSSession.formattedStart` / `FSMessage.formattedTime` correctly
//      parse ISO8601 timestamps that omit fractional seconds instead of
//      falling back to the raw string / an empty label, mirroring
//      `MessageDisplayGroup.parseTimestamp`'s existing dual-format retry.
//
// Item 5 (the note-resume "Continue" island's chamfer) needs no new test —
// intake confirmed it is not a defect, and `NoteResumeCardContinueIslandTests`
// already covers that geometry from a separate, completed task. Item 6
// (`DateTimeTile`'s native picker chrome) is an accepted no-code-change
// exception per design decision 3 — nothing to regression-test.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - 1. SessionBanner row restructure (design decision 1)

@MainActor
final class SessionBannerRowRestructureRegressionTests: XCTestCase {

    private func makeSession(title: String = "Evening Study") -> FSSession {
        FSSession(
            id: "session-1",
            title: title,
            time_start: "2026-08-27T18:00:00.000Z",
            verses: ["John 3:16"],
            prompts: ["What stood out to you?"],
            recurring: true,
            creator_id: ""
        )
    }

    private func makeInspectable(title: String = "Evening Study") -> some View {
        let appState = AppState(service: MockDataService.shared)
        return SessionBanner(session: makeSession(title: title)).environmentObject(appState)
    }

    // MARK: Structural separation — title/time row vs. button row

    func test_sessionBanner_rendersTwoDistinctHStacks_titleRowAndButtonRowAreSeparate() throws {
        // Before design decision 1, SessionBanner.body was a single HStack
        // containing the icon, title/time, Spacer, AND the Join/Details
        // HStack all sharing one row — that shared row is exactly what
        // starved the button row for width. After the restructure there
        // must be (at least) two sibling HStacks: one for the title row,
        // one for the button row.
        let sut = makeInspectable()
        let hStacks = try sut.inspect().findAll(ViewType.HStack.self)
        XCTAssertGreaterThanOrEqual(
            hStacks.count, 2,
            "SessionBanner must render the title/time row and the Join/Details row as separate HStacks, not one shared row"
        )
    }

    func test_sessionBanner_titleRow_noLongerContainsTheButtons() throws {
        // The specific regression this guards: the title's own HStack must
        // not also contain "Join" or "Details" — if it did, they'd be back
        // to competing for the same row's width.
        let sut = makeInspectable()
        let hStacks = try sut.inspect().findAll(ViewType.HStack.self)
        let titleRow = try XCTUnwrap(
            hStacks.first { hStack in
                (try? hStack.find(text: "Evening Study")) != nil
            },
            "expected to find the HStack containing the session title"
        )
        XCTAssertThrowsError(
            try titleRow.find(button: "Join"),
            "the title row must not also contain the Join button after the row restructure"
        ) { _ in }
        XCTAssertThrowsError(
            try titleRow.find(button: "Details"),
            "the title row must not also contain the Details button after the row restructure"
        ) { _ in }
    }

    // MARK: Join-label wrap-prevention mechanism (structural, not a real layout pass)

    func test_sessionBanner_joinLabel_hasFixedSize_soItCannotBeCompressedIntoAWrap() throws {
        let sut = makeInspectable()
        let joinText = try sut.inspect().find(ViewType.Text.self, where: { try $0.string() == "Join" })
        XCTAssertNoThrow(
            try joinText.fixedSize(),
            "'Join' must keep .fixedSize() so it renders at its natural single-line size and cannot be squeezed into a 'Jo'/'in' wrap the way it did in the pre-restructure single-HStack layout"
        )
    }

    func test_sessionBanner_joinAndDetailsButtons_haveFullWidthFrame_matchingRender3Proportions() throws {
        // The mechanism that makes the two buttons "span most of the card's
        // content width" (render-3-session-summary.png) rather than hugging
        // a small trailing cluster: each button's label carries
        // .frame(maxWidth: .infinity).
        let sut = makeInspectable()

        let joinButton = try sut.inspect().find(button: "Join")
        let joinFrame = try joinButton.labelView().flexFrame()
        XCTAssertTrue(joinFrame.maxWidth.isInfinite,
                      "Join's label must use .frame(maxWidth: .infinity) so it shares the full-width button row roughly evenly with Details")

        let detailsButton = try sut.inspect().find(button: "Details")
        let detailsFrame = try detailsButton.labelView().flexFrame()
        XCTAssertTrue(detailsFrame.maxWidth.isInfinite,
                      "Details' label must use .frame(maxWidth: .infinity) so it shares the full-width button row roughly evenly with Join")
    }

    func test_sessionBanner_realisticLongTitle_joinLabelStaysExactlyTheStringJoin() throws {
        // "Wednesday Night Study" is the exact title the intake spec found
        // triggering the "Jo"/"in" wrap under the old single-HStack layout.
        // The label's own string content must still render as the literal,
        // un-truncated "Join" — combined with the .fixedSize() mechanism
        // test above, this pins both "what renders" and "why it can't wrap".
        let sut = makeInspectable(title: "Wednesday Night Study")
        XCTAssertNoThrow(try sut.inspect().find(text: "Wednesday Night Study"))
        let joinText = try sut.inspect().find(ViewType.Text.self, where: { try $0.string() == "Join" })
        XCTAssertEqual(try joinText.string(), "Join")
        XCTAssertNoThrow(try joinText.fixedSize())
    }

    func test_sessionBanner_detailsButtonStillOpensSessionDetailSheet_afterRestructure() throws {
        // The row restructure must not have broken the pre-existing
        // Details -> SessionDetailSheet affordance covered by
        // EmberGlassChatRegressionTests — re-asserted here alongside the new
        // layout coverage for this same view.
        let sut = makeInspectable()
        try sut.inspect().find(button: "Details").tap()
    }
}

// MARK: - 2. Plain sender-group hairline divider removal (design decision 2)
//
// The divider treatment is inline render logic in ChatThreadView's message-
// list ForEach, not a separately-instantiable component, and the enclosing
// ChatThreadView can't be hosted in a unit test without a live WebSocket/
// network round trip (no test in this target does — see
// SessionBannerAndDetailSheetTests/MessageDisplayGroupTests for the
// project's existing component-level-only convention here). Consistent with
// this codebase's own established technique for pinning an otherwise-
// ViewInspector-unreachable implementation detail against the real shipped
// source (see NoteResumeCardContinueIslandTests.
// test_source_reduceMotionPressSubstitution_dropsScaleAndUsesOpacityDipInstead
// and LoadingScreenAssetTransparencyTests), this reads the real
// ChatThreadView.swift/MessageGroupRow.swift source directly.

final class SenderGroupDividerRemovalRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_source_messageListForEach_usesClearSpacer_notARenderedLine_betweenNonDayBoundaryGroups() throws {
        let source = try readSource("FellowScript/Chat/ChatThreadView.swift")
        XCTAssertTrue(
            source.contains("Color.clear.frame(height: Theme.spacingSM)"),
            "the sender-group-to-sender-group gap must be a pure spacing spacer (Color.clear), not a rendered hairline — design decision 2 reversing the original Ember Glass §13 call to keep it, per render-2-conversation-thread.png showing no such line"
        )
    }

    func test_source_chatThreadView_hasExactlyOneRemainingHairline_headerOnly() throws {
        // ChatThreadView.swift originally used this exact hairline one-liner
        // in two unrelated places: the header's bottom edge and the
        // composer's top edge. Task 20260828-chat-schedule-ui-cleanup-ios
        // deliberately removed the composer's copy (its own acceptance
        // criterion 7), so only the header's remains — see that task's
        // ComposerDividerRemovalRegressionTests for the dedicated coverage
        // of that removal. This assertion is updated from 2 to 1 to reflect
        // that intended state; a 3rd occurrence reappearing would still mean
        // the (unrelated) removed sender-group divider has regressed back in.
        let source = try readSource("FellowScript/Chat/ChatThreadView.swift")
        let occurrences = source.components(separatedBy: "Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "expected exactly 1 remaining occurrence of the plain hairline one-liner in ChatThreadView.swift (header's bottom edge only, since the composer's own copy was intentionally removed by task 20260828-chat-schedule-ui-cleanup-ios)"
        )
    }

    func test_source_dayDividerHairlines_remainUntouchedInMessageGroupRow() throws {
        // Design decision 2 only reverses the plain, unlabeled sender-group
        // divider — the day-boundary divider's own line-flanking-a-label
        // motif (design gate §13, unchanged) must still be intact.
        let source = try readSource("FellowScript/Chat/MessageGroupRow.swift")
        let occurrences = source.components(separatedBy: "Rectangle().fill(Theme.borderGoldFaint)").count - 1
        XCTAssertEqual(
            occurrences, 2,
            "DayDividerRow must still render its two flanking hairlines around the day label — this decision must not have collaterally removed those"
        )
    }
}

// MARK: - 3. ChipToggle single-line/equal-height fix

final class ChipToggleWrapFixRegressionTests: XCTestCase {

    private func makeChip(title: String, isOn: Bool = false) -> ChipToggle {
        ChipToggle(title: title, isOn: .constant(isOn))
    }

    func test_repeatWeeklyChip_titleText_hasLineLimitOne() throws {
        let sut = makeChip(title: "Repeat weekly")
        let text = try sut.inspect().find(text: "Repeat weekly")
        XCTAssertEqual(try text.lineLimit(), 1,
                       "both Session-Options chips must render single-line at default Dynamic Type/device width")
    }

    func test_summarizeWithAgentChip_titleText_hasLineLimitOne() throws {
        // This is the specific chip the intake spec found wrapping to two
        // lines and breaking equal-height alignment with "Repeat weekly".
        let sut = makeChip(title: "Summarize with agent")
        let text = try sut.inspect().find(text: "Summarize with agent")
        XCTAssertEqual(try text.lineLimit(), 1,
                       "'Summarize with agent' previously wrapped to two lines at default width — .lineLimit(1) must keep it single-line")
    }

    func test_summarizeWithAgentChip_titleText_hasMinimumScaleFactor_soItShrinksRatherThanWraps() throws {
        let sut = makeChip(title: "Summarize with agent")
        let text = try sut.inspect().find(text: "Summarize with agent")
        XCTAssertEqual(try text.minimumScaleFactor(), 0.75,
                       "the longer label must be allowed to shrink (minimumScaleFactor) rather than wrap or get clipped, keeping equal height with the shorter chip")
    }

    func test_repeatWeeklyChip_titleText_hasMinimumScaleFactor_forParityWithTheLongerChip() throws {
        let sut = makeChip(title: "Repeat weekly")
        let text = try sut.inspect().find(text: "Repeat weekly")
        XCTAssertEqual(try text.minimumScaleFactor(), 0.75,
                       "both chips must share the same lineLimit/minimumScaleFactor treatment for equal-height parity, not just the chip that used to visibly wrap")
    }

    // Existing tap-toggle behavior (ChipToggleTests.swift) is untouched by
    // this fix — re-confirming here that the fix didn't disturb it.
    func test_summarizeWithAgentChip_stillTogglesOnTap() throws {
        var current = false
        let binding = Binding<Bool>(get: { current }, set: { current = $0 })
        let sut = ChipToggle(title: "Summarize with agent", isOn: binding)
        try sut.inspect().find(ViewType.HStack.self).callOnTapGesture()
        XCTAssertTrue(current)
    }
}

// MARK: - 4. Models.swift flexible ISO8601 date-parsing fix

final class FlexibleISO8601DateParsingRegressionTests: XCTestCase {

    // MARK: parseFlexibleISO8601 (the shared helper both fixes now use)

    func test_parseFlexibleISO8601_handlesFractionalSecondsFormat() {
        XCTAssertNotNil(parseFlexibleISO8601("2026-07-02T19:00:00.000Z"))
    }

    func test_parseFlexibleISO8601_handlesNonFractionalSecondsFormat() {
        // The exact reproduction case: the server (and the client's own
        // ChatThreadViewModel.sendMessage) can produce a timestamp with no
        // fractional seconds — this is what the fractional-only parser
        // silently failed on before the fix.
        XCTAssertNotNil(parseFlexibleISO8601("2026-07-02T19:00:00Z"))
    }

    func test_parseFlexibleISO8601_emptyStringReturnsNilRatherThanCrashing() {
        XCTAssertNil(parseFlexibleISO8601(""))
    }

    func test_parseFlexibleISO8601_malformedStringReturnsNilRatherThanCrashing() {
        XCTAssertNil(parseFlexibleISO8601("not-a-real-date"))
    }

    // MARK: FSSession.formattedStart

    func test_FSSession_formattedStart_nonFractionalTimestamp_formatsInsteadOfReturningRawString() {
        // This is the exact bug the intake spec found: "2026-07-02T19:00:00"
        // (no fractional seconds, no trailing Z) rendered verbatim in the
        // SessionBanner instead of a formatted "Today · 8:00 PM"-style string.
        var session = FSSession()
        session.time_start = "2026-07-02T19:00:00"
        let formatted = session.formattedStart
        XCTAssertNotEqual(formatted, "2026-07-02T19:00:00",
                           "a non-fractional-seconds ISO8601 timestamp must be formatted, not fall back to the raw string")
        XCTAssertFalse(formatted.isEmpty)
    }

    func test_FSSession_formattedStart_nonFractionalTimestampWithZ_alsoFormats() {
        var session = FSSession()
        session.time_start = "2026-07-02T19:00:00Z"
        let formatted = session.formattedStart
        XCTAssertNotEqual(formatted, "2026-07-02T19:00:00Z")
        XCTAssertFalse(formatted.isEmpty)
    }

    func test_FSSession_formattedStart_fractionalTimestamp_stillFormats_noRegression() {
        var session = FSSession()
        session.time_start = "2026-07-02T19:00:00.000Z"
        let formatted = session.formattedStart
        XCTAssertNotEqual(formatted, "2026-07-02T19:00:00.000Z")
        XCTAssertFalse(formatted.isEmpty)
    }

    func test_FSSession_formattedStart_emptyTimeStart_returnsEmptyString() {
        var session = FSSession()
        session.time_start = ""
        XCTAssertEqual(session.formattedStart, "")
    }

    func test_FSSession_formattedStart_genuinelyMalformedString_stillFallsBackToRawString() {
        // The raw-string fallback itself is legitimate for truly unparseable
        // input — only the fractional-seconds-only gap was the bug being
        // fixed, not the existence of a fallback at all.
        var session = FSSession()
        session.time_start = "not-a-real-date"
        XCTAssertEqual(session.formattedStart, "not-a-real-date")
    }

    // MARK: FSMessage.formattedTime

    func test_FSMessage_formattedTime_nonFractionalTimestamp_formatsInsteadOfReturningEmptyString() {
        // Same-pattern audit finding: ChatThreadViewModel.sendMessage stamps
        // outgoing messages with ISO8601DateFormatter()'s default (no
        // fractional seconds) — before the fix this silently rendered no
        // time label at all for the message a user just sent.
        let message = FSMessage(id: "1", text: "hi", mine: true, sender: "", timestamp: "2026-08-09T18:00:00Z")
        XCTAssertFalse(message.formattedTime.isEmpty,
                       "a just-sent message's own non-fractional-seconds timestamp must still produce a time label")
    }

    func test_FSMessage_formattedTime_fractionalTimestamp_stillFormats_noRegression() {
        let message = FSMessage(id: "1", text: "hi", mine: false, sender: "alice",
                                 timestamp: "2026-08-09T18:00:00.000Z")
        XCTAssertFalse(message.formattedTime.isEmpty)
    }

    func test_FSMessage_formattedTime_emptyTimestamp_returnsEmptyString() {
        let message = FSMessage(id: "1", text: "hi", mine: true, sender: "", timestamp: "")
        XCTAssertEqual(message.formattedTime, "")
    }

    func test_FSMessage_formattedTime_malformedTimestamp_returnsEmptyStringRatherThanCrashing() {
        let message = FSMessage(id: "1", text: "hi", mine: true, sender: "", timestamp: "not-a-real-date")
        XCTAssertEqual(message.formattedTime, "")
    }
}
