// AccountEventsSequentialHeartbeatsWalkRegressionTests.swift
// task 20260930-account-events-release-taskgroup-drop, testing gate.
//
// Live Release (-O) evidence: the heartbeats `withTaskGroup` walk logged
// `tasksAdded=1 resultsConsumed=0 allEventsCount=0` even though the fetch
// succeeded, so events committed empty with eventsLoaded=false. The walk in
// AccountViewModel.load() is now a plain sequential loop. These tests pin the
// behavior behaviorally (not by source text): every started fetch's result is
// consumed and lands in `events`, partial failure keeps per-agent baselines,
// cancellation never commits false-empty, and eventsLoaded semantics hold.
// Run under both Debug and `-configuration Release` (see testing.json).

import XCTest
@testable import FellowScript

@MainActor
final class AccountEventsSequentialHeartbeatsWalkRegressionTests: XCTestCase {

    private func makeUser(_ id: String) -> FSUser {
        FSUser(user_id: id, username: "alice", email: "alice@example.com")
    }

    private func agent(_ id: String, _ user: FSUser) -> FSAgent {
        FSAgent(id: id, user_id: user.user_id, name: id, role: "guide", enabled: true, chats: [])
    }

    private func hb(_ id: String, agent: String, user: FSUser) -> FSHeartbeat {
        FSHeartbeat(id: id, agent_id: agent, user_id: user.user_id, prompt: "P-\(id)")
    }

    // MARK: results consumed == fetches started

