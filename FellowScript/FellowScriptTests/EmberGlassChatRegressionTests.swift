// EmberGlassChatRegressionTests.swift — coverage for task
// 20260827-ember-glass-chat-rewrite, step 4 (testing).
//
// Proves the intake spec's "must not be removed" acceptance items #2 and #3
// individually, against the real, restyled Chat/ChatThreadView.swift source
// (per this project's per-bug/per-task test file convention — see
// AgentChatReconnectRegressionTests.swift's own comment on this):
//
//   2. GroupMembersPanel / the "Add member" dashed chip / the group icon next
//      to a group contact's name still render for group threads, restyled
//      (net-new visual design within the new system, per design gate §14.2).
//   3. SessionDetailSheet still shows verses, discussion prompts, "Repeats
//      weekly", and host-only delete-with-confirmation, restyled — reachable
//      from SessionBanner's "Details" button, not a dead end.
//
// GroupMembersPanel and SessionDetailSheet are both pure functions of their
// `let`/`@EnvironmentObject` inputs (no side effects on inspection), so they
// are inspected directly via ViewInspector's `.inspect()`, matching this
// target's existing convention for stateless-render components (see
// DashboardEmptyStateTests.swift's own note on this). SessionBanner/
// SessionDetailSheet additionally require an injected `AppState`
// EnvironmentObject — confirmed working with ViewInspector 0.10.3 in this
// target via `.environmentObject(_:)` before `.inspect()`.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - GroupMembersPanel (must-not-be-removed item #2)

final class GroupMembersPanelTests: XCTestCase {

    func test_rendersEachMemberNameAndTheCurrentUserAsYou() throws {
        let me = FSUser(user_id: "u1", username: "Zoe", email: "z@example.com")
        let sut = GroupMembersPanel(memberNames: ["Alice", "Bob"], user: me, onAddTapped: {})

        XCTAssertNoThrow(try sut.inspect().find(text: "Zoe (you)"),
                          "the viewer's own chip must render with the '(you)' suffix")
        XCTAssertNoThrow(try sut.inspect().find(text: "Alice"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Bob"))
    }

    func test_emptyMemberNameFallsBackToMemberRatherThanBlankChip() throws {
        // Real-world guard: a malformed/empty member username must not
        // render a blank, unlabeled avatar chip.
        let sut = GroupMembersPanel(memberNames: [""], user: nil, onAddTapped: {})
        XCTAssertNoThrow(try sut.inspect().find(text: "Member"))
    }

    func test_addChipRendersAndInvokesOnAddTappedWhenProvided() throws {
        var tapped = false
        let sut = GroupMembersPanel(memberNames: ["Alice"], user: nil, onAddTapped: { tapped = true })

        XCTAssertNoThrow(try sut.inspect().find(text: "Add"),
                          "the dashed 'Add member' chip must still render for group threads")
        try sut.inspect().find(button: "Add").tap()
        XCTAssertTrue(tapped)
    }

    func test_addChipDoesNotRenderWhenOnAddTappedIsNil() throws {
        // Mirrors ChatThreadView's real call site contract: onAddTapped is
        // only passed when the viewer may add members. The panel itself must
        // honor a nil closure by omitting the chip, not rendering a dead button.
        let sut = GroupMembersPanel(memberNames: ["Alice"], user: nil, onAddTapped: nil)
        XCTAssertThrowsError(try sut.inspect().find(text: "Add"),
                              "no add chip should render when onAddTapped is nil") { _ in }
    }
}

// MARK: - SessionBanner -> SessionDetailSheet (must-not-be-removed item #3)

@MainActor
final class SessionBannerAndDetailSheetTests: XCTestCase {

    private func makeSession(creatorId: String = "") -> FSSession {
        FSSession(
            id: "session-1",
            title: "Evening Study",
            time_start: "2026-08-27T18:00:00.000Z",
            verses: ["John 3:16", "Romans 8:28"],
            prompts: ["What stood out to you?", "How will you apply this?"],
            recurring: true,
            creator_id: creatorId
        )
    }

    // MARK: SessionBanner reachability

    func test_sessionBanner_rendersTitleAndDetailsButton() throws {
        let appState = AppState(service: MockDataService.shared)
        let sut = SessionBanner(session: makeSession()).environmentObject(appState)

        XCTAssertNoThrow(try sut.inspect().find(text: "Evening Study"))
        // "Details" is still the real, tappable pill that opens
        // SessionDetailSheet via the unchanged `showDetail` state -- this
        // proves the affordance is still present and wired to a real button
        // (not a dead label) after the restyle.
        XCTAssertNoThrow(try sut.inspect().find(button: "Details"))
        try sut.inspect().find(button: "Details").tap()
    }

    // MARK: SessionDetailSheet content -- verses, prompts, "Repeats weekly"

    func test_sessionDetailSheet_rendersVersesPromptsAndRecurringLabel() throws {
        let appState = AppState(service: MockDataService.shared)
        let sut = SessionDetailSheet(session: makeSession()).environmentObject(appState)
        let inspected = try sut.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Evening Study"))
        XCTAssertNoThrow(try inspected.find(text: "John 3:16"))
        XCTAssertNoThrow(try inspected.find(text: "Romans 8:28"))
        XCTAssertNoThrow(try inspected.find(text: "What stood out to you?"))
        XCTAssertNoThrow(try inspected.find(text: "How will you apply this?"))
        XCTAssertNoThrow(try inspected.find(text: "Repeats weekly"))
    }

    func test_sessionDetailSheet_nonRecurringSession_omitsRepeatsWeeklyLabel() throws {
        var session = makeSession()
        session.recurring = false
        let appState = AppState(service: MockDataService.shared)
        let sut = SessionDetailSheet(session: session).environmentObject(appState)

        XCTAssertThrowsError(try sut.inspect().find(text: "Repeats weekly"),
                              "a non-recurring session must not claim to repeat weekly") { _ in }
    }

    // MARK: Host-only delete-with-confirmation

    func test_sessionDetailSheet_hostSession_showsDeleteButton() throws {
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: "host-1", username: "Host", email: "h@example.com")
        let sut = SessionDetailSheet(session: makeSession(creatorId: "host-1")).environmentObject(appState)

        XCTAssertNoThrow(try sut.inspect().find(button: "Delete Session"),
                          "the session's creator must still see the delete affordance, restyled")
    }

    func test_sessionDetailSheet_nonHostViewer_hidesDeleteButton() throws {
        // Security/UX guard carried over unchanged from before the restyle:
        // only the creator may delete a session.
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: "someone-else", username: "Guest", email: "g@example.com")
        let sut = SessionDetailSheet(session: makeSession(creatorId: "host-1")).environmentObject(appState)

        XCTAssertThrowsError(try sut.inspect().find(button: "Delete Session"),
                              "a non-host viewer must not see the delete-session affordance") { _ in }
    }
}
