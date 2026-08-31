// ComplianceRemediationActionRevertRegressionTests.swift — regression
// coverage for task 20260830-compliance-remediation's iOS H6/H7 findings
// (steps 1-6 of that pipeline) that had no prior dedicated test coverage.
//
// H6/H7 applied the "do { try await ... } catch { revert optimistic
// mutation; surface a user-facing message }" shape — already used elsewhere
// in these same files (toggleAgent/renameAgent/createAgent/updateEvent,
// saveHighlight/clearHighlight) — to several call sites that previously
// either bare `try?`-swallowed the error (leaving a stale optimistic UI
// state with no revert and no signal) or unconditionally treated an
// operation as successful. This file proves each fixed call site actually
// reverts its local mutation and surfaces the real failure reason, and that
// the happy path is unaffected.
//
// Covered here (ViewModel-level, no ViewInspector needed):
//   - NotesViewModel.deleteNote (Notes/NotesListView.swift)
//   - ChatViewModel.removeFriend / leaveGroup (Chat/ChatRootView.swift)
//
// NOT covered here (residual gap, left for a follow-up UI-level test): C4
// (AccountView's delete-account confirm-before-signout) and ChatRootView's
// reportUser/blockUser are implemented directly inside a View's alert/sheet
// button closures rather than a testable ViewModel method, so exercising
// them requires a ViewInspector-driven button tap rather than a plain
// service-double test. Reviewed by direct code read instead (do/catch,
// success/failure branches correctly ordered, matches the same shape as the
// ViewModel-level sites proven below).

import XCTest
@testable import FellowScript

@MainActor
final class NotesViewModelDeleteNoteRegressionTests: XCTestCase {

    private func makeNote(id: String) -> FSNote {
        FSNote(id: id, user: "user-123", title: "T", text: "B")
    }

    /// Before the fix: `try? await service.deleteNote(...)` discarded any
    /// failure, so a note removed from a free-tier/expired-session/network
    /// error still vanished from the UI with no revert and no signal.
    func test_deleteNote_revertsOptimisticRemoval_andSurfacesError_onFailure() async {
        let vm = NotesViewModel()
        let note = makeNote(id: "note-1")
        vm.notes["note-1"] = note
        let service = ThrowingTestDataService()
        service.deleteNoteError = AppError.networkError("Session expired")
        vm.service = service

        await vm.deleteNote(id: "note-1", userId: "user-123", isOwnNote: true)

        XCTAssertEqual(vm.notes["note-1"]?.id, "note-1",
                        "the optimistically-removed note must be restored after a failed delete")
        XCTAssertEqual(vm.saveError, "Session expired",
                        "the real failure reason must be surfaced, not a silent no-op")
        XCTAssertEqual(service.deleteNoteCallCount, 1)
    }

    /// Regression guard: a successful delete still removes the note and
    /// leaves no stale error behind.
    func test_deleteNote_keepsRemoval_onSuccess() async {
        let vm = NotesViewModel()
        vm.notes["note-1"] = makeNote(id: "note-1")
        let service = ThrowingTestDataService()
        vm.service = service

        await vm.deleteNote(id: "note-1", userId: "user-123", isOwnNote: true)

        XCTAssertNil(vm.notes["note-1"])
        XCTAssertNil(vm.saveError)
        XCTAssertEqual(service.deleteNoteCallCount, 1)
    }

    /// Regression guard, pre-existing behavior unaffected by the fix: a note
    /// the caller doesn't own is never sent to the service at all.
    func test_deleteNote_notOwnNote_isNoOp_doesNotCallService() async {
        let vm = NotesViewModel()
        vm.notes["note-1"] = makeNote(id: "note-1")
        let service = ThrowingTestDataService()
        vm.service = service

        await vm.deleteNote(id: "note-1", userId: "user-123", isOwnNote: false)

        XCTAssertNotNil(vm.notes["note-1"], "a non-owned note must not be removed locally")
        XCTAssertEqual(service.deleteNoteCallCount, 0)
    }
}

@MainActor
final class ChatViewModelFriendGroupActionRegressionTests: XCTestCase {

    /// Poll for the fire-and-forget `Task {}` launched inside
    /// removeFriend/leaveGroup to complete -- both methods are intentionally
    /// synchronous (mirroring the real button-tap call sites in
    /// ChatRootView), so tests can't just `await` them directly.
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeContact(id: String, type: ContactType) -> FSContact {
        FSContact(id: id, name: "c-\(id)", type: type)
    }

    /// Before the fix: removeFriend was a bare optimistic-remove-then-`try?`
    /// no-op -- a failed removal (e.g. already-removed, expired session)
    /// left the friend permanently gone from the list with no revert and no
    /// signal to the user.
    func test_removeFriend_revertsOptimisticRemoval_andSurfacesError_onFailure() async {
        let vm = ChatViewModel()
        vm.friends = [makeContact(id: "f1", type: .friend), makeContact(id: "f2", type: .friend)]
        let service = ThrowingTestDataService()
        service.removeFriendError = AppError.networkError("Server error 500")
        vm.service = service

        vm.removeFriend(id: "f1", userId: "user-123")
        await waitUntil { vm.friendActionError != nil }

        XCTAssertEqual(Set(vm.friends.map(\.id)), ["f1", "f2"],
                        "the optimistically-removed friend must be restored after a failed removal")
        XCTAssertEqual(vm.friendActionError, "Server error 500")
    }

    func test_removeFriend_keepsRemoval_onSuccess() async {
        let vm = ChatViewModel()
        vm.friends = [makeContact(id: "f1", type: .friend), makeContact(id: "f2", type: .friend)]
        let service = ThrowingTestDataService()
        vm.service = service

        vm.removeFriend(id: "f1", userId: "user-123")
        await waitUntil { service.removeFriendCallCount == 1 }

        XCTAssertEqual(vm.friends.map(\.id), ["f2"])
        XCTAssertNil(vm.friendActionError)
    }

    /// Same class of bug, leaveGroup(): a failed leave must restore the
    /// group to the list and surface groupActionError, not silently drop it.
    func test_leaveGroup_revertsOptimisticRemoval_andSurfacesError_onFailure() async {
        let vm = ChatViewModel()
        vm.groups = [makeContact(id: "g1", type: .group)]
        let service = ThrowingTestDataService()
        service.leaveGroupError = AppError.networkError("Session expired")
        vm.service = service

        vm.leaveGroup(id: "g1", userId: "user-123")
        await waitUntil { vm.groupActionError != nil }

        XCTAssertEqual(vm.groups.map(\.id), ["g1"],
                        "the optimistically-removed group must be restored after a failed leave")
        XCTAssertEqual(vm.groupActionError, "Session expired")
    }

    func test_leaveGroup_keepsRemoval_onSuccess() async {
        let vm = ChatViewModel()
        vm.groups = [makeContact(id: "g1", type: .group)]
        let service = ThrowingTestDataService()
        vm.service = service

        vm.leaveGroup(id: "g1", userId: "user-123")
        await waitUntil { service.leaveGroupCallCount == 1 }

        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.groupActionError)
    }
}
