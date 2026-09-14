// SessionEditButtonAuthorGateTests.swift — minimal coverage for task
// 20260914-session-edit-button (Lightweight spec, no separate testing gate
// -- the frontend gate writes this itself per that workflow's own contract).
//
// Covers the acceptance criteria's testable core:
//   1. The new "Edit Session" button on SessionDetailSheet is gated by the
//      same author-only `isHost` rule as the existing Delete button (visible
//      to the creator, absent -- not merely disabled -- for anyone else),
//      mirroring NotesAuthorOnlyEditGateTests.swift's own pattern for the
//      analogous Notes feature.
//   2. SessionCreatorSheet's edit mode pre-fills from the passed-in
//      `existingSession` (title/verses/prompts all render).
//   3. The Save action, in edit mode, drives the new `onSaveAsync` closure
//      with the edited FSSession (success path) and never falls through to
//      the legacy fire-and-forget `onSave` when `onSaveAsync` throws
//      (failure path) -- proving the failure never masquerades as success.
//   4. NetworkService.updateSession still PUTs to /devotions/ with the
//      expected devotion_id/user_id/devotion body shape, confirming the
//      wiring targets the real, already-implemented endpoint correctly.
//
// Async Task-driven state (isSaving/saveError) is intentionally not
// re-inspected via ViewInspector after a tap -- this file's own sibling
// ChatScheduleUICleanupIOSRegressionTests.swift documents that combination
// hanging/failing against this project's ViewInspector 0.10.3 / iOS 26.5
// toolchain. Item 3 instead observes success/failure through the closures
// themselves (XCTestExpectation), which needs no re-inspection at all.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - 1. SessionDetailSheet.isHost gates Edit (and Delete) button visibility

@MainActor
final class SessionDetailSheetEditButtonGateTests: XCTestCase {

    private func makeSession(creatorId: String) -> FSSession {
        FSSession(
            id: "session-1", title: "Evening Study",
            time_start: "2026-09-14T18:00:00.000Z", time_end: "2026-09-14T18:30:00.000Z",
            verses: ["John 3:16"], prompts: ["What stood out to you?"],
            recurring: false, creator_id: creatorId
        )
    }

    func test_sessionDetailSheet_hostSession_showsEditButton() throws {
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: "host-1", username: "Host", email: "h@example.com")
        let sut = SessionDetailSheet(session: makeSession(creatorId: "host-1")).environmentObject(appState)

        XCTAssertNoThrow(try sut.inspect().find(button: "Edit Session"),
                          "the session's creator must see the new Edit affordance")
    }

    func test_sessionDetailSheet_nonHostViewer_hidesEditButton() throws {
        // The exact gap this task's acceptance criteria calls out: the edit
        // entry point must not render at all for a non-author, not merely be
        // disabled.
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: "someone-else", username: "Guest", email: "g@example.com")
        let sut = SessionDetailSheet(session: makeSession(creatorId: "host-1")).environmentObject(appState)

        XCTAssertThrowsError(try sut.inspect().find(button: "Edit Session"),
                              "a non-host viewer must not see the edit-session affordance") { _ in }
    }

    func test_sessionDetailSheet_hostSession_stillShowsDeleteButton_noRegression() throws {
        // The existing Delete affordance must survive sitting alongside the
        // new Edit button, unchanged.
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: "host-1", username: "Host", email: "h@example.com")
        let sut = SessionDetailSheet(session: makeSession(creatorId: "host-1")).environmentObject(appState)

        XCTAssertNoThrow(try sut.inspect().find(button: "Delete Session"))
    }

    func test_sessionWithEmptyCreatorId_hidesEditButton_denyByDefault() throws {
        // isHost is internal (not private, matching NoteDetailView.canEdit's
        // testability-seam convention) precisely so this can be asserted
        // directly -- but @EnvironmentObject's storage is only populated by
        // SwiftUI's own render pipeline, so it's still exercised through a
        // real .environmentObject(_:) + .inspect() render rather than a bare
        // property access, which would otherwise trip @EnvironmentObject's
        // "no ObservableObject found" fatalError outside a live host.
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: "host-1", username: "Host", email: "h@example.com")
        let sut = SessionDetailSheet(session: makeSession(creatorId: "")).environmentObject(appState)

        XCTAssertThrowsError(try sut.inspect().find(button: "Edit Session"),
                              "an undecoded/uncaptured session creator must fail closed, not be assumed to be the viewer") { _ in }
    }
}

// MARK: - 2. SessionCreatorSheet edit mode pre-fills from existingSession

@MainActor
final class SessionCreatorSheetEditModePrefillTests: XCTestCase {

    private func makeSession() -> FSSession {
        FSSession(
            id: "session-1", title: "Evening Study",
            time_start: "2026-09-14T18:00:00.000Z", time_end: "2026-09-14T18:30:00.000Z",
            verses: ["John 3:16", "Romans 8:28"], prompts: ["What stood out to you?"],
            recurring: true, creator_id: "host-1"
        )
    }

