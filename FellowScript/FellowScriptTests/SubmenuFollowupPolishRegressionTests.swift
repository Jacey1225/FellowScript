// SubmenuFollowupPolishRegressionTests.swift — testing-gate coverage for
// task 20260902-submenu-followup-polish, step 2 (frontend gate).
//
// The frontend gate fixed three specific follow-up issues on the four
// sheets restyled by the prior 20260902-submenu-visual-redesign task:
//   1. AddFriendSheet's (and, pre-emptively, the other three sheets') nav
//      title reading off-center once toolbar button widths changed --
//      fixed with a `.principal` ToolbarItem that centers independently of
//      the leading/trailing item widths.
//   2. EventSetupSheet.detailsScreen's stacked EVENT TIME / GROUP cards
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
//   B. EventSetupSheet.detailsScreen's EVENT TIME and GROUP controls sit in
//      one `.widgetCard()` (a single HStack), not two separate cards.
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
        XCTAssertTrue(sheetBody.contains("ToolbarItem(placement: .principal)"),
                      "AddFriendSheet must center its title via a `.principal` toolbar item, independent of leading/trailing button widths")
        XCTAssertTrue(sheetBody.contains("Text(\"Add Friend\")"),
                      "the `.principal` item must render the sheet's actual title text")
    }

    func test_addGroupSheet_hasPrincipalTitleItem() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        let sheetBody = try body(of: "AddGroupSheet", in: source)
        XCTAssertTrue(sheetBody.contains("ToolbarItem(placement: .principal)"),
                      "AddGroupSheet must also get the centered-title fix now that its Create button width changed")
        XCTAssertTrue(sheetBody.contains("Text(\"New Group\")"))
    }

    func test_newAgentSheet_hasPrincipalTitleItem() throws {
        // NewAgentSheet moved to AccountSupportingViews.swift in the
        // compliance-readability-cleanup task's AccountView.swift split.
        let source = try readSource("FellowScript/Account/AccountSupportingViews.swift")
        let sheetBody = try body(of: "NewAgentSheet", in: source)
        XCTAssertTrue(sheetBody.contains("ToolbarItem(placement: .principal)"),
                      "NewAgentSheet must also get the centered-title fix now that its Create button width changed")
        XCTAssertTrue(sheetBody.contains("Text(\"New Agent\")"))
    }

    func test_eventSetupSheet_recurrenceScreenAndDetailsScreen_havePrincipalTitleItems() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        guard let recRange = source.range(of: "private var recurrenceScreen: some View {") else {
            XCTFail("recurrenceScreen not found"); return
        }
        let recEnd = source.range(of: "private func recurrenceCard", range: recRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let recBody = String(source[recRange.upperBound..<recEnd])
        XCTAssertTrue(recBody.contains("ToolbarItem(placement: .principal)"),
                      "recurrenceScreen has no trailing item at all, so its default inline title was never truly centered -- needs the same `.principal` fix")
        XCTAssertTrue(recBody.contains("isEditing ? \"Edit Event\" : \"New Event\""))

        guard let detRange = source.range(of: "private var detailsScreen: some View {") else {
            XCTFail("detailsScreen not found"); return
        }
        let detEnd = source.range(of: "// ── Helpers", range: detRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let detBody = String(source[detRange.upperBound..<detEnd])
        XCTAssertTrue(detBody.contains("ToolbarItem(placement: .principal)"),
                      "detailsScreen must keep 'Details' centered now that its trailing pill is wider than the old plain-text button")
        XCTAssertTrue(detBody.contains("Text(\"Details\")"))
    }

    // MARK: - B. EventSetupSheet.detailsScreen: EVENT TIME + GROUP merged into one row

    func test_eventSetupSheet_detailsScreen_eventTimeAndGroupAreOneRow() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        guard let detRange = source.range(of: "private var detailsScreen: some View {") else {
            XCTFail("detailsScreen not found"); return
        }
        let detEnd = source.range(of: "// ── Helpers", range: detRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let detBody = String(source[detRange.upperBound..<detEnd])

        guard let hstackRange = detBody.range(of: "HStack(alignment: .top, spacing: Theme.spacingMD) {") else {
            XCTFail("the row-combining HStack (item 2's fix) was not found in detailsScreen"); return
        }
        guard let closingCardRange = detBody.range(of: ".widgetCard()", range: hstackRange.upperBound..<detBody.endIndex) else {
            XCTFail(".widgetCard() closing the merged row not found after the HStack"); return
        }
        let row = String(detBody[hstackRange.lowerBound..<closingCardRange.upperBound])

        XCTAssertTrue(row.contains("EVENT TIME"), "EVENT TIME must be inside the row-combining HStack")
        XCTAssertTrue(row.contains("\"GROUP\""), "GROUP must be inside the same row-combining HStack as EVENT TIME")
        // Only the one widgetCard() (closing this shared row) should appear
        // inside the HStack's own body -- confirms EVENT TIME and GROUP are
        // not still each individually wrapped in their own widgetCard().
        let rowBodyOnly = String(row.dropLast(".widgetCard()".count))
        XCTAssertFalse(rowBodyOnly.contains(".widgetCard()"),
                       "EVENT TIME and GROUP must share exactly one widgetCard() (the row's own), not carry individual ones")
        // The separate PROMPT card must come strictly after this merged row.
        guard let promptRange = detBody.range(of: "Text(\"PROMPT\")") else {
            XCTFail("PROMPT card not found"); return
        }
        XCTAssertTrue(closingCardRange.upperBound <= promptRange.lowerBound,
                      "the merged EVENT TIME/GROUP row's widgetCard() must close before the separate PROMPT card begins")
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
        let friendBody = try body(of: "AddFriendSheet", in: source)
        let groupBody = try body(of: "AddGroupSheet", in: source)
        for (name, sheetBody) in [("AddFriendSheet", friendBody), ("AddGroupSheet", groupBody)] {
            XCTAssertFalse(sheetBody.contains(#"Button("Cancel")"#),
                           "\(name) must no longer use a plain string-literal `Button(\"Cancel\")` (picks up unstyled system Liquid Glass chrome)")
            XCTAssertTrue(sheetBody.contains("sheetGhostCancelLabel"),
                          "\(name) must use the shared ghost-chip Cancel label")
            XCTAssertTrue(sheetBody.contains("Button(action: { dismiss() }) { sheetGhostCancelLabel }"),
                          "\(name)'s Cancel must still call dismiss()")
        }
        // The shared label itself must actually render as a custom chip
        // (capsule fill + stroke), not fall back to plain text.
        XCTAssertTrue(source.contains("fileprivate var sheetGhostCancelLabel: some View {"))
        XCTAssertTrue(source.contains("Capsule().fill(Theme.parchment.opacity(0.06))"))
        XCTAssertTrue(source.contains("Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1)"))
    }

    func test_newAgentSheet_usesGhostChipCancel_notPlainButton() throws {
        let source = try readSource("FellowScript/Account/AccountSupportingViews.swift")
        let sheetBody = try body(of: "NewAgentSheet", in: source)
        XCTAssertFalse(sheetBody.contains(#"Button("Cancel")"#),
                       "NewAgentSheet must no longer use a plain string-literal Button(\"Cancel\")")
        XCTAssertTrue(sheetBody.contains("cancelGhostChip"), "NewAgentSheet must use its own ghost-chip Cancel label")
        XCTAssertTrue(sheetBody.contains("Button(action: { dismiss() }) { cancelGhostChip }"),
                      "NewAgentSheet's Cancel must still call dismiss()")
        XCTAssertTrue(sheetBody.contains("Capsule().fill(Theme.parchment.opacity(0.06))"))
    }

    func test_eventSetupSheet_recurrenceScreen_usesGhostChipCancel_notPlainButton() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        guard let recRange = source.range(of: "private var recurrenceScreen: some View {") else {
            XCTFail("recurrenceScreen not found"); return
        }
        let recEnd = source.range(of: "private func recurrenceCard", range: recRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let recBody = String(source[recRange.upperBound..<recEnd])
        XCTAssertFalse(recBody.contains(#"Button("Cancel")"#),
                       "EventSetupSheet.recurrenceScreen must no longer use a plain string-literal Button(\"Cancel\")")
        XCTAssertTrue(recBody.contains("cancelGhostChip"), "recurrenceScreen must use the file's ghost-chip Cancel label")
        XCTAssertTrue(recBody.contains("Button(action: { dismiss() }) { cancelGhostChip }"),
                      "recurrenceScreen's Cancel must still call dismiss()")
    }

    // MARK: - D. Primary actions use PillButton (gold-gradient recipe), not a plain Button

    func test_addFriendSheet_sendRequest_usesPillButton() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        let sheetBody = try body(of: "AddFriendSheet", in: source)
        XCTAssertTrue(sheetBody.contains(#"PillButton(title: "Send Request") {"#),
                      "Send Request must use PillButton's gold-gradient recipe")
        XCTAssertFalse(sheetBody.contains(#"Button("Send Request")"#),
                       "must not keep the old plain-text Button for Send Request")
        XCTAssertTrue(sheetBody.contains(".disabled(username.isEmpty)"), "disabled predicate must be unchanged")
    }

    func test_addGroupSheet_create_usesPillButton() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        let sheetBody = try body(of: "AddGroupSheet", in: source)
        XCTAssertTrue(sheetBody.contains(#"PillButton(title: "Create") {"#))
        XCTAssertFalse(sheetBody.contains(#"Button("Create")"#))
        XCTAssertTrue(sheetBody.contains(".disabled(groupName.isEmpty)"), "disabled predicate must be unchanged")
    }

    func test_newAgentSheet_create_usesPillButton() throws {
        let source = try readSource("FellowScript/Account/AccountSupportingViews.swift")
        let sheetBody = try body(of: "NewAgentSheet", in: source)
        XCTAssertTrue(sheetBody.contains(#"PillButton(title: "Create") { onCreate(); dismiss() }"#))
        XCTAssertFalse(sheetBody.contains(#"Button("Create")"#))
    }

    func test_eventSetupSheet_detailsScreen_updateOrSave_usesPillButton() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        guard let detRange = source.range(of: "private var detailsScreen: some View {") else {
            XCTFail("detailsScreen not found"); return
        }
        let detEnd = source.range(of: "// ── Helpers", range: detRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let detBody = String(source[detRange.upperBound..<detEnd])
        XCTAssertTrue(detBody.contains(#"PillButton(title: isEditing ? "Update" : "Save") {"#),
                      "Update/Save must use PillButton's gold-gradient recipe, matching the other three sheets' primary actions")
        XCTAssertFalse(detBody.contains(#"Button("Update")"#) && detBody.contains(#"Button("Save")"#))
        XCTAssertTrue(detBody.contains(".disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || selectedAgentId.isEmpty)"),
                      "disabled predicate on Update/Save must be unchanged")
    }

    // MARK: - F. Out-of-scope guard: dayPickerScreen's Next and TimeZonePickerSheet untouched

    func test_dayPickerScreenNext_and_timeZonePickerSheetCancel_notSweptIntoThisTask() throws {
        let eventSource = try readSource("FellowScript/Account/EventSetupSheet.swift")
        guard let dayRange = eventSource.range(of: "private var dayPickerScreen: some View {") else {
            XCTFail("dayPickerScreen not found"); return
        }
        let dayEnd = eventSource.range(of: "private var weekdayPicker", range: dayRange.upperBound..<eventSource.endIndex)?.lowerBound ?? eventSource.endIndex
        let dayBody = String(eventSource[dayRange.upperBound..<dayEnd])
        XCTAssertTrue(dayBody.contains(#"Button("Next") { path.append(.details) }"#),
                      "dayPickerScreen's Next button was explicitly optional/out-of-scope and should be left as-is")

        let accountSource = try readSource("FellowScript/Account/AccountSupportingViews.swift")
        guard let tzRange = accountSource.range(of: "struct TimeZonePickerSheet: View {") else {
            XCTFail("TimeZonePickerSheet not found"); return
        }
        let tzEnd = accountSource.range(of: "\nstruct ", range: tzRange.upperBound..<accountSource.endIndex)?.lowerBound ?? accountSource.endIndex
        let tzBody = String(accountSource[tzRange.upperBound..<tzEnd])
        XCTAssertTrue(tzBody.contains(#"Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)"#),
                      "TimeZonePickerSheet was not named in this task's scope and must keep its plain Cancel button")
    }
}
