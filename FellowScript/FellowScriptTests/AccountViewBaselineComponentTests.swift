// AccountViewBaselineComponentTests.swift — testing gate coverage for task
// 20260904-compliance-readability-cleanup, step 1 (testing).
//
// AccountView.swift (2189 loc) had NO test coverage at all before this task
// (AccountViewModelTests.swift covers AccountViewModel.load, but nothing
// exercises the View layer). A later step in this same task splits
// AccountView into a view-model file plus per-section view files with no
// intended behavior change — this file adds baseline/characterization
// coverage for the file's self-contained, stateless View types and pure
// value types so that split has something concrete to verify against:
//
//   - `StatBox` / `EventRow` — reusable row components used by
//     statsSection/eventsSection, easy to instantiate and inspect in
//     isolation (same pattern as DashboardComponents.swift's
//     FriendActivityHeroCard/CheckInRow, see DashboardEmptyStateTests.swift).
//   - `AccountView.AccountSheet` — the `Identifiable` enum driving
//     `.sheet(item:)`; pure `id` logic, no View needed.
//   - `IdentifiableString` — trivial wrapper, included for completeness
//     since it's a one-line pure-logic type in the same file.
//
// Uses ViewInspector, matching this target's existing convention.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - StatBox

final class StatBoxBaselineTests: XCTestCase {