    func test_zeroAgents_noFetches_eventsEmpty_eventsLoadedTrue() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-zero")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = []
        await vm.load(service: service, user: user)
        XCTAssertEqual(service.fetchHeartbeatsCallCount, 0)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertTrue(vm.eventsLoaded, "a clean walk over zero agents proves the account has no events")
    }

    func test_oneAgent_resultConsumed_eventsLanded_eventsLoadedTrue() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-one")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("a1", user)]
        service.fetchHeartbeatsResultsByAgent["a1"] = [hb("h1", agent: "a1", user: user), hb("h2", agent: "a1", user: user)]
        await vm.load(service: service, user: user)
        XCTAssertEqual(service.fetchHeartbeatsCallCount, 1)
        XCTAssertEqual(Set(vm.events.map(\.id)), ["h1", "h2"],
                       "the live Release symptom: fetch succeeded but zero results reached events")
        XCTAssertTrue(vm.eventsLoaded)
        XCTAssertNil(vm.statsMsg)
    }

    func test_threeAgents_everyStartedFetchIsConsumed() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-three")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("a1", user), agent("a2", user), agent("a3", user)]
        service.fetchHeartbeatsResultsByAgent["a1"] = [hb("h1", agent: "a1", user: user)]
        service.fetchHeartbeatsResultsByAgent["a2"] = [hb("h2", agent: "a2", user: user), hb("h3", agent: "a2", user: user)]
        service.fetchHeartbeatsResultsByAgent["a3"] = [hb("h4", agent: "a3", user: user)]
        await vm.load(service: service, user: user)
        XCTAssertEqual(service.fetchHeartbeatsCallCount, 3)
        XCTAssertEqual(Set(service.fetchHeartbeatsCalledAgentIds), ["a1", "a2", "a3"])
        XCTAssertEqual(Set(vm.events.map(\.id)), ["h1", "h2", "h3", "h4"],
                       "results consumed must equal fetches started: all 3 agents' events land")
        XCTAssertEqual(vm.events.count, 4)
        XCTAssertTrue(vm.eventsLoaded)
    }

    func test_agentsWithEmptyHeartbeats_stillLoaded() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-empty")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("a1", user), agent("a2", user)]
        service.fetchHeartbeatsResultsByAgent["a1"] = []
        service.fetchHeartbeatsResultsByAgent["a2"] = []
        await vm.load(service: service, user: user)
        XCTAssertEqual(service.fetchHeartbeatsCallCount, 2)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertTrue(vm.eventsLoaded)
    }

    // MARK: partial failure

    func test_partialFailure_failingAgentKeepsBaseline_succeedingAgentGetsFreshEvents() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-partial")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("good", user), agent("bad", user)]
        vm.events = [hb("old-good", agent: "good", user: user), hb("old-bad", agent: "bad", user: user)]
        service.fetchHeartbeatsResultsByAgent["good"] = [hb("fresh-good", agent: "good", user: user)]
        service.fetchHeartbeatsErrorsByAgent["bad"] = AppError.networkError("boom")
        await vm.load(service: service, user: user)
        XCTAssertEqual(service.fetchHeartbeatsCallCount, 2, "a failing agent must not stop later/earlier agents' fetches")
        XCTAssertEqual(Set(vm.events.map(\.id)), ["fresh-good", "old-bad"],
                       "succeeding agent's fresh events replace its baseline; failing agent's baseline is preserved")
        XCTAssertNotNil(vm.statsMsg, "genuine failure still surfaces the banner")
        XCTAssertFalse(vm.eventsLoaded, "an incomplete walk must not assert eventsLoaded")
    }

    func test_partialFailure_failingAgentFirst_laterAgentStillFetchedAndLands() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-partial-first")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("bad", user), agent("good", user)]
        service.fetchHeartbeatsErrorsByAgent["bad"] = AppError.networkError("boom")
        service.fetchHeartbeatsResultsByAgent["good"] = [hb("g1", agent: "good", user: user)]
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.events.map(\.id), ["g1"])
        XCTAssertFalse(vm.eventsLoaded)
    }

    func test_allFail_withBaseline_baselinePreserved_notLoaded() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-allfail")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("a1", user)]
        vm.events = [hb("old", agent: "a1", user: user)]
        service.fetchHeartbeatsErrorsByAgent["a1"] = URLError(.timedOut)
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.events.map(\.id), ["old"])
        XCTAssertFalse(vm.eventsLoaded)
        XCTAssertNotNil(vm.statsMsg)
    }

    // MARK: cancellation

    func test_cancellation_preservesBaseline_noFalseEmpty_noBanner_notLoaded() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-cancel")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("a1", user), agent("a2", user)]
        vm.events = [hb("old1", agent: "a1", user: user), hb("old2", agent: "a2", user: user)]
        service.fetchHeartbeatsErrorsByAgent["a1"] = CancellationError()
        service.fetchHeartbeatsErrorsByAgent["a2"] = CancellationError()
        await vm.load(service: service, user: user)
        XCTAssertNil(vm.statsMsg, "cancellation is not a genuine failure")
        XCTAssertEqual(Set(vm.events.map(\.id)), ["old1", "old2"], "cancelled round must not commit false-empty")
        XCTAssertFalse(vm.eventsLoaded, "cancelled round proves nothing")
    }

    func test_cancellation_urlErrorCancelled_sameAsCancellationError() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-cancel-url")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("a1", user)]
        vm.events = [hb("old1", agent: "a1", user: user)]
        service.fetchHeartbeatsErrorsByAgent["a1"] = URLError(.cancelled)
        await vm.load(service: service, user: user)
        XCTAssertNil(vm.statsMsg)
        XCTAssertEqual(vm.events.map(\.id), ["old1"])
        XCTAssertFalse(vm.eventsLoaded)
    }

    func test_oneCancelled_oneSucceeds_freshLandsBaselinePreserved_notLoaded() async {
        let vm = AccountViewModel()
        let user = makeUser("seqhb-cancel-mixed")
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [agent("a1", user), agent("a2", user)]
        vm.events = [hb("old1", agent: "a1", user: user)]
        service.fetchHeartbeatsErrorsByAgent["a1"] = CancellationError()
        service.fetchHeartbeatsResultsByAgent["a2"] = [hb("new2", agent: "a2", user: user)]
        await vm.load(service: service, user: user)
        XCTAssertEqual(Set(vm.events.map(\.id)), ["old1", "new2"])
        XCTAssertFalse(vm.eventsLoaded)
        XCTAssertNil(vm.statsMsg)
    }

    // MARK: no TaskGroup in the heartbeats walk (guards reintroduction)

    func test_source_heartbeatsWalkHasNoTaskGroup() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Account/AccountViewModel.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("withTaskGroup"), "the Release-dropping TaskGroup walk must not return")
        XCTAssertFalse(code.contains("for await (agentId, result) in group"))
    }
}
