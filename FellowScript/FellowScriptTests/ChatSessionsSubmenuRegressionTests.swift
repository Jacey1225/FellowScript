// ChatSessionsSubmenuRegressionTests.swift — coverage for task
// 20260920-chat-sessions-submenu (testing gate, final step of the
// lightweight pipeline).
//
// Proves the four acceptance criteria the design gate implemented directly
// in ChatThreadView.swift:
//
//   1. The header's session pill now reads "Sessions" (not "Schedule"),
//      keeps its calendar icon/gradient background, and its accessibility
//      label reflects the new view-and-schedule role.
//   2. The old always-visible inline `SessionBanner` card is gone from the
//      thread body -- neither `SessionBanner(` nor `vm.sessions.first` is
//      instantiated/read anywhere outside the (still-present, still
//      independently tested by SessionBannerAndDetailSheetTests /
//      SessionBannerRowRestructureRegressionTests) `SessionBanner` struct
//      definition itself.
//   3. Tapping "Sessions" opens a floating, translucent/blurred submenu
//      (`.ultraThinMaterial` scrim + `.regularMaterial` card) listing every
//      session for the chat, with a "Schedule new session" action wired to
//      the existing create-session sheet, an empty state when there are no
//      sessions, and upcoming/past sections that only label themselves when
//      both groups are non-empty.
//   4. Tapping a listed session opens the existing `SessionDetailSheet` via
//      `.sheet(item: $selectedSession)`, preserving its join/edit/delete
//      flows unmodified.
//
// `header`/`sessionsMenuOverlay`/`sessionsMenuCard`/`sessionRow` are all
// private computed properties/methods of ChatThreadView, which (per this
// file's own established precedent -- see
// ChatScheduleUICleanupIOSRegressionTests's `headerSource()`/`composerSource()`
// and EmberGlassFidelityPassRegressionTests' SenderGroupDividerRemovalRegressionTests)
// can't be hosted directly in a unit test without a live EnvironmentObject/
// WebSocket round trip, so this suite reads the real shipped source directly,
// scoped to the specific region under test, rather than driving a live render.

import XCTest
@testable import FellowScript

final class ChatSessionsSubmenuRegressionTests: XCTestCase {

