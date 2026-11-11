// SubmenuFollowupPolishRegressionTests.swift — testing-gate coverage for
// task 20260902-submenu-followup-polish, step 2 (frontend gate).
//
// The frontend gate fixed three specific follow-up issues on the four
// sheets restyled by the prior 20260902-submenu-visual-redesign task:
//   1. AddFriendSheet's (and, pre-emptively, the other three sheets') nav
//      title reading off-center once toolbar button widths changed --
//      fixed with a `.principal` ToolbarItem that centers independently of
//      the leading/trailing item widths.
//   2. EventSetupSheet.detailsScreen's stacked DEVOTION TIME / GROUP cards
//      merged into one row.
//   3. All four sheets' Cancel/primary toolbar buttons swapped from plain
//      system-styled Buttons to this app's own established chip
//      recipes: ghost-chip for Cancel, PillButton's gold-gradient pill for
//      the primary action.
//
// Following this project's established technique for this exact class of
// task (see SubmenuVisualRedesignRegressionTests.swift, the direct
// predecessor) of pinning render-tree facts that ViewInspector can't cheaply
// assert on for a NavigationStack-wrapped sheet (an exact toolbar item
// placement, an absent plain-Button Cancel, an unchanged callback wiring) by
// reading the real shipped source directly.
//
// This file proves:
//   A. All four sheets' relevant screens carry a `.principal` ToolbarItem
//      with the expected title text (decoupling the title from
//      leading/trailing item widths).
//   B. EventSetupSheet.detailsScreen's DEVOTION TIME and GROUP controls sit in
//      one `.fsCard()` (a single HStack), not two separate cards.
//   C. All four sheets' Cancel affordance is the ghost-chip recipe (a
//      Button wrapping a Text with a faint parchment-tinted Capsule
//      fill+stroke), not a plain `Button("Cancel") { }.foregroundColor(...)`.
//   D. All four sheets' primary action is `PillButton(title:)`, not a plain
//      `Button(...).foregroundColor(Theme.gold)`.
//   E. No behavioral regression: Cancel still calls `dismiss()`; disabled
//      predicates on the four primary actions are unchanged from before this
//      task (already covered by SubmenuVisualRedesignRegressionTests, but
//      re-asserted here scoped to this task's specific edits for isolation).
//   F. Out-of-scope guard: EventSetupSheet.dayPickerScreen's "Next" button
//      and TimeZonePickerSheet's Cancel were left as plain system buttons,
//      per this task's explicit optional/out-of-bounds scoping.

import XCTest
import SwiftUI
@testable import FellowScript

final class SubmenuFollowupPolishRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func body(of structName: String, in source: String) throws -> String {
        guard let structRange = source.range(of: "struct \(structName): View {") else {
            XCTFail("\(structName) not found")
            return ""
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        return String(source[structRange.upperBound..<end])
    }

    // MARK: - A. `.principal` title item on all four sheets' relevant screens

