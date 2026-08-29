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
//      and its neighboring back button / "Schedule" pill are unchanged.
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
        let header = try headerSource()
        XCTAssertTrue(header.contains("Circle().fill(Theme.gold.opacity(0.18))"),
                      "the avatar circle's fill must be unchanged after removing only the bloom background")
        XCTAssertTrue(header.contains("Circle().stroke(Theme.borderGoldDim, lineWidth: 1)"),
                      "the avatar circle's stroke must be unchanged after removing only the bloom background")
        XCTAssertTrue(header.contains(".frame(width: 38, height: 38)"),
                      "the avatar must keep its original 38x38 sizing -- the bloom removal must not have resized it")
        XCTAssertTrue(header.contains("String(contact.name.prefix(1)).uppercased()"),
                      "the avatar's initial-letter content must be unchanged")
    }

    func test_source_headerAvatarBlock_backButtonAndSchedulePillUnaffected() throws {
        let header = try headerSource()
        XCTAssertTrue(header.contains(#"RoundIconButton(systemIcon: "chevron.left")"#),
                      "removing the avatar bloom must not have disturbed the back button")
        XCTAssertTrue(header.contains(#"PillButton(title: "Schedule", systemIcon: "calendar")"#),
                      "removing the avatar bloom must not have disturbed the header's own \"Schedule\" pill")
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

    // ── Title text ───────────────────────────────────────────────────────

    func test_sheetHeader_titleReadsSchedule_notScheduleASession() throws {
        let sut = makeSheet()
        XCTAssertNoThrow(try sut.inspect().find(text: "Schedule"),
                          "the sheet header title must read 'Schedule'")
        XCTAssertThrowsError(try sut.inspect().find(text: "Schedule a Session"),
                              "the old, over-long 'Schedule a Session' title must no longer render") { _ in }
    }

    // ── Cancel: circular xmark icon button, dismiss() preserved, accessible ─

    func test_cancelButton_isCircularXmarkIcon() throws {
        let sut = makeSheet()
        let cancel = try findCancelIconButton(in: sut)
        XCTAssertEqual(try cancel.actualView().systemIcon, "xmark",
                       "Cancel must be a circular button carrying the xmark glyph")
    }

    func test_cancelButton_noLongerRendersVisibleCancelText() throws {
        // The visible "Cancel" text is retired in favor of the icon-only
        // button -- its accessibility label (asserted below) is what now
        // carries that meaning.
        let sut = makeSheet()
        let cancel = try findCancelIconButton(in: sut)
        XCTAssertThrowsError(try cancel.find(text: "Cancel"),
                              "Cancel is now icon-only -- no visible 'Cancel' text should remain inside the button") { _ in }
    }

    func test_cancelButton_tapDoesNotThrow_dismissActionStillWired() throws {
        // dismiss() is a no-op outside a real presentation host, so (mirroring
        // this codebase's own established convention -- see
        // NoteDetailViewDirectionBTests' test_closePill_isPresentAndTappable)
        // this confirms the control exists and its tap doesn't throw/crash,
        // rather than observing dismissal itself.
        let sut = makeSheet()
        let cancel = try findCancelIconButton(in: sut)
        XCTAssertNoThrow(try cancel.find(ViewType.Button.self).tap())
    }

    func test_cancelButton_accessibilityLabelIsCancel() throws {
        let sut = makeSheet()
        let cancel = try findCancelIconButton(in: sut)
        XCTAssertEqual(try cancel.accessibilityLabel().string(), "Cancel")
    }

    // ── Schedule submit: circular calendar icon button ──────────────────────

    func test_scheduleButton_isCircularCalendarIcon() throws {
        let sut = makeSheet()
        let schedule = try findScheduleButton(in: sut)
        let image = try schedule.find(ViewType.Image.self)
        XCTAssertEqual(try image.actualImage().name(), "calendar",
                       "the submit action must be a circular button carrying a clearly legible scheduling icon")
    }

    func test_scheduleButton_disabledAndDimmedWhenTitleIsEmpty() throws {
        let sut = makeSheet()
        let schedule = try findScheduleButton(in: sut)
        XCTAssertTrue(try schedule.isDisabled(),
                      "the submit button must stay disabled while the session title is empty, exactly as the original PillButton was")
        XCTAssertEqual(try schedule.opacity(), 0.4, accuracy: 0.001,
                       "the submit button must stay dimmed (opacity 0.4) while the session title is empty")
    }

    func test_scheduleButton_accessibilityLabelIsScheduleSession() throws {
        let sut = makeSheet()
        XCTAssertNoThrow(try findScheduleButton(in: sut))
    }

    // The "re-enables once a title is typed" half of acceptance criterion 3,
    // and the tap -> scheduleSession() wiring, are pinned at the source
    // level rather than by mutating `title` through ViewInspector's
    // TextField.setInput(_:) and re-inspecting: that combination reliably
    // failed fast against this project's ViewInspector 0.10.3 / iOS 26.5
    // toolchain pairing while writing this suite (`title` is a private
    // @State with no external seam, and ViewInspector's TextField binding
    // reflection needs to match SwiftUI's current internal representation
    // to round-trip a mutation back into a fresh render). The empty-title
    // (disabled/dimmed) half above is proven live; this half proves the
    // *condition* driving both states is unchanged.
    func test_source_scheduleButton_disabledOpacityConditionAndActionWiring_unchanged() throws {
        let header = try sheetHeaderSource()
        XCTAssertTrue(header.contains("Button(action: scheduleSession)"),
                      "the circular submit button's action must still be scheduleSession(), unchanged from before the restyle")
        XCTAssertTrue(header.contains(".disabled(title.isEmpty)"),
                      "the submit button must stay disabled exactly when the session title is empty, unchanged from the original PillButton")
        XCTAssertTrue(header.contains(".opacity(title.isEmpty ? 0.4 : 1)"),
                      "the submit button's dimmed/full-opacity condition must be unchanged from the original PillButton")
    }

    // ── Centering: symmetric 36pt buttons flank the title ───────────────────

    func test_sheetHeader_cancelAndScheduleButtons_shareTheSame36ptDiameter() throws {
        // Equal-diameter side controls (plus the existing symmetric Spacers
        // on both sides of the title, unchanged from before this task) are
        // what makes the title centering work -- pin the diameter equality
        // directly rather than only visually.
        let sut = makeSheet()

        let cancelRoundIconButton = try sut.inspect().find(RoundIconButton.self)
        XCTAssertEqual(try cancelRoundIconButton.actualView().diameter, 36,
                       "Cancel's RoundIconButton must be 36pt to match the Schedule button's own 36pt frame")

        let schedule = try findScheduleButton(in: sut)
        let scheduleFrame = try schedule.find(ViewType.Image.self).fixedFrame()
        XCTAssertEqual(scheduleFrame.width, 36, accuracy: 0.001)
        XCTAssertEqual(scheduleFrame.height, 36, accuracy: 0.001)
    }

    func test_source_sheetHeader_titleSitsBetweenTwoSymmetricSpacers() throws {
        // See sheetHeaderSource()'s own comment for why this is a source-pin
        // rather than a ViewInspector traversal: this sheet's tree contains
        // a real DatePicker, and a broad `find(HStack, where: nested find)`
        // search across it hung indefinitely while writing this suite.
        let header = try sheetHeaderSource()
        XCTAssertEqual(header.components(separatedBy: "Spacer()").count - 1, 2,
                       "the title must still sit between exactly two Spacers (one on each side) for centering to hold once the side buttons are equal width")
        guard let cancelRange = header.range(of: "RoundIconButton(systemIcon: \"xmark\""),
              let firstSpacerRange = header.range(of: "Spacer()"),
              let titleRange = header.range(of: "Text(\"Schedule\")"),
              let secondSpacerRange = header.range(of: "Spacer()", range: firstSpacerRange.upperBound..<header.endIndex),
              let scheduleButtonRange = header.range(of: "Button(action: scheduleSession)") else {
            XCTFail("expected to find Cancel, both Spacers, the title, and the Schedule button in sheetHeader's source")
            return
        }
        XCTAssertTrue(
            cancelRange.lowerBound < firstSpacerRange.lowerBound &&
            firstSpacerRange.lowerBound < titleRange.lowerBound &&
            titleRange.lowerBound < secondSpacerRange.lowerBound &&
            secondSpacerRange.lowerBound < scheduleButtonRange.lowerBound,
            "expected source order Cancel -> Spacer -> \"Schedule\" title -> Spacer -> Schedule button, so the title is symmetrically flanked"
        )
    }

    // ── 3. "Summarize" chip label + unchanged toggle behavior ──────────────

    func test_sessionOptionsSection_summarizeChip_labelIsShortened() throws {
        let sut = makeSheet()
        XCTAssertNoThrow(try sut.inspect().find(text: "Summarize"),
                          "the chip must now read 'Summarize'")
        XCTAssertThrowsError(try sut.inspect().find(text: "Summarize with agent"),
                              "the old, over-long 'Summarize with agent' label must no longer render") { _ in }
    }

    func test_sessionOptionsSection_repeatWeeklyChip_isUntouchedByTheLabelChange() throws {
        let sut = makeSheet()
        XCTAssertNoThrow(try sut.inspect().find(text: "Repeat weekly"))
    }

    func test_summarizeChip_tapDoesNotThrow_toggleWiringStillIntact() throws {
        // Mirrors the Cancel button's own "does not throw" convention above:
        // $summarize is a private @State with no external seam, so the
        // resulting on/off value isn't reliably re-observable through a
        // second, separate ViewInspector inspection pass in this project's
        // ViewInspector/iOS toolchain pairing (see the scheduleButton source
        // note above for the same underlying limitation). ChipToggle's own
        // toggle *mechanism* (isOn.toggle() on tap) is already independently
        // covered by ChipToggleTests via an external Binding -- this confirms
        // the shortened chip is still wired to a live, throw-free tap target.
        let sut = makeSheet()
        let chip = try sut.inspect().find(ChipToggle.self, where: { view in
            (try? view.actualView().title) == "Summarize"
        })
        XCTAssertNoThrow(try chip.find(ViewType.HStack.self).callOnTapGesture())
    }

    func test_source_summarizeChip_stillBindsToTheSameSummarizeState() throws {
        let source = try chatThreadViewSource()
        XCTAssertTrue(
            source.contains(#"ChipToggle(title: "Summarize", isOn: $summarize)"#),
            "the shortened chip must still bind to the same $summarize state as before the label change, not a new/different property"
        )
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

    func test_source_chatThreadView_hasExactlyOneRemainingPlainHairline_headerOnly() throws {
        // Supersedes EmberGlassFidelityPassRegressionTests'
        // SenderGroupDividerRemovalRegressionTests expectation of exactly 2
        // occurrences (header + composer) -- that test predates this task,
        // which intentionally removes the composer's copy, per acceptance
        // criterion 7. That existing test's own count assertion is updated
        // alongside this one so the full suite reflects the new, intended
        // state rather than flagging an expected, spec-required change as a
        // regression.
        let source = try chatThreadViewSource()
        let occurrences = source.components(separatedBy: "Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "expected exactly 1 remaining occurrence of the plain hairline one-liner in ChatThreadView.swift (header's bottom edge only) now that the composer's top divider has been removed"
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