    func test_editMode_prefillsTitleVersesAndPrompts() throws {
        let sut = SessionCreatorSheet(groupId: "group-1", existingSession: makeSession())

        XCTAssertNoThrow(try sut.inspect().find(text: "Evening Study"),
                          "the title field must render the existing session's title")
        XCTAssertNoThrow(try sut.inspect().find(text: "John 3:16"),
                          "edit mode must render the existing session's verses (create mode has no verses UI at all)")
        XCTAssertNoThrow(try sut.inspect().find(text: "Romans 8:28"))
        XCTAssertNoThrow(try sut.inspect().find(text: "What stood out to you?"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Edit Session"),
                          "the sheet header must read 'Edit Session', not 'Schedule', in edit mode")
    }

    func test_createMode_hasNoVersesSectionAndUnchangedTitle() throws {
        // Regression guard: adding the edit-mode Verses section must not leak
        // into the create path.
        let sut = SessionCreatorSheet(groupId: "group-1", onSave: { _ in })

        XCTAssertNoThrow(try sut.inspect().find(text: "Schedule"))
        XCTAssertThrowsError(try sut.inspect().find(text: "Verses"),
                              "the create path must not show a Verses section") { _ in }
    }
}

// MARK: - 3. Save wiring: onSaveAsync success path, and failure never masquerades as onSave success

@MainActor
final class SessionCreatorSheetEditSaveWiringTests: XCTestCase {

    private func makeSession() -> FSSession {
        FSSession(
            id: "session-1", title: "Old Title",
            time_start: "2026-09-14T18:00:00.000Z", time_end: "2026-09-14T18:30:00.000Z",
            verses: ["John 3:16"], prompts: ["Q1"], recurring: false,
            group_id: "group-1", creator_id: "host-1", participants: ["host-1", "member-2"]
        )
    }

    private func findScheduleButton(in sut: SessionCreatorSheet) throws -> InspectableView<ViewType.Button> {
        try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string()) == "Schedule session"
        })
    }

    func test_editMode_save_invokesOnSaveAsyncWithEditedSession_preservingIdentity() throws {
        let session = makeSession()
        let exp = expectation(description: "onSaveAsync invoked")
        var received: FSSession?
        let sut = SessionCreatorSheet(groupId: "group-1", existingSession: session, onSaveAsync: { updated in
            received = updated
            exp.fulfill()
        })

        try findScheduleButton(in: sut).tap()
        wait(for: [exp], timeout: 2)

        // The full FSSession round-trips (updateSession's PUT body is the
        // whole devotion), so id/creator_id/group_id/participants must
        // survive unedited, not be reset the way a fresh create-mode
        // FSSession would be.
        XCTAssertEqual(received?.id, "session-1")
        XCTAssertEqual(received?.creator_id, "host-1")
        XCTAssertEqual(received?.group_id, "group-1")
        XCTAssertEqual(received?.participants, ["host-1", "member-2"])
        XCTAssertEqual(received?.title, "Old Title")
        XCTAssertEqual(received?.verses, ["John 3:16"])
    }

    func test_editMode_save_onSaveAsyncThrows_neverFallsThroughToOnSave() throws {
        struct DummyError: Error {}
        let exp = expectation(description: "onSaveAsync attempted")
        var onSaveCalled = false
        let sut = SessionCreatorSheet(
            groupId: "group-1",
            existingSession: makeSession(),
            onSave: { _ in onSaveCalled = true },
            onSaveAsync: { _ in
                exp.fulfill()
                throw DummyError()
            }
        )

        try findScheduleButton(in: sut).tap()
        wait(for: [exp], timeout: 2)
        // Give the do/catch its own runloop turn to complete after the throw.
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        XCTAssertFalse(onSaveCalled,
                       "a failed edit save must never fall through to the create path's success handler -- that would falsely indicate success")
    }

    // Note: an end-to-end tap-through test for the create path (title empty
    // by default -> Schedule stays disabled, exactly like before this task)
    // isn't added here -- ChatScheduleUICleanupIOSRegressionTests already
    // pins that disabled-while-empty behavior and the scheduleSession()
    // wiring at the source level, and populating `title` first would need
    // ViewInspector's TextField.setInput(_:), which that same suite's own
    // comments document as unreliable against this project's ViewInspector
    // 0.10.3 / iOS 26.5 pairing. The create branch itself is otherwise
    // provably unchanged by inspection: same field assignments, same order,
    // as the original scheduleSession() this replaced.
}

// MARK: - 4. NetworkService.updateSession still targets the real endpoint correctly

final class UpdateSessionNetworkRequestShapeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data()
    }

    func test_updateSession_sendsPUTWithDevotionIdUserIdAndDevotionBody() async throws {
        let session = FSSession(id: "session-1", title: "Updated Title", creator_id: "host-1")

        try await NetworkService.shared.updateSession(userId: "host-1", sessionId: "session-1", devotion: session)

        let putRequests = StubURLProtocol.requestLog.filter { $0.method == "PUT" }
        XCTAssertEqual(putRequests.count, 1, "editing a session must send exactly one PUT to the devotions endpoint")
        let req = try XCTUnwrap(putRequests.first)
        XCTAssertEqual(req.path, "/api/devotions")
        XCTAssertEqual(req.bodyJSON?["devotion_id"] as? String, "session-1")
        XCTAssertEqual(req.bodyJSON?["user_id"] as? String, "host-1")
        let devotion = req.bodyJSON?["devotion"] as? [String: Any]
        XCTAssertEqual(devotion?["title"] as? String, "Updated Title")
    }
}
