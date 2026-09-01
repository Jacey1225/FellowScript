// HeartbeatCRUDRegressionTests.swift — replacement regression coverage for
// task: 20260901-heartbeat-backend-scheduling (testing step), replacing the
// deleted HeartbeatSchedulerRegressionTests.swift.
//
// HeartbeatScheduler.swift (both `scheduleAll` and `checkAndFire`) was
// removed in full — heartbeat firing now happens entirely server-side (see
// api/backend/interactions/scheduler.py::_fire_due_heartbeats and its
// per-user-local-timezone due-detection). There is no client-side firing
// logic left to regression-test, so the old test's actual subject
// (`HeartbeatScheduler.checkAndFire`'s result-string handling) no longer
// exists.
//
// What DOES survive from that change are AccountViewModel's three heartbeat
// CRUD entry points (`createEvent`, `removeEvent`, `updateEvent`) — each of
// these used to ALSO call `HeartbeatScheduler.scheduleAll(events:)` after a
// successful server write, to keep the client's local-notification schedule
// in sync. That call is now gone (there's nothing left to reschedule
// locally), which changes these three methods' bodies. This suite proves
// the removal didn't regress their actual surviving behavior:
//   1. `createEvent` still appends the new event locally on success, and
//      still surfaces an error (without appending) on failure — exactly as
//      before, just without the extra scheduling call in between.
//   2. `removeEvent` still optimistically removes, and still reverts the
//      optimistic removal (restoring the exact previous list) and surfaces
//      an error on failure — the revert path specifically used to also call
//      `HeartbeatScheduler.scheduleAll(events:)` with the restored list,
//      so this is the most direct regression risk from the removal.
//   3. `updateEvent` still replaces the event in place on success, and still
//      leaves the list untouched (no partial update) on failure.
//
// Uses ThrowingTestDataService's addHeartbeatError/deleteHeartbeatError/
// updateHeartbeatError seams (AppStateAuthAccountTests.swift), added
// alongside this file specifically to make these three paths controllable.

import XCTest
@testable import FellowScript

@MainActor
final class HeartbeatCRUDRegressionTests: XCTestCase {

    private func makeProfile() -> FSUser {
        FSUser(user_id: MockDataService.mockUser.user_id,
               username: MockDataService.mockUser.username,
               email: MockDataService.mockUser.email)
    }

    // MARK: 1 — createEvent

    func test_createEvent_success_appendsEventLocally() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        vm.service = service

        XCTAssertTrue(vm.events.isEmpty)
        await vm.createEvent(agentId: "agent-1", prompt: "Reflect on today.", timestamps: Array(repeating: nil, count: 31))

        XCTAssertEqual(vm.events.count, 1, "a successful create must append exactly one event")
        XCTAssertEqual(vm.events.first?.agent_id, "agent-1")
        XCTAssertNil(vm.limitMsg, "no error should be surfaced on success")
    }

    func test_createEvent_failure_doesNotAppendAndSurfacesError() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.addHeartbeatError = URLError(.badServerResponse)
        vm.service = service

        await vm.createEvent(agentId: "agent-1", prompt: "Reflect on today.", timestamps: Array(repeating: nil, count: 31))

        XCTAssertTrue(vm.events.isEmpty, "a failed create must not append the event")
        XCTAssertNotNil(vm.limitMsg, "a failed create must surface an error message")
    }

    // MARK: 2 — removeEvent (the revert path is the most direct regression
    // risk: it used to also call HeartbeatScheduler.scheduleAll(events:)
    // with the restored list after reverting)

    func test_removeEvent_success_removesOptimisticallyAndStaysRemoved() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        vm.service = service

        let event = FSHeartbeat(id: "hb-1", agent_id: "agent-1", user_id: vm.profileData!.user_id,
                                 timestamps: Array(repeating: nil, count: 31), prompt: "Reflect.")
        vm.events = [event]

        vm.removeEvent(event)
        // removeEvent's server call runs in a detached Task; the optimistic
        // removal itself is synchronous.
        XCTAssertTrue(vm.events.isEmpty, "the event must be optimistically removed immediately")

        // Let the in-flight Task's success path run to completion.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(vm.events.isEmpty, "a successful delete must leave the event removed")
        XCTAssertNil(vm.agentMsg, "no error should be surfaced on a successful delete")
    }

    func test_removeEvent_failure_revertsOptimisticRemovalAndSurfacesError() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.deleteHeartbeatError = URLError(.badServerResponse)
        vm.service = service

        let event = FSHeartbeat(id: "hb-1", agent_id: "agent-1", user_id: vm.profileData!.user_id,
                                 timestamps: Array(repeating: nil, count: 31), prompt: "Reflect.")
        vm.events = [event]

        vm.removeEvent(event)
        XCTAssertTrue(vm.events.isEmpty, "the event is optimistically removed immediately, before the server call resolves")

        // Let the in-flight Task's failure/revert path run to completion.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.events.count, 1, "a failed delete must revert the optimistic removal — the event must reappear")
        XCTAssertEqual(vm.events.first?.id, event.id)
        XCTAssertNotNil(vm.agentMsg, "a failed delete must surface an error message")
    }

    // MARK: 3 — updateEvent

    func test_updateEvent_success_replacesEventInPlace() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        vm.service = service

        let original = FSHeartbeat(id: "hb-1", agent_id: "agent-1", user_id: vm.profileData!.user_id,
                                    timestamps: Array(repeating: nil, count: 31), prompt: "Old prompt.")
        vm.events = [original]

        var newTimestamps: [String?] = Array(repeating: nil, count: 31)
        newTimestamps[0] = "09:00"
        await vm.updateEvent(original, agentId: "agent-1", prompt: "New prompt.", timestamps: newTimestamps)

        XCTAssertEqual(vm.events.count, 1, "update must not add or remove events, only replace")
        XCTAssertEqual(vm.events.first?.prompt, "New prompt.")
        XCTAssertEqual(vm.events.first?.timestamps[0], "09:00")
        XCTAssertNil(vm.agentMsg, "no error should be surfaced on a successful update")
    }

    func test_updateEvent_failure_leavesOriginalEventUntouched() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        service.updateHeartbeatError = URLError(.badServerResponse)
        vm.service = service

        let original = FSHeartbeat(id: "hb-1", agent_id: "agent-1", user_id: vm.profileData!.user_id,
                                    timestamps: Array(repeating: nil, count: 31), prompt: "Old prompt.")
        vm.events = [original]

        await vm.updateEvent(original, agentId: "agent-1", prompt: "New prompt.", timestamps: Array(repeating: nil, count: 31))

        XCTAssertEqual(vm.events.count, 1)
        XCTAssertEqual(vm.events.first?.prompt, "Old prompt.",
                        "a failed update must leave the pre-existing event untouched, not partially applied")
        XCTAssertNotNil(vm.agentMsg, "a failed update must surface an error message")
    }
}