    func test_rendersValueAndLabelText() throws {
        let sut = StatBox(value: 12, label: "Notes")
        XCTAssertNoThrow(try sut.inspect().find(text: "12"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Notes"))
    }

    func test_zeroValue_stillRendersExplicitZero_notBlank() throws {
        let sut = StatBox(value: 0, label: "Highlights")
        XCTAssertNoThrow(try sut.inspect().find(text: "0"),
                          "a zero count must render as an explicit '0', never a blank/omitted value")
    }

    func test_accessibilityLabel_combinesValueAndLabel() throws {
        let sut = StatBox(value: 7, label: "Friends")
        let root = try sut.inspect().vStack()
        XCTAssertEqual(try root.accessibilityLabel().string(), "7 Friends")
    }
}

// MARK: - EventRow

final class EventRowBaselineTests: XCTestCase {

    private func heartbeat(prompt: String = "Pray for patience", timestamps: [String?] = Array(repeating: "09:00", count: 31)) -> FSHeartbeat {
        FSHeartbeat(id: "hb-1", agent_id: "agent-1", user_id: "user-1", timestamps: timestamps, prompt: prompt)
    }

    func test_rendersPromptAgentNameAndScheduleSummary() throws {
        let sut = EventRow(event: heartbeat(prompt: "Pray for patience"), agentName: "Spiritual Guide",
                            isFiring: false, onEdit: {}, onDelete: {}, onFire: {})
        XCTAssertNoThrow(try sut.inspect().find(text: "Pray for patience"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Spiritual Guide"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Every day"),
                          "a heartbeat with all 31 daily slots filled must show the 'Every day' schedule summary")
    }

    func test_emptyPrompt_fallsBackToUntitledEvent() throws {
        let sut = EventRow(event: heartbeat(prompt: ""), agentName: "Spiritual Guide",
                            isFiring: false, onEdit: {}, onDelete: {}, onFire: {})
        XCTAssertNoThrow(try sut.inspect().find(text: "Untitled Event"))
    }

    func test_longPrompt_isTruncatedToFiftyCharacters() throws {
        let longPrompt = String(repeating: "a", count: 80)
        let sut = EventRow(event: heartbeat(prompt: longPrompt), agentName: "Spiritual Guide",
                            isFiring: false, onEdit: {}, onDelete: {}, onFire: {})
        XCTAssertNoThrow(try sut.inspect().find(text: String(longPrompt.prefix(50))))
        XCTAssertThrowsError(try sut.inspect().find(text: longPrompt),
                              "the full 80-character prompt must never render untruncated") { _ in }
    }

    func test_noScheduledSlots_showsNotScheduled() throws {
        let sut = EventRow(event: heartbeat(timestamps: Array(repeating: nil, count: 31)), agentName: "Guide",
                            isFiring: false, onEdit: {}, onDelete: {}, onFire: {})
        XCTAssertNoThrow(try sut.inspect().find(text: "Not scheduled"))
    }

    func test_isFiring_showsProgressViewInsteadOfPlayIcon_andDisablesFireButton() throws {
        let sut = EventRow(event: heartbeat(), agentName: "Guide",
                            isFiring: true, onEdit: {}, onDelete: {}, onFire: {})
        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertNoThrow(try button.find(ViewType.ProgressView.self),
                          "while firing, the button must show a spinner, not the play icon")
        XCTAssertTrue(try button.isDisabled())
    }

    func test_notFiring_showsPlayIcon_buttonEnabled() throws {
        let sut = EventRow(event: heartbeat(), agentName: "Guide",
                            isFiring: false, onEdit: {}, onDelete: {}, onFire: {})
        let button = try sut.inspect().find(ViewType.Button.self)
        XCTAssertThrowsError(try button.find(ViewType.ProgressView.self),
                              "when not firing, no spinner should be present") { _ in }
        XCTAssertFalse(try button.isDisabled())
    }

    func test_tappingFireButton_invokesOnFire() throws {
        var fired = false
        let sut = EventRow(event: heartbeat(), agentName: "Guide",
                            isFiring: false, onEdit: {}, onDelete: {}, onFire: { fired = true })
        try sut.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(fired)
    }

    func test_fireButtonAccessibilityLabel_reflectsFiringState() throws {
        let firing = EventRow(event: heartbeat(), agentName: "Guide", isFiring: true, onEdit: {}, onDelete: {}, onFire: {})
        let idle   = EventRow(event: heartbeat(), agentName: "Guide", isFiring: false, onEdit: {}, onDelete: {}, onFire: {})

        XCTAssertEqual(try firing.inspect().find(ViewType.Button.self).accessibilityLabel().string(), "Firing event now")
        XCTAssertEqual(try idle.inspect().find(ViewType.Button.self).accessibilityLabel().string(), "Fire event now")
    }

    func test_rootAccessibilityLabel_combinesPromptAndScheduleSummary() throws {
        let sut = EventRow(event: heartbeat(prompt: "Pray for patience"), agentName: "Guide",
                            isFiring: false, onEdit: {}, onDelete: {}, onFire: {})
        let root = try sut.inspect().hStack()
        XCTAssertEqual(try root.accessibilityLabel().string(),
                        "Event: Pray for patience. Scheduled Every day.")
    }
}

// MARK: - AccountView.AccountSheet (Identifiable id logic)

final class AccountSheetIdentityBaselineTests: XCTestCase {

    func test_newAgent_id() {
        XCTAssertEqual(AccountView.AccountSheet.newAgent.id, "newAgent")
    }

    func test_newEvent_id() {
        XCTAssertEqual(AccountView.AccountSheet.newEvent.id, "newEvent")
    }

    func test_timezonePicker_id() {
        XCTAssertEqual(AccountView.AccountSheet.timezonePicker.id, "timezonePicker")
    }

    func test_editEvent_id_incorporatesHeartbeatId() {
        let event = FSHeartbeat(id: "hb-42")
        XCTAssertEqual(AccountView.AccountSheet.editEvent(event).id, "event-hb-42")
    }

    func test_editEvent_id_differsForDifferentHeartbeats_soSheetItemDoesNotCollide() {
        let first  = AccountView.AccountSheet.editEvent(FSHeartbeat(id: "hb-1"))
        let second = AccountView.AccountSheet.editEvent(FSHeartbeat(id: "hb-2"))
        XCTAssertNotEqual(first.id, second.id)
    }
}

// MARK: - IdentifiableString

final class IdentifiableStringBaselineTests: XCTestCase {

    func test_idEqualsValue() {
        XCTAssertEqual(IdentifiableString(value: "America/New_York").id, "America/New_York")
    }
}
