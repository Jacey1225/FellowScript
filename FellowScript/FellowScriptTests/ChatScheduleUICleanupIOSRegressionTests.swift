// ChatScheduleUICleanupIOSRegressionTests.swift — coverage for task
// 20260828-chat-schedule-ui-cleanup-ios (testing gate, final step).
//
// Proves each of the four visual fixes this task made against the real,
// shipped Chat/ChatThreadView.swift source, so a regression of any one of
// them fails here rather than only being caught by a future manual
// screenshot comparison:
//
//   1. The oversized RadialGradient "ambient bloom" behind ChatThreadView's
//      header avatar is gone; the 38x38 avatar's fill/stroke/initial-letter
//      and its neighboring back button are unchanged (the header's pill
//      itself was later renamed "Schedule" -> "Sessions" by task
//      20260920-chat-sessions-submenu -- this suite's assertion tracks that
//      current title rather than the one that shipped with this task).
//   2. SessionCreatorSheet.sheetHeader: title reads "Schedule" (not
//      "Schedule a Session"); Cancel is a circular xmark icon button
//      (dismiss() preserved, accessible); the submit action is a circular
//      calendar icon button (scheduleSession()/disabled+opacity preserved,
//      accessible); both side buttons are the same 36pt diameter, centering
//      the title between symmetric Spacers.
//   3. sessionOptionsSection's "Summarize with agent" chip is now
//      "Summarize" -- the underlying $summarize toggle behavior is
//      unaffected.
//   4. The composer's own top hairline divider (between the message list and
//      the input/send bar) is gone, while header's own bottom divider and
//      GroupMembersPanel's divider (a distinct `Divider()`, untouched by
//      this task) remain.
//
// `header` and `composer` are private computed properties of ChatThreadView,
// which can't be hosted in a unit test without a live WebSocket/network
// round trip (no test in this target does -- see
// SessionBannerAndDetailSheetTests/EmberGlassFidelityPassRegressionTests'
// own SenderGroupDividerRemovalRegressionTests for this project's existing
// convention here), so items 1 and 4 read the real shipped source directly,
// scoped to the specific property being asserted on so a change elsewhere in
// the file can't accidentally satisfy the assertion. SessionCreatorSheet
// (item 2/3) has no such constraint -- it takes no EnvironmentObject and
// performs no network/socket work -- so it's inspected directly via
// ViewInspector, consistent with PillButtonTests/ChipToggleTests' existing
// technique for this exact file's other standalone components.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - 1. Header avatar bloom removal

final class HeaderAvatarBloomRemovalRegressionTests: XCTestCase {

