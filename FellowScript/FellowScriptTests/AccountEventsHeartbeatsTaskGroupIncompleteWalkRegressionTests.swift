// AccountEventsHeartbeatsTaskGroupIncompleteWalkRegressionTests.swift —
// testing-gate coverage for task 20260910-account-events-refresh-regression's
// fifth frontend re-entry (live Release/-O device-capture bisection).
//
// Mechanism (see frontend.json's summary and
// .claude/pipeline/20260910-account-events-refresh-regression/device-capture/
// for the live evidence): AccountViewModel.load()'s per-agent heartbeats
// `withTaskGroup` genuinely fetches and decodes each agent's heartbeats
// successfully (NetworkService's own decode-success log fires, with the
// correct count, confirmed against the real 6,877-byte production payload)
// but, ONLY under Release (-O) compilation, the completed child task's result
// never reaches the `for await (agentId, result) in group` consuming loop —
// live capture showed tasksAdded=1, resultsConsumed=0 across multiple
// reproductions. The fix makes AccountViewModel.load() count
// `heartbeatsTasksAdded` (once per `group.addTask`) and
// `heartbeatsResultsConsumed` (once per `for await` iteration) and, if a
// round ever finishes with fewer results consumed than tasks added, treats
// that exactly like any other incomplete/failed walk: `events` is left
// untouched (never overwritten with an unproven/partial `allEvents`) and
// `eventsLoaded` stays false (so the UI falls through to the existing
// "haven't loaded yet, pull to refresh" branch instead of asserting
// confirmed-empty).
//
// WHY THIS FILE IS SOURCE-STRUCTURAL, NOT A RUNTIME REPRODUCTION: Swift's
// structured-concurrency contract for `withTaskGroup` guarantees that a
// manual `for await` loop which runs to exhaustion (as this one does) always
// consumes exactly one result per `group.addTask` call — reviewed the
// DataServiceProtocol/ThrowingTestDataService surface used by every other
// AccountViewModel regression test in this target and confirmed there is no
// way to force `resultsConsumed < tasksAdded` through it (a per-agent
// failure or cancellation still produces a `.failure` result that IS
// consumed by the loop; it does not skip an iteration). Frontend's own
// investigation required an actual local Release (-O) build plus live device
// capture to reproduce this at all — XCTest, like the Debug baseline
// frontend also tested, runs the loop to completion every time. Rather than
// assert a false claim of live-equivalent runtime reproduction (this bug
// family's own established honesty standard — see this task's other gates'
// "verified_live_vs_synthetic" fields), this file pins the fix's SOURCE
// contract instead, the same convention this codebase already uses for
// AccountEventsSectionNotYetLoadedBranchRegressionTests /
// AccountEventsSectionLoadingBranchRegressionTests for view-branch ordering
// that's similarly impractical to force purely at runtime. Each assertion
// here was hand-verified to fail when the specific guard it pins is reverted
// (see testing.json for the revert-and-rerun record) and to pass again once
// restored.

import XCTest
@testable import FellowScript

final class AccountEventsHeartbeatsTaskGroupIncompleteWalkRegressionTests: XCTestCase {

    private func accountViewModelSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Account/AccountViewModel.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Sanity: the accounting this whole fix depends on must actually be
    /// wired around the TaskGroup — one increment per `addTask`, one per
    /// `for await` iteration (regardless of which Result case it is).
    func test_load_heartbeatsTaskGroup_countsTasksAddedAndResultsConsumed() throws {
        let source = try accountViewModelSource()
        guard let addTaskRange = source.range(of: "for agent in agentsResult {"),
              let forAwaitRange = source.range(of: "for await (agentId, result) in group {") else {
            XCTFail("could not locate the heartbeats TaskGroup's add/consume loops")
            return
        }
        let addTaskBlockEnd = source[addTaskRange.upperBound...].range(of: "group.addTask {")
        XCTAssertNotNil(addTaskBlockEnd, "group.addTask must still follow the per-agent loop")

        let beforeAddTask = source[addTaskRange.upperBound..<(addTaskBlockEnd?.lowerBound ?? forAwaitRange.lowerBound)]
        XCTAssertTrue(beforeAddTask.contains("heartbeatsTasksAdded += 1"),
                      "THE FIX: every group.addTask call for an agent's heartbeats fetch must increment heartbeatsTasksAdded")

        let afterForAwait = source[forAwaitRange.upperBound...]
        guard let switchRange = afterForAwait.range(of: "switch result {") else {
            XCTFail("could not locate the per-result switch inside the consuming loop"); return
        }
        let betweenForAwaitAndSwitch = afterForAwait[afterForAwait.startIndex..<switchRange.lowerBound]
        XCTAssertTrue(betweenForAwaitAndSwitch.contains("heartbeatsResultsConsumed += 1"),
                      "THE FIX: every `for await` iteration (success or failure) must increment heartbeatsResultsConsumed, unconditionally, before branching on the result")
    }