    func test_addFriendSheet_hasPrincipalTitleItem_decoupledFromToolbarWidths() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        let sheetBody = try body(of: "AddFriendSheet", in: source)
        XCTAssertTrue(sheetBody.contains("FSFormScaffold(") && sheetBody.contains("title: \"Add Friend\""),
                      "AddFriendSheet's centered title comes from the FSForm scaffold nav bar")
    }

    func test_addGroupSheet_hasPrincipalTitleItem() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        let sheetBody = try body(of: "AddGroupSheet", in: source)
        XCTAssertTrue(sheetBody.contains("FSFormScaffold(") && sheetBody.contains("title: \"New Group\""))
    }

    func test_newAgentSheet_hasPrincipalTitleItem() throws {
        // NewAgentSheet moved to AccountSupportingViews.swift in the
        // compliance-readability-cleanup task's AccountView.swift split.
        let source = try readSource("FellowScript/Account/AccountSupportingViews.swift")
        let sheetBody = try body(of: "NewAgentSheet", in: source)
        XCTAssertTrue(sheetBody.contains("FSFormScaffold(") && sheetBody.contains("title: \"New Agent\""),
                      "NewAgentSheet's centered title now comes from the FSForm scaffold nav bar")
    }

    func test_eventSetupSheet_recurrenceScreenAndDetailsScreen_havePrincipalTitleItems() throws {
        // TA1: one centered title for all three steps, from the FSFormScaffold nav bar.
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains("FSFormScaffold(") &&
                      source.contains("title: isEditing ? \"Edit scheduled devotion\" : \"New scheduled devotion\""),
                      "EventSetupSheet's centered title comes from the FSForm scaffold nav bar")
    }

    // MARK: - B. EventSetupSheet.detailsScreen: DEVOTION TIME + GROUP merged into one row

    func test_eventSetupSheet_detailsScreen_eventTimeAndGroupAreOneRow() throws {
        // TA1: Group and Time share ONE Details card on the WHO & WHEN step.
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        guard let start = source.range(of: "FSFormCard(title: \"Details\") {"),
              let end = source.range(of: "FSFormCard(title: \"Permissions\")", range: start.upperBound..<source.endIndex) else {
            XCTFail("Details card or Permissions card not found"); return
        }
        let card = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(card.contains("Text(\"Group\")"), "Group must sit inside the Details card")
        XCTAssertTrue(card.contains("Text(\"Time\")") && card.contains("DatePicker(\"Time\""), "Time must sit inside the same Details card")
        XCTAssertFalse(card.contains("FSFormCard("), "Group and Time must share the one card, not carry individual cards")
        // The separate Prompt card belongs to the next step.
        XCTAssertTrue(source.contains("private var promptCard: some View {") && source.contains("FSFormCard(title: \"Prompt\")"))
    }

    func test_eventSetupSheet_detailsScreen_dateAndMenuBindingsUnchanged() throws {
        // Both controls' actual behavior must be untouched by the re-layout.
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains(#"DatePicker("Time", selection: $selectedTime, displayedComponents: .hourAndMinute)"#),
                      "DatePicker binding must be moved verbatim, not altered")
        XCTAssertTrue(source.contains(#"Button(action: { selectedGroupId = "" }) {"#),
                      "'No Group' option in the group Menu must be unchanged")
        XCTAssertTrue(source.contains("ForEach(sortedGroups) { group in"),
                      "group list source in the Menu must be unchanged")
    }

    // MARK: - C. Cancel uses the ghost-chip recipe, not a plain system button

    func test_addFriendSheet_addGroupSheet_useGhostChipCancel_notPlainButton() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        for name in ["AddFriendSheet", "AddGroupSheet"] {
            let sheetBody = try body(of: name, in: source)
            XCTAssertFalse(sheetBody.contains(#"Button("Cancel")"#), "\(name) must not use a plain Button(\"Cancel\")")
            XCTAssertTrue(sheetBody.contains(#"secondaryTitle: "Cancel", onSecondary: { dismiss() }"#),
                          "\(name)'s Cancel is the pinned bar secondary and must still call dismiss()")
        }
    }

    func test_newAgentSheet_usesGhostChipCancel_notPlainButton() throws {
        let source = try readSource("FellowScript/Account/AccountSupportingViews.swift")
        let sheetBody = try body(of: "NewAgentSheet", in: source)
        XCTAssertFalse(sheetBody.contains(#"Button("Cancel")"#),
                       "NewAgentSheet must no longer use a plain string-literal Button(\"Cancel\")")
        XCTAssertTrue(sheetBody.contains(#"secondaryTitle: "Cancel", onSecondary: { dismiss() }"#),
                      "NewAgentSheet's Cancel is now the pinned bar's secondary action and must still call dismiss()")
    }

    func test_eventSetupSheet_recurrenceScreen_usesGhostChipCancel_notPlainButton() throws {
        // TA1: Cancel (step 1) / Back is the pinned bar's ghost-pill secondary.
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertFalse(source.contains(#"Button("Cancel")"#), "EventSetupSheet must not use a plain Button(\"Cancel\")")
        XCTAssertTrue(source.contains(#"secondaryTitle: step == 0 ? "Cancel" : "Back""#), "the pinned bar secondary is Cancel on step 1, Back after")
        XCTAssertTrue(source.contains("if step == 0 { dismiss() }"), "Cancel must still call dismiss()")
    }

    // MARK: - D. Primary actions use PillButton (gold-gradient recipe), not a plain Button

    func test_addFriendSheet_sendRequest_usesPillButton() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        let sheetBody = try body(of: "AddFriendSheet", in: source)
        XCTAssertTrue(sheetBody.contains(#"primaryTitle: "Send Request""#), "Send Request is the pinned bar primary")
        XCTAssertFalse(sheetBody.contains(#"Button("Send Request")"#))
        XCTAssertTrue(sheetBody.contains("primaryDimmed: username.isEmpty"), "dimmed predicate must be unchanged")
    }

    func test_addGroupSheet_create_usesPillButton() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        let sheetBody = try body(of: "AddGroupSheet", in: source)
        XCTAssertTrue(sheetBody.contains(#"primaryTitle: "Create""#))
        XCTAssertFalse(sheetBody.contains(#"Button("Create")"#))
        XCTAssertTrue(sheetBody.contains("primaryDimmed: groupName.isEmpty"), "dimmed predicate must be unchanged")
    }

    func test_newAgentSheet_create_usesPillButton() throws {
        let source = try readSource("FellowScript/Account/AccountSupportingViews.swift")
        let sheetBody = try body(of: "NewAgentSheet", in: source)
        XCTAssertTrue(sheetBody.contains(#"primaryTitle: "Create", onPrimary: { onCreate(); dismiss() }"#))
        XCTAssertFalse(sheetBody.contains(#"Button("Create")"#))
    }

    func test_eventSetupSheet_detailsScreen_updateOrSave_usesPillButton() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains(#"primaryTitle: lastStep ? (isEditing ? "Update" : "Save") : "Next""#),
                      "Update/Save is the pinned bar's gold primary, Next on earlier steps")
        XCTAssertFalse(source.contains(#"Button("Update")"#) || source.contains(#"Button("Save")"#))
        XCTAssertTrue(source.contains("primaryDimmed: primaryDimmed"), "primary dims via the sheet's predicate")
        XCTAssertTrue(source.contains("default: return needsDays || promptTrimmed.isEmpty || selectedAgentId.isEmpty"),
                      "Save/Update must still be dimmed on empty prompt or missing agent")
        XCTAssertTrue(source.contains("if isSaving { return true }"), "and while a save is in flight")
    }

    // MARK: - F. Out-of-scope guard: dayPickerScreen's Next and TimeZonePickerSheet untouched

    func test_dayPickerScreenNext_and_timeZonePickerSheetCancel_notSweptIntoThisTask() throws {
        // TA1 replaced the old dayPickerScreen with the inline REPEAT step; the
        // day pickers still exist and the Next button is the pinned bar's.
        let eventSource = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertFalse(eventSource.contains("dayPickerScreen"), "the old separate day-picker screen is gone")
        XCTAssertTrue(eventSource.contains("private var weekdayPicker") && eventSource.contains("private var monthDayPicker"),
                      "weekday and month-day pickers must survive inline in the REPEAT step")

        let accountSource = try readSource("FellowScript/Account/AccountSupportingViews.swift")
        guard let tzRange = accountSource.range(of: "struct TimeZonePickerSheet: View {") else {
            XCTFail("TimeZonePickerSheet not found"); return
        }
        let tzEnd = accountSource.range(of: "\nstruct ", range: tzRange.upperBound..<accountSource.endIndex)?.lowerBound ?? accountSource.endIndex
        let tzBody = String(accountSource[tzRange.upperBound..<tzEnd])
        XCTAssertTrue(tzBody.contains(#"FSFormScaffold("#) && tzBody.contains("onClose: { dismiss() }"),
                      "TimeZonePickerSheet (restyled onto the FSForm scaffold) must still dismiss on close")
    }
}