    /// The `header` computed property's source, isolated from the rest of
    /// ChatThreadView.swift (canvas ambient wash + SessionBanner's own
    /// calendar-badge bloom both legitimately still use RadialGradient
    /// elsewhere in this file/module -- scoping to just `header` is what
    /// makes this test actually pin the avatar bloom specifically, not just
    /// "a RadialGradient exists somewhere").
    private func headerSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Chat/ChatThreadView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        guard let start = source.range(of: "private var header: some View {"),
              let end = source.range(of: "// ── Composer (mirrors chat.html") else {
            XCTFail("expected to find ChatThreadView's `header` property in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func test_source_headerAvatarBlock_hasNoRadialGradientBloom() throws {
        let header = try headerSource()
        XCTAssertFalse(
            header.contains("RadialGradient"),
            "the oversized ambient bloom behind the header avatar must be removed -- no RadialGradient should remain anywhere in ChatThreadView.header"
        )
    }

    func test_source_headerAvatarBlock_avatarFillStrokeSizingUnchanged() throws {
        // Task 20260905-profile-photo-avatar-gaps replaced this block's
        // previously-inline `ZStack { Circle().fill(...); Text(initial) }
        // .frame(width: 38, height: 38)` with a call into the shared
        // AvatarView component (same fill/diameter/initial passed through as
        // arguments instead of being written out literally here) so the
        // header can also render `contact.photoUrl` when present, falling
        // back to the exact same initials treatment otherwise -- per this
        // codebase's "reuse AvatarView rather than invent a third avatar
        // treatment" convention (already used by GroupMembersPanel/NoteRow).
        // The fill color, diameter, stroke, and initial-letter content are
        // still all present, just as AvatarView's own arguments/overlay
        // rather than inline Circle literals.
        let header = try headerSource()
        XCTAssertTrue(header.contains("AvatarView("),
                      "the header avatar must be rendered via the shared AvatarView component (photo-with-initials-fallback), not reverted to an inline ZStack")
        XCTAssertTrue(header.contains("fillColor: Theme.gold.opacity(0.18)"),
                      "the avatar's fill color must be unchanged after adopting AvatarView")
        XCTAssertTrue(header.contains("diameter: 38"),
                      "the avatar must keep its original 38x38 sizing -- adopting AvatarView must not have resized it")
        XCTAssertTrue(header.contains("Circle().stroke(Theme.borderGoldDim, lineWidth: 1)"),
                      "the avatar circle's stroke overlay must be unchanged")
        XCTAssertTrue(header.contains("initial: String(contact.name.prefix(1)).uppercased()"),
                      "the avatar's initial-letter fallback content must be unchanged")
        XCTAssertTrue(header.contains("photoURL: contact.photoUrl"),
                      "the header avatar must now also render the contact's real photo when present (task 20260905-profile-photo-avatar-gaps), falling back to the initial above when absent")
    }

    func test_source_headerAvatarBlock_backButtonAndSessionsPillUnaffected() throws {
        // UPDATED for task 20261028-dm-direct-call (Jacey option a): the friend-DM
        // header's trailing pill is now Call (same slot, same PillButton); the DM
        // Sessions pill is gone. Group Sessions live in the info chip row.
        // Task 20260920-chat-sessions-submenu renamed this pill "Schedule" ->
        // "Sessions" (now opening the sessions submenu instead of the
        // create-session sheet directly) -- updated here to the new intended
        // label so this stays a real regression guard rather than pinning a
        // title the feature intentionally moved past.
        let header = try headerSource()
        XCTAssertTrue(header.contains(#"RoundIconButton(systemIcon: "chevron.left")"#),
                      "removing the avatar bloom must not have disturbed the back button")
        XCTAssertTrue(header.contains(#"PillButton(title: "Call", systemIcon: "phone.fill")"#),
                      "removing the avatar bloom must not have disturbed the header's trailing Call pill")
        XCTAssertFalse(header.contains(#"PillButton(title: "Sessions""#),
                       "the friend-DM Sessions pill is removed")
    }
}

// MARK: - 2 & 3. SessionCreatorSheet.sheetHeader restyle + "Summarize" chip

@MainActor
final class SessionCreatorSheetHeaderRegressionTests: XCTestCase {

    private func makeSheet(onSave: @escaping (FSSession) -> Void = { _ in }) -> SessionCreatorSheet {
        SessionCreatorSheet(groupId: "group-1", onSave: onSave)
    }

    /// `RoundIconButton(...).accessibilityLabel("Cancel")` attaches the
    /// modifier to the *custom view* (RoundIconButton), not to the plain
    /// native `Button` nested inside its own `body` -- so accessibility/icon
    /// checks must be made against the RoundIconButton inspection node
    /// itself (`.find(RoundIconButton.self)`), not against a
    /// `.find(ViewType.Button.self, where: accessibilityLabel == ...)`
    /// search, which only sees modifiers attached directly to a native
    /// Button. There is exactly one RoundIconButton in this sheet (Cancel),
    /// so the type-based find is unambiguous.
    private func findCancelIconButton(in sut: SessionCreatorSheet) throws -> InspectableView<ViewType.View<RoundIconButton>> {
        try sut.inspect().find(RoundIconButton.self)
    }

    /// The circular Schedule submit button is a plain native `Button` with
    /// `.accessibilityLabel("Schedule session")` applied directly to it, so
    /// the direct find-by-accessibility-label technique (this codebase's own
    /// established pattern -- see NoteResumeCardContinueIslandTests) works
    /// unmodified here.
    private func findScheduleButton(in sut: SessionCreatorSheet) throws -> InspectableView<ViewType.Button> {
        try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string()) == "Schedule session"
        })
    }

    /// `sheetHeader`'s source, isolated the same way `header`/`composer` are
    /// in the sibling test classes below. Used for the handful of assertions
    /// that are safer pinned at the source level than driven through
    /// ViewInspector: this sheet embeds a real `DatePicker`
    /// (`startTimeSection`'s `DateTimeTile`), and broad/nested ViewInspector
    /// searches that walk through it (e.g. finding an HStack via a nested
    /// text-search predicate) were found, while writing this suite, to hang
    /// indefinitely against ViewInspector 0.10.3 on this project's iOS 26.5
    /// toolchain -- so those specific checks use the real shipped source
    /// directly instead, consistent with this codebase's own established
    /// fallback (see SenderGroupDividerRemovalRegressionTests).
    private func chatThreadViewSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Chat/ChatThreadView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func sheetHeaderSource() throws -> String {
        let source = try chatThreadViewSource()
        guard let start = source.range(of: "private var sheetHeader: some View {"),
              let end = source.range(of: "// MARK: - Sections") else {
            XCTFail("expected to find SessionCreatorSheet's `sheetHeader` property in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    // Forms restyle (20261023): the header's circular Cancel/Schedule buttons were replaced by the
    // FSForm scaffold (close X in the nav bar) and a sticky bar inside a 3-step stepper. These
    // tests pin the new structure and the behavior that must survive the restyle.

    func test_sheetHeader_titleReadsSchedule_notScheduleASession() throws {
        let sut = makeSheet()
        XCTAssertNoThrow(try sut.inspect().find(text: "Schedule"),
                          "the sheet title must read 'Schedule'")
        XCTAssertThrowsError(try sut.inspect().find(text: "Schedule a Session"),
                              "the old, over-long 'Schedule a Session' title must no longer render") { _ in }
    }

    private func sessionCreatorSource() throws -> String {
        let source = try chatThreadViewSource()
        guard let start = source.range(of: "struct SessionCreatorSheet: View {") else {
            XCTFail("SessionCreatorSheet not found"); return ""
        }
        return String(source[start.lowerBound...].prefix(14000))
    }

    func test_source_sheetUsesScaffoldWithThreeStepRail_andCloseDismisses() throws {
        let src = try sessionCreatorSource()
        XCTAssertTrue(src.contains("FSFormScaffold("))
        XCTAssertTrue(src.contains("title: isEditing ? \"Edit Session\" : \"Schedule\""))
        XCTAssertTrue(src.contains("let stepNames = [\"Basics\", \"Study\", \"Options\"]"))
        XCTAssertTrue(src.contains("onClose: { dismiss() }"), "closing must still dismiss the sheet")
    }

    func test_source_scheduleAction_isDimmedWithoutTitle_stillTappable_andKeepsItsAccessibilityLabel() throws {
        let src = try sessionCreatorSource()
        XCTAssertTrue(src.contains("primaryDimmed: !titleValid"))
        XCTAssertTrue(src.contains("primaryAccessibilityLabel: \"Schedule session\""))
        XCTAssertTrue(src.contains("private func tapSave()"), "a dimmed tap must still run validation (spec D8)")
        XCTAssertTrue(src.contains("scheduleSession()"), "the save wiring must be unchanged")
    }

    func test_source_optionsStep_repeatWeekly_andSummarize_stillBindToTheSameState() throws {
        let src = try sessionCreatorSource()
        XCTAssertTrue(src.contains("FSToggleRow(title: \"Repeat weekly\""))
        XCTAssertTrue(src.contains("isOn: $recurring"))
        XCTAssertTrue(src.contains("title: \"Summarize with agent\""))
        XCTAssertTrue(src.contains("isOn: $summarize"))
    }

}

// MARK: - 4. Composer top divider removal

final class ComposerDividerRemovalRegressionTests: XCTestCase {

    private func chatThreadViewSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Chat/ChatThreadView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The `composer` computed property's source, isolated the same way
    /// `header`'s is above.
    private func composerSource() throws -> String {
        let source = try chatThreadViewSource()
        guard let start = source.range(of: "private var composer: some View {"),
              let end = source.range(of: "private func sendMessage()") else {
            XCTFail("expected to find ChatThreadView's `composer` property in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func test_source_composer_hasNoTopDividerOverlay() throws {
        let composer = try composerSource()
        XCTAssertFalse(
            composer.contains("Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)"),
            "the composer's top hairline divider (between the message list and the input/send bar) must be removed"
        )
        XCTAssertFalse(composer.contains(".overlay(alignment: .top)"),
                       "the composer must not carry any top-edge overlay divider after removal")
    }

    func test_source_composer_sendButtonAndTextFieldUnaffectedByDividerRemoval() throws {
        let composer = try composerSource()
        XCTAssertTrue(composer.contains(#"TextField("", text: $text,"#),
                      "removing the divider must not have disturbed the message TextField")
        XCTAssertTrue(composer.contains("Button(action: sendMessage)"),
                      "removing the divider must not have disturbed the send button/action")
    }

    func test_source_headerBottomDivider_stillPresent_onlyComposerDividerWasRemoved() throws {
        // header's own bottom hairline is explicitly out of scope for this
        // task -- confirm it's still exactly where it was.
        let source = try chatThreadViewSource()
        guard let headerStart = source.range(of: "private var header: some View {"),
              let headerEnd = source.range(of: "// ── Composer (mirrors chat.html") else {
            XCTFail("expected to find ChatThreadView's `header` property in the shipped source")
            return
        }
        let header = String(source[headerStart.lowerBound..<headerEnd.lowerBound])
        XCTAssertTrue(
            header.contains(".overlay(alignment: .bottom) {") &&
            header.contains("Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)"),
            "header's own bottom divider must be untouched -- only the composer's top divider was in scope for this task"
        )
    }

    func test_source_chatThreadView_hasExactlyTwoRemainingPlainHairlines_headerAndSessionsMenuCard() throws {
        // Supersedes EmberGlassFidelityPassRegressionTests'
        // SenderGroupDividerRemovalRegressionTests expectation of exactly 2
        // occurrences (header + composer) -- that test predates this task,
        // which intentionally removes the composer's copy, per acceptance
        // criterion 7, dropping the count to 1. That existing test's own
        // count assertion was updated alongside this one at the time so the
        // full suite reflected that intended state.
        //
        // Task 20260920-chat-sessions-submenu later added a second, unrelated
        // use of this same one-liner (the divider between the sessions
        // submenu card's "Schedule new session" action and its session list),
        // bringing the count back to 2 -- both count assertions (this one and
        // EmberGlassFidelityPassRegressionTests' sibling) are updated together
        // again here so a real regression (the composer's divider reappearing,
        // or the sender-group divider reappearing) is still distinguishable
        // from this expected, intentional addition.
        let source = try chatThreadViewSource()
        let occurrences = source.components(separatedBy: "Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)").count - 1
        XCTAssertEqual(
            occurrences, 2,
            "expected exactly 2 remaining occurrences of the plain hairline one-liner in ChatThreadView.swift (header's bottom edge, and the sessions submenu card's schedule/list divider) now that the composer's own top divider has been removed"
        )
    }

    func test_source_groupMembersPanelDivider_isADistinctPrimitive_unaffectedByThisTask() throws {
        // GroupMembersPanel's own bottom divider uses SwiftUI's native
        // Divider(), not the Rectangle-based hairline pattern -- confirming
        // this documents why it's naturally excluded from the count above,
        // and pins that it wasn't collaterally touched.
        let source = try chatThreadViewSource()
        XCTAssertTrue(source.contains(".overlay(alignment: .bottom) { Divider().background(Theme.borderGoldFaint) }"),
                      "GroupMembersPanel's own divider must remain exactly as it was -- only the composer's top divider was in scope for this task")
    }
}