    /// THE BUG this fix closes: a round where fewer results were consumed
    /// than tasks were added must not let `events` commit from that round's
    /// (silently incomplete) `allEvents` — live capture proved this can
    /// happen with a genuinely-successful fetch simply never reaching the
    /// append.
    func test_load_incompleteHeartbeatsWalk_doesNotOverwriteEvents() throws {
        let source = try accountViewModelSource()
        XCTAssertTrue(
            source.contains("if eventsUsable && heartbeatsResultsConsumed >= heartbeatsTasksAdded { events = allEvents }"),
            "THE FIX: `events` must only commit from a heartbeats walk that consumed every added task's result — reverting this guard back to `if eventsUsable { events = allEvents }` reproduces the live symptom (tasksAdded=1, resultsConsumed=0 confirmed in device-capture logs), where a genuinely successful fetch that never reached the consuming loop's append silently commits an empty `allEvents` over a real cached baseline"
        )
    }

    /// The other half of the fix: an incomplete walk must also prevent
    /// `eventsLoaded` from being asserted true, so the UI doesn't tell the
    /// user "No events yet" (confirmed-empty) off an unproven round.
    func test_load_incompleteHeartbeatsWalk_marksWalkFailed_soEventsLoadedCannotBeAsserted() throws {
        let source = try accountViewModelSource()
        guard let taskGroupEnd = source.range(of: "RefreshDiagnostics.taskGroupOutcome(") else {
            XCTFail("could not locate the post-TaskGroup diagnostic emission this guard must follow"); return
        }
        let afterDiagnostic = source[taskGroupEnd.upperBound...]
        guard let mismatchGuard = afterDiagnostic.range(of: "if heartbeatsResultsConsumed < heartbeatsTasksAdded {") else {
            XCTFail("THE FIX: the walk-failed guard for an incomplete TaskGroup consume must exist after the diagnostic emission")
            return
        }
        let guardBody = afterDiagnostic[mismatchGuard.upperBound...].prefix(200)
        XCTAssertTrue(guardBody.contains("heartbeatsWalkFailed = true"),
                      "THE FIX: an incomplete walk (resultsConsumed < tasksAdded) must set heartbeatsWalkFailed so eventsLoaded's existing `eventsUsable && !heartbeatsWalkFailed` gate stays false, matching every other incomplete-walk case in this method")

        // eventsLoaded's gate itself is pre-existing (from
        // 20260910-refresh-clobber-live-rootcause) but must still be present
        // and must run after this fix's own mismatch guard has a chance to
        // set heartbeatsWalkFailed, not before it.
        guard let eventsLoadedGate = source.range(of: "if eventsUsable && !heartbeatsWalkFailed { eventsLoaded = true }") else {
            XCTFail("eventsLoaded's existing walk-failed gate must still exist, unweakened")
            return
        }
        XCTAssertTrue(mismatchGuard.lowerBound < eventsLoadedGate.lowerBound,
                      "the incomplete-walk mismatch guard must run before eventsLoaded is evaluated, or a Release-only incomplete walk could still be asserted as loaded")
    }

    /// Both counters must be reset to zero at the top of every load() round
    /// — a stale nonzero count carried over from nothing would either falsely
    /// trip or falsely clear the guard for an account with zero agents.
    func test_load_heartbeatsTaskGroupCounters_startAtZeroEachRound() throws {
        let source = try accountViewModelSource()
        guard let declRange = source.range(of: "var heartbeatsTasksAdded = 0"),
              let declRange2 = source.range(of: "var heartbeatsResultsConsumed = 0") else {
            XCTFail("THE FIX: both counters must be freshly declared (and thus reset to 0) inside load(), not hoisted to shared/instance state that could leak across rounds")
            return
        }
        _ = declRange; _ = declRange2
    }
}