    private func chatThreadViewSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // repo-relative project root
            .appendingPathComponent("FellowScript/Chat/ChatThreadView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Isolates just the header property, ending before the sessions-submenu
    /// block begins -- narrower than ChatScheduleUICleanupIOSRegressionTests'
    /// own `headerSource()` (which intentionally runs through to `composer`),
    /// so assertions here can't accidentally be satisfied by code that lives
    /// in the submenu instead of the header itself.
    // NOTE: the "// ── Sessions submenu (task 20260920-chat-sessions-submenu)"
    // marker comment appears *twice* in the shipped source -- once above the
    // `@State` declarations near the top of the struct, and again above the
    // `openSessionsMenu`/overlay/card/row block itself. Every lookup below
    // that uses it as a boundary constrains its search to *after* a known
    // anchor (`header`'s own start) so it always resolves to the second
    // occurrence, not the first (which sits before `header` and would
    // otherwise produce an inverted, crash-inducing range).

    private func headerOnlySource() throws -> String {
        let source = try chatThreadViewSource()
        guard let start = source.range(of: "private var header: some View {"),
              let end = source.range(of: "// ── Sessions submenu (task 20260920-chat-sessions-submenu)",
                                      range: start.upperBound..<source.endIndex) else {
            XCTFail("expected to find ChatThreadView's `header` property in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    /// Isolates the sessions-submenu block (`openSessionsMenu`/
    /// `closeSessionsMenu`/`upcomingSessions`/`pastSessions`/
    /// `sessionsMenuOverlay`/`sessionsMenuCard`/`sessionRow`), ending before
    /// the composer begins.
    private func sessionsSubmenuSource() throws -> String {
        let source = try chatThreadViewSource()
        guard let headerStart = source.range(of: "private var header: some View {"),
              let start = source.range(of: "// ── Sessions submenu (task 20260920-chat-sessions-submenu)",
                                        range: headerStart.upperBound..<source.endIndex),
              let end = source.range(of: "// ── Composer (mirrors chat.html",
                                      range: start.upperBound..<source.endIndex) else {
            XCTFail("expected to find ChatThreadView's sessions-submenu block in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    /// The body of the outer ZStack, where the old inline SessionBanner used
    /// to render and where the new floating overlay is now conditionally
    /// inserted -- isolated the same way as the two ranges above.
    private func threadBodyOverlaySource() throws -> String {
        let source = try chatThreadViewSource()
        guard let start = source.range(of: ".dismissesKeyboardOnScrollAndTap()"),
              let end = source.range(of: ".preferredColorScheme(.dark)") else {
            XCTFail("expected to find the thread body's overlay-insertion point in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    // MARK: - 1. Header pill rename

    func test_source_headerPill_readsSessionsNotSchedule() throws {
        let header = try headerOnlySource()
        XCTAssertTrue(header.contains(#"PillButton(title: "Sessions", systemIcon: "calendar")"#),
                      "the header's session pill must now read 'Sessions' and keep its calendar icon")
        XCTAssertFalse(header.contains(#"PillButton(title: "Schedule", systemIcon: "calendar")"#),
                       "the old 'Schedule' pill title must no longer be present in the header")
    }

    func test_source_headerPill_accessibilityLabelReflectsNewRole() throws {
        let header = try headerOnlySource()
        XCTAssertTrue(header.contains(#".accessibilityLabel("View and schedule study sessions")"#),
                      "the pill's accessibility label must reflect that it now both views and schedules sessions, not just 'Schedule new study session'")
        XCTAssertFalse(header.contains("Schedule new study session"),
                       "the old, schedule-only accessibility label must no longer be present")
    }

    func test_source_headerPill_actionOpensSessionsMenu() throws {
        let header = try headerOnlySource()
        XCTAssertTrue(header.contains("openSessionsMenu()"),
                      "tapping the header's Sessions pill must open the sessions submenu, not the create-session sheet directly")
    }

    // MARK: - 2. Inline SessionBanner removal

    func test_source_threadBody_noLongerInstantiatesInlineSessionBanner() throws {
        let source = try chatThreadViewSource()
        // The struct definition (`struct SessionBanner: View {`) legitimately
        // still contains the substring "SessionBanner(" nowhere in its own
        // declaration, so this check for an actual *instantiation* call site
        // (`SessionBanner(session:`) can't be satisfied by the surviving
        // struct itself -- only by a live call site, which must not exist.
        XCTAssertFalse(source.contains("SessionBanner(session:"),
                       "ChatThreadView must no longer instantiate SessionBanner inline -- it is fully replaced by the sessions submenu + detail sheet")
        XCTAssertFalse(source.contains("vm.sessions.first"),
                       "the old 'only ever show .first' assumption must be gone -- the submenu now surfaces the full vm.sessions array")
    }

    func test_source_sessionBannerStructDefinition_stillExists_forExistingCoverage() throws {
        // The design gate deliberately left the struct itself undeleted
        // (still exercised directly by SessionBannerAndDetailSheetTests /
        // SessionBannerRowRestructureRegressionTests) -- confirms this
        // suite's "no inline instantiation" assertion above isn't
        // accidentally passing because the whole type was deleted.
        let source = try chatThreadViewSource()
        XCTAssertTrue(source.contains("struct SessionBanner: View {"),
                      "SessionBanner's struct definition must still exist for its own dedicated regression suites")
    }

    func test_source_threadBody_sessionsOverlayRendersConditionallyAboveComposer() throws {
        let overlay = try threadBodyOverlaySource()
        XCTAssertTrue(overlay.contains("if showSessionsMenu {"),
                      "the sessions submenu overlay must render conditionally on showSessionsMenu")
        XCTAssertTrue(overlay.contains("sessionsMenuOverlay"),
                      "the conditional block must actually render sessionsMenuOverlay")
        XCTAssertFalse(overlay.contains("SessionBanner"),
                       "no SessionBanner reference should remain in the thread body's live layout")
    }

    // MARK: - 3. Submenu presentation: translucent/blurred, schedule action, empty state, sections

    func test_source_sessionsMenuOverlay_hasClearScrimWithTapToDismiss() throws {
        // Task 20260920-sessions-menu-background-blur: the backdrop no longer
        // blurs the whole chat thread -- it's an invisible tap-catcher now,
        // scoped so only sessionsMenuCard's own .regularMaterial reads as
        // translucent/blurred. Tap-outside-to-dismiss and accessibility must
        // still work exactly as before.
        let submenu = try sessionsSubmenuSource()
        XCTAssertTrue(submenu.contains("Color.clear"),
                      "the submenu's backdrop must be Color.clear so the chat thread behind it stays fully visible/unblurred")
        XCTAssertFalse(submenu.contains(".fill(.ultraThinMaterial)"),
                       "the full-screen .ultraThinMaterial backdrop must be gone -- blur now lives only on the card itself")
        XCTAssertTrue(submenu.contains("closeSessionsMenu()"),
                      "the backdrop (and the card's own close button) must be wired to dismiss the menu")
        XCTAssertTrue(submenu.contains(#".accessibilityLabel("Close sessions menu")"#),
                      "the tap-outside-to-dismiss scrim must be accessible, not just a silent hit target")
    }

    func test_source_sessionsMenuCard_usesRegularMaterialGlassSurface() throws {
        let submenu = try sessionsSubmenuSource()
        XCTAssertTrue(submenu.contains(".background(.regularMaterial)"),
                      "the submenu card itself must use the app's glass-surface material, matching the Ember Glass language")
        XCTAssertTrue(submenu.contains("topEdgeHighlight("),
                      "the submenu card must use the app's existing topEdgeHighlight elevation convention, not a dropped shadow")
    }

    func test_source_sessionsMenuCard_hasVisibleScheduleNewSessionAction() throws {
        let submenu = try sessionsSubmenuSource()
        XCTAssertTrue(submenu.contains("Schedule new session"),
                      "the submenu must contain a clearly visible 'Schedule new session' action")
        XCTAssertTrue(submenu.contains("showSession = true"),
                      "the schedule action must open the existing create-session sheet (showSession), not a new/duplicate flow")
    }

    func test_source_sessionsMenuCard_hasMinimalEmptyStateThatStillOffersSchedule() throws {
        let submenu = try sessionsSubmenuSource()
        guard let ifEmptyRange = submenu.range(of: "if vm.sessions.isEmpty {"),
              let emptyTextRange = submenu.range(of: "No sessions scheduled yet.", range: ifEmptyRange.upperBound..<submenu.endIndex),
              let scheduleActionRange = submenu.range(of: "Schedule new session") else {
            XCTFail("expected an `if vm.sessions.isEmpty` branch with a plain empty-state message in the submenu source")
            return
        }
        XCTAssertTrue(emptyTextRange.lowerBound > ifEmptyRange.upperBound,
                      "the empty-state message must actually live inside the `vm.sessions.isEmpty` branch")
        XCTAssertTrue(scheduleActionRange.lowerBound < ifEmptyRange.lowerBound,
                      "the schedule action must remain visible above/outside the empty-state branch, not only shown when there are sessions")
    }

    func test_source_sessionsMenuCard_listsBothUpcomingAndPastSessions() throws {
        let submenu = try sessionsSubmenuSource()
        XCTAssertTrue(submenu.contains("ForEach(upcomingSessions)"),
                      "the submenu must list every upcoming session, not just the next one")
        XCTAssertTrue(submenu.contains("ForEach(pastSessions)"),
                      "per the intake spec's literal 'all existing sessions' scope, past sessions must also be listed")
    }

    func test_source_sessionsMenuCard_sectionEyebrowsOnlyShowWhenBothGroupsNonEmpty() throws {
        let submenu = try sessionsSubmenuSource()
        // Both eyebrow insertions are guarded by the *other* array's
        // non-emptiness, not their own -- i.e. "Upcoming" only labels itself
        // when there are also past sessions to distinguish it from, and vice
        // versa, matching the single-group case reading as one plain list.
        guard let upcomingEyebrowRange = submenu.range(of: "SectionEyebrow(title: \"Upcoming\")"),
              let pastEyebrowRange = submenu.range(of: "SectionEyebrow(title: \"Past\")") else {
            XCTFail("expected both 'Upcoming' and 'Past' SectionEyebrow labels in the submenu source")
            return
        }
        // Check only the immediately-preceding text (a tight window right
        // before each eyebrow), not the whole prefix of the file -- both
        // guard conditions legitimately appear elsewhere in this same source
        // (e.g. the ForEach gates just below each eyebrow), so a whole-prefix
        // `.contains` would pass even if the eyebrow were accidentally moved
        // outside its guard.
        func immediatelyPrecedingWindow(before range: Range<String.Index>, width: Int = 80) -> String {
            let start = submenu.index(range.lowerBound, offsetBy: -width, limitedBy: submenu.startIndex) ?? submenu.startIndex
            return String(submenu[start..<range.lowerBound])
        }
        XCTAssertTrue(immediatelyPrecedingWindow(before: upcomingEyebrowRange).contains("if !pastSessions.isEmpty {"),
                      "the 'Upcoming' eyebrow must be immediately guarded by pastSessions being non-empty")
        XCTAssertTrue(immediatelyPrecedingWindow(before: pastEyebrowRange).contains("if !upcomingSessions.isEmpty {"),
                      "the 'Past' eyebrow must be immediately guarded by upcomingSessions being non-empty")
    }

    func test_source_sessionsSorting_upcomingSoonestFirst_pastMostRecentFirst() throws {
        let submenu = try sessionsSubmenuSource()
        // Pin the actual filter/comparator expressions rather than just their
        // presence, so a regression that keeps both arrays but flips a
        // comparator (e.g. accidentally reusing upcoming's ascending sort for
        // past sessions too) still fails this test.
        XCTAssertTrue(submenu.contains(">= now }") && submenu.contains("< (parseFlexibleISO8601($1.time_start) ?? .distantPast) }"),
                      "upcomingSessions must filter to time_start >= now and sort ascending (soonest first)")
        XCTAssertTrue(submenu.contains("< now }") && submenu.contains("> (parseFlexibleISO8601($1.time_start) ?? .distantPast) }"),
                      "pastSessions must filter to time_start < now and sort descending (most recent first)")
    }

    // MARK: - 4. Session row -> existing SessionDetailSheet

    func test_source_sessionRow_accessibilityLabelDescribesSessionTitleAndTime() throws {
        let submenu = try sessionsSubmenuSource()
        XCTAssertTrue(submenu.contains(#".accessibilityLabel("View session details: \(session.title), \(session.formattedStart)")"#),
                      "each session row must have an accessibility label describing which session it opens")
    }

    func test_source_sessionRow_tapSetsSelectedSessionAndClosesMenu() throws {
        let submenu = try sessionsSubmenuSource()
        guard let rowStart = submenu.range(of: "private func sessionRow(_ session: FSSession) -> some View {") else {
            XCTFail("expected to find sessionRow in the submenu source")
            return
        }
        let row = String(submenu[rowStart.lowerBound...])
        XCTAssertTrue(row.contains("selectedSession = session"),
                      "tapping a session row must set selectedSession, driving the existing SessionDetailSheet open")
        XCTAssertTrue(row.contains("closeSessionsMenu()"),
                      "tapping a session row must also close the submenu so the detail sheet isn't presented behind it")
    }

    func test_source_selectedSession_sheetWiresToExistingSessionDetailSheet() throws {
        let source = try chatThreadViewSource()
        XCTAssertTrue(source.contains(".sheet(item: $selectedSession) { session in"),
                      "the detail sheet must be item-driven off selectedSession, so any row in the submenu can open it")
        guard let sheetStart = source.range(of: ".sheet(item: $selectedSession) { session in") else {
            XCTFail("expected to find the selectedSession sheet wiring")
            return
        }
        let sheetBlock = String(source[sheetStart.lowerBound...])
        XCTAssertTrue(sheetBlock.contains("SessionDetailSheet(session: session, onDelete: refreshSessions, onUpdate: refreshSessions)"),
                      "the existing SessionDetailSheet must be reused as-is (same onDelete/onUpdate refresh wiring SessionBanner used), not a new/modified component")
    }

    // MARK: - Reduced motion

    func test_source_sessionsMenuOverlay_hasReducedMotionFallback() throws {
        let submenu = try sessionsSubmenuSource()
        XCTAssertTrue(submenu.contains("reduceMotion") && submenu.contains("? .opacity"),
                      "the submenu's open/close transition must degrade to a plain opacity swap under reduced motion")
        XCTAssertTrue(submenu.contains("withMotionAwareAnimation(.spring"),
                      "opening the submenu must use the file's existing motion-aware animation helper, not a raw unconditional animation")
        XCTAssertTrue(submenu.contains("withMotionAwareAnimation(.easeOut"),
                      "closing the submenu must use the file's existing motion-aware animation helper, not a raw unconditional animation")
    }
}

// MARK: - Sort-order fixture sanity (FSSession + parseFlexibleISO8601 are both
// directly testable, unlike ChatThreadView's private sorting properties
// themselves -- this independently confirms parseFlexibleISO8601 correctly
// orders the exact kind of timestamps the submenu's sessions carry, so the
// source-pinned comparator assertions above rest on a verified parsing
// foundation rather than an assumed one).
final class SessionsSubmenuSortFixtureSanityTests: XCTestCase {

    func test_parseFlexibleISO8601_ordersPlainTimestampsChronologically() {
        let earlier = parseFlexibleISO8601("2026-07-02T19:00:00")
        let later   = parseFlexibleISO8601("2026-09-14T18:00:00")
        XCTAssertNotNil(earlier)
        XCTAssertNotNil(later)
        XCTAssertTrue(earlier! < later!,
                      "the submenu's sort relies on parseFlexibleISO8601 producing chronologically-comparable Dates for this app's session timestamp format")
    }
}
