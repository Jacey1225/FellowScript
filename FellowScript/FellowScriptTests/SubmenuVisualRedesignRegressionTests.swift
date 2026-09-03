// SubmenuVisualRedesignRegressionTests.swift — testing-gate coverage for
// task 20260902-submenu-visual-redesign, step 3.
//
// The frontend gate (step 2) implemented design-notes.md's spec: extracted a
// shared `Theme.warmBloomBackground()` modifier (identical two-RadialGradient
// recipe already used on every primary tab screen), applied it to
// AddFriendSheet, AddGroupSheet, NewAgentSheet, and all three EventSetupSheet
// steps (recurrenceScreen/dayPickerScreen/detailsScreen), and restructured
// AddFriendSheet/AddGroupSheet/NewAgentSheet/EventSetupSheet.detailsScreen off
// native Form/Section onto ScrollView+VStack+widgetCard() layouts.
//
// Following this project's established technique for this exact class of
// task (see DashboardBackgroundConsistencyRegressionTests.swift, the direct
// predecessor task 20260901-dashboard-background-consistency, and
// InteractionPolishSharedMechanismsTests.swift) of pinning render-tree facts
// that ViewInspector can't cheaply assert on for a NavigationStack-wrapped
// sheet (an *exact* modifier call, an *absent* Form/Section, an unchanged
// callback signature) by reading the real shipped source directly.
//
// This file proves:
//   A. All four sheets (+ EventSetupSheet's two other steps) actually apply
//      `.warmBloomBackground()`, with the shared modifier itself carrying the
//      exact hex/opacity/anchor/radius values DashboardView.swift uses.
//   B. The five pre-existing warm-bloom-ground call sites (Dashboard/Account
//      root/Notes/Chat-root/Bible) were NOT repointed at the new modifier —
//      out-of-scope guard from design-notes.md §7.
//   C. AddFriendSheet, AddGroupSheet, NewAgentSheet, and
//      EventSetupSheet.detailsScreen no longer use native Form/Section.
//   D. No behavioral regression: onSend/onCreate/onSave callback signatures,
//      disabled predicates, prefill(from:), buildTimestamps(), and the
//      group-picker Menu's content/behavior are all byte-for-byte unchanged.
//   E. Existing accessibility labels/traits survived the container swap.
//   F. Presentation-detent additions landed exactly where spec'd, and
//      EventSetupSheet's own detents were left alone.
//   G. Out-of-bounds guard: TimeZonePickerSheet/ReportUserSheet were not
//      swept into this change.

import XCTest
import SwiftUI
@testable import FellowScript

final class SubmenuVisualRedesignRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - A. Shared background applied to all four sheets + 3 sub-screens

    func test_themeSwift_warmBloomBackground_usesExactSharedRecipe() throws {
        let source = try readSource("FellowScript/Theme/Theme.swift")
        guard let range = source.range(of: "func warmBloomBackground() -> some View {") else {
            XCTFail("shared warmBloomBackground() modifier not found in Theme.swift")
            return
        }
        let body = String(source[range.upperBound...].prefix(700))
        XCTAssertTrue(body.contains("Theme.bgPage"), "must layer the shared bgPage token as the base fill")
        XCTAssertTrue(
            body.contains(##"RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],"##) &&
            body.contains("center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)"),
            "first bloom (top-left, #D4922A @ 0.20) must match the exact anchor/radius every primary screen uses"
        )
        XCTAssertTrue(
            body.contains(##"RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],"##) &&
            body.contains("center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)"),
            "second bloom (bottom-right, #B8761D @ 0.12) must match the exact anchor/radius every primary screen uses"
        )
        XCTAssertTrue(body.contains(".ignoresSafeArea()"), "must ignore safe area like every other full-page background")
    }

    func test_addFriendSheet_appliesSharedWarmBloomBackground() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        guard let structRange = source.range(of: "struct AddFriendSheet: View {") else {
            XCTFail("AddFriendSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertTrue(body.contains(".warmBloomBackground()"), "AddFriendSheet must use the shared warm-bloom-ground modifier")
        XCTAssertFalse(body.contains("Theme.bgPage.ignoresSafeArea()"), "must not keep the old flat-fill background alongside the new one")
    }

    func test_addGroupSheet_appliesSharedWarmBloomBackground() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        guard let structRange = source.range(of: "struct AddGroupSheet: View {") else {
            XCTFail("AddGroupSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertTrue(body.contains(".warmBloomBackground()"), "AddGroupSheet must use the shared warm-bloom-ground modifier")
        XCTAssertFalse(body.contains("Theme.bgPage.ignoresSafeArea()"), "must not keep the old flat-fill background alongside the new one")
    }

    func test_newAgentSheet_appliesSharedWarmBloomBackground() throws {
        let source = try readSource("FellowScript/Account/AccountView.swift")
        guard let structRange = source.range(of: "struct NewAgentSheet: View {") else {
            XCTFail("NewAgentSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertTrue(body.contains(".warmBloomBackground()"), "NewAgentSheet must use the shared warm-bloom-ground modifier")
    }

    func test_eventSetupSheet_allThreeSteps_applySharedWarmBloomBackground() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        // Count only actual modifier CALL sites (a trimmed line that starts
        // with the modifier itself), not the explanatory comment mentioning
        // `Theme.warmBloomBackground()` by name -- same technique as
        // InteractionPolishSharedMechanismsTests' bespoke-call-site guard.
        let callSites = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0 == ".warmBloomBackground()" }
        XCTAssertEqual(callSites.count, 3, "expected exactly 3 call sites (recurrenceScreen, dayPickerScreen, detailsScreen), found \(callSites.count)")
        XCTAssertFalse(source.contains("Theme.bgPage.ignoresSafeArea()"), "EventSetupSheet must no longer use the old flat-fill background anywhere")
    }

    // MARK: - B. Out-of-scope guard: the five pre-existing call sites untouched

    func test_fivePreExistingWarmBloomCallSites_areNotRepointedAtSharedModifier() throws {
        // Each of these must still carry its own inline two-RadialGradient
        // duplicate (per design-notes.md §2/§7) rather than calling the new
        // shared modifier -- repointing them was explicitly out of bounds.
        //
        // NotesListView.swift is checked separately, scoped to NoteDetailView
        // only (below): task 20260903-notes-reply-submenu-restyle later
        // extended `.warmBloomBackground()` to that same file's
        // ReplyComposerSheet, which was correctly out of scope for THIS
        // (predecessor) task but is a legitimate, spec'd adoption by that
        // subsequent task -- mirroring how AccountView.swift/ChatRootView.swift
        // are already handled below (root screen keeps its own duplicate,
        // their own in-scope sheets do use the shared modifier).
        let untouchedFiles = [
            "FellowScript/Dashboard/DashboardView.swift",
            "FellowScript/Bible/BibleReaderView.swift",
        ]
        for path in untouchedFiles {
            let source = try readSource(path)
            XCTAssertTrue(source.contains("Theme.bgPage.ignoresSafeArea()"),
                          "\(path) must keep its own inline warm-bloom-ground background, not be repointed at the shared modifier")
            XCTAssertFalse(source.contains(".warmBloomBackground()"),
                           "\(path) must not have been swept into this task's shared-modifier adoption")
        }

        let notesSource = try readSource("FellowScript/Notes/NotesListView.swift")
        guard let detailStart = notesSource.range(of: "struct NoteDetailView: View {"),
              let detailEnd = notesSource.range(of: "\n// ── Reply composer sheet", range: detailStart.upperBound..<notesSource.endIndex) else {
            XCTFail("could not scope NoteDetailView's own body within NotesListView.swift")
            return
        }
        let noteDetailViewBody = String(notesSource[detailStart.upperBound..<detailEnd.lowerBound])
        XCTAssertTrue(noteDetailViewBody.contains("Theme.bgPage.ignoresSafeArea()"),
                      "NoteDetailView's own root-screen background duplicate must remain untouched by this task")
        XCTAssertFalse(noteDetailViewBody.contains(".warmBloomBackground()"),
                       "NoteDetailView itself must not have been swept into this task's shared-modifier adoption")

        // AccountView.swift and ChatRootView.swift DO contain
        // `.warmBloomBackground()` now (their own in-scope sheets use it),
        // but their pre-existing root-screen inline duplicate must remain.
        let accountSource = try readSource("FellowScript/Account/AccountView.swift")
        XCTAssertTrue(accountSource.contains("Theme.bgPage.ignoresSafeArea()"),
                      "AccountView's own root-screen background duplicate must remain untouched")

        let chatSource = try readSource("FellowScript/Chat/ChatRootView.swift")
        XCTAssertTrue(chatSource.contains("Theme.bgPage.ignoresSafeArea()"),
                      "ChatRootView's own root-screen background duplicate must remain untouched")
    }

    // MARK: - C. Structural decision: Form/Section removed from the four sheets

    func test_addFriendSheet_noLongerUsesFormOrSection() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        guard let structRange = source.range(of: "struct AddFriendSheet: View {") else {
            XCTFail("AddFriendSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertFalse(body.contains("Form {") || body.contains("Form(") || body.contains("Section("),
                       "AddFriendSheet must be restructured off native Form/Section")
        XCTAssertTrue(body.contains("ScrollView") && body.contains(".widgetCard()"),
                      "AddFriendSheet must use the ScrollView + widgetCard() shell")
    }

    func test_addGroupSheet_noLongerUsesFormOrSectionOrList() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        guard let structRange = source.range(of: "struct AddGroupSheet: View {") else {
            XCTFail("AddGroupSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertFalse(body.contains("Form {") || body.contains("Form(") || body.contains("Section("),
                       "AddGroupSheet must be restructured off native Form/Section")
        XCTAssertFalse(body.contains("List("), "AddGroupSheet's member list must no longer be a native List")
        XCTAssertTrue(body.contains("ScrollView") && body.contains(".widgetCard()") && body.contains("ForEach("),
                      "AddGroupSheet must use the ScrollView + widgetCard() + manual ForEach shell")
    }

    func test_newAgentSheet_noLongerUsesFormOrSection() throws {
        let source = try readSource("FellowScript/Account/AccountView.swift")
        guard let structRange = source.range(of: "struct NewAgentSheet: View {") else {
            XCTFail("NewAgentSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertFalse(body.contains("Form {") || body.contains("Form(") || body.contains("Section("),
                       "NewAgentSheet must be restructured off native Form/Section")
    }

    func test_eventSetupSheet_detailsScreen_noLongerUsesFormOrSection() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        guard let range = source.range(of: "private var detailsScreen: some View {") else {
            XCTFail("detailsScreen not found"); return
        }
        // detailsScreen is the last computed property before the private
        // helpers section -- bound the search at the "── Helpers" marker.
        let end = source.range(of: "// ── Helpers", range: range.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[range.upperBound..<end])
        XCTAssertFalse(body.contains("Form {") || body.contains("Form(") || body.contains("Section("),
                       "EventSetupSheet.detailsScreen must be restructured off native Form/Section")
        XCTAssertTrue(body.contains("ScrollView") && body.contains(".widgetCard()"),
                      "EventSetupSheet.detailsScreen must use the ScrollView + widgetCard() shell matching recurrenceScreen/dayPickerScreen")
    }

    // MARK: - D. No behavioral regression: callbacks, disabled predicates, group-picker, prefill/buildTimestamps

    func test_addFriendSheet_onSendCallback_andDisabledPredicate_unchanged() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        XCTAssertTrue(source.contains("let onSend: (String) -> Void"), "onSend signature must be unchanged")
        XCTAssertTrue(source.contains("onSend(username)"), "Send Request must still call onSend with the raw username")
        XCTAssertTrue(source.contains(".disabled(username.isEmpty)"), "Send Request must still be disabled on empty username")
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Enter username to add as friend\")"),
                      "existing accessibility label must survive the container swap")
    }

    func test_addGroupSheet_onCreateCallback_andDisabledPredicate_unchanged() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        XCTAssertTrue(source.contains("let onCreate: (String, [String]) -> Void"), "onCreate signature must be unchanged")
        XCTAssertTrue(source.contains("onCreate(groupName, Array(selectedIds))"), "Create must still call onCreate with groupName + selectedIds")
        XCTAssertTrue(source.contains(".disabled(groupName.isEmpty)"), "Create must still be disabled on empty group name")
        XCTAssertTrue(source.contains(#".accessibilityLabel("\(f.name). \(selectedIds.contains(f.id) ? "Selected" : "Not selected")")"#),
                      "per-row accessibility label must survive the List->manual-ForEach container swap")
        XCTAssertTrue(source.contains(".accessibilityAddTraits(selectedIds.contains(f.id) ? .isSelected : [])"),
                      "per-row .isSelected trait must survive the List->manual-ForEach container swap")
        // The tap-to-toggle logic itself (the actual selection behavior) must
        // be byte-for-byte the same predicate as before the restructuring.
        XCTAssertTrue(source.contains("if selectedIds.contains(f.id) { selectedIds.remove(f.id) }") &&
                      source.contains("else                           { selectedIds.insert(f.id) }"),
                      "member-row tap-to-toggle logic must be unchanged")
    }

    func test_newAgentSheet_onCreateCallback_unchanged() throws {
        let source = try readSource("FellowScript/Account/AccountView.swift")
        guard let structRange = source.range(of: "struct NewAgentSheet: View {") else {
            XCTFail("NewAgentSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertTrue(body.contains("let onCreate: () -> Void"), "onCreate signature must be unchanged")
        // Literal button implementation updated by task
        // 20260902-submenu-followup-polish (plain Button -> gold PillButton),
        // but the call/dismiss wiring this assertion actually cares about is
        // unchanged.
        XCTAssertTrue(body.contains("PillButton(title: \"Create\") { onCreate(); dismiss() }"), "Create button must still call onCreate then dismiss")
        XCTAssertTrue(body.contains(".accessibilityLabel(\"Agent role description\")"), "existing accessibility label must survive the container swap")
    }

    func test_eventSetupSheet_onSaveCallback_andDisabledPredicate_unchanged() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains("let onSave:   (_ agentId: String, _ prompt: String, _ timestamps: [String?], _ groupId: String?) -> Void"),
                      "onSave signature must be unchanged")
        XCTAssertTrue(source.contains("onSave(selectedAgentId,") &&
                      source.contains("prompt.trimmingCharacters(in: .whitespaces),") &&
                      source.contains("buildTimestamps(),") &&
                      source.contains("selectedGroupId.isEmpty ? nil : selectedGroupId)"),
                      "Save/Update must still call onSave with the same four unmapped arguments")
        XCTAssertTrue(source.contains(".disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || selectedAgentId.isEmpty)"),
                      "Save/Update must still be disabled on empty prompt or missing agent")
    }

    func test_eventSetupSheet_groupPickerMenu_contentAndBehaviorUnchanged() throws {
        // Task 20260902-group-tagged-devotions' logic -- must be completely
        // untouched by this purely-visual redesign task.
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains(#"Button(action: { selectedGroupId = "" }) {"#), "the 'No Group' option must be unchanged")
        XCTAssertTrue(source.contains("ForEach(sortedGroups) { group in"), "the groups list source must be unchanged")
        XCTAssertTrue(source.contains("Button(action: { selectedGroupId = group.id }) {"), "selecting a group must be unchanged")
        XCTAssertTrue(source.contains(".background(Theme.goldGradient)") && source.contains(".clipShape(Capsule())") && source.contains(".topEdgeHighlight(Capsule())"),
                      "the group-picker pill's own visual recipe (untouched by this task's sheet-container changes) must remain exactly as before")
    }

    func test_eventSetupSheet_prefillAndBuildTimestamps_unchanged() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains("private func prefill(from hb: FSHeartbeat) {"), "prefill(from:) must still exist with the same signature")
        XCTAssertTrue(source.contains("selectedGroupId = hb.group_id ?? \"\""), "prefill must still restore the group selection")
        XCTAssertTrue(source.contains("private func buildTimestamps() -> [String?] {"), "buildTimestamps() must still exist with the same signature")
        XCTAssertTrue(source.contains("case .daily:") && source.contains("case .weekly:") && source.contains("case .monthly:"),
                      "buildTimestamps' recurrence branches must be unchanged")
    }

    func test_eventSetupSheet_dayPickerScreen_accessibilityUnchanged() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Day \\(day)\")"), "monthDayPicker's per-day accessibility label must be unchanged")
        XCTAssertTrue(source.contains(".accessibilityAddTraits(sel ? .isSelected : [])"), "day-grid .isSelected traits must be unchanged")
    }

    // MARK: - F. Presentation detents landed exactly where spec'd

    func test_addFriendSheet_getsMediumDetentAndDragIndicator() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        guard let structRange = source.range(of: "struct AddFriendSheet: View {") else {
            XCTFail("AddFriendSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertTrue(body.contains(".presentationDetents([.medium])"), "AddFriendSheet must get a .medium detent (fixes the before-shot's wasted empty space)")
        XCTAssertTrue(body.contains(".presentationDragIndicator(.visible)"), "AddFriendSheet must show a drag indicator")
    }

    func test_addGroupSheet_getsMediumLargeDetentsAndDragIndicator() throws {
        let source = try readSource("FellowScript/Chat/ChatRootView.swift")
        guard let structRange = source.range(of: "struct AddGroupSheet: View {") else {
            XCTFail("AddGroupSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertTrue(body.contains(".presentationDetents([.medium, .large])"), "AddGroupSheet must get .medium/.large detents (variable member-list length)")
        XCTAssertTrue(body.contains(".presentationDragIndicator(.visible)"), "AddGroupSheet must show a drag indicator")
    }

    func test_newAgentSheet_keepsExistingMediumDetent_unchanged() throws {
        let source = try readSource("FellowScript/Account/AccountView.swift")
        guard let structRange = source.range(of: "struct NewAgentSheet: View {") else {
            XCTFail("NewAgentSheet not found"); return
        }
        let end = source.range(of: "\nstruct ", range: structRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[structRange.upperBound..<end])
        XCTAssertTrue(body.contains(".presentationDetents([.medium])"), "NewAgentSheet's pre-existing .medium detent must remain unchanged")
    }

    func test_eventSetupSheet_getsNoPresentationDetentsChange_remainsFullHeight() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertFalse(source.contains(".presentationDetents("),
                       "EventSetupSheet's multi-step flow must remain full-height (no new presentationDetents call) per spec §3d")
    }

    // MARK: - G. Out-of-bounds guard: sheets not named in scope are untouched

    func test_timeZonePickerSheet_andReportUserSheet_notSweptIn() throws {
        let accountSource = try readSource("FellowScript/Account/AccountView.swift")
        guard let tzRange = accountSource.range(of: "struct TimeZonePickerSheet: View {") else {
            XCTFail("TimeZonePickerSheet not found"); return
        }
        let tzEnd = accountSource.range(of: "\nstruct ", range: tzRange.upperBound..<accountSource.endIndex)?.lowerBound ?? accountSource.endIndex
        let tzBody = String(accountSource[tzRange.upperBound..<tzEnd])
        XCTAssertFalse(tzBody.contains(".warmBloomBackground()"), "TimeZonePickerSheet was not named in scope and must not have been restyled")
        XCTAssertTrue(tzBody.contains("List(filtered, id: \\.self)"), "TimeZonePickerSheet must keep its native List, unchanged")

        let reportSource = try readSource("FellowScript/Chat/ReportUserSheet.swift")
        XCTAssertFalse(reportSource.contains(".warmBloomBackground()"), "ReportUserSheet was not named in scope and must not have been restyled")
        XCTAssertTrue(reportSource.contains("Form {"), "ReportUserSheet must keep its native Form, unchanged")
    }
}
