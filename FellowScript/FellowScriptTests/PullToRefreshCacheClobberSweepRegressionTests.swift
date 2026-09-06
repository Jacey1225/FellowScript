// PullToRefreshCacheClobberSweepRegressionTests.swift — testing-gate
// coverage for task 20260905-pull-to-refresh-cache-clobber (Lightweight
// spec, frontend gate already passed; this is the standard follow-on
// testing step per the intake spec's "Whether any test infrastructure
// already exists..." open question).
//
// This is the same bug class already regression-tested twice in this repo
// (DashboardStaleReloadRegressionTests.swift for DashboardViewModel.load(),
// NotesGroupRefreshNullDataRegressionTests.swift for
// NotesViewModel.fetchAndCache) — a `try?`-collapsed fetch failure defaults
// to []/0/nil and then gets written UNCONDITIONALLY over already-good
// cached/displayed state, wiping it to empty on any transient failure
// instead of leaving it intact. This file proves the frontend gate's fix of
// the three remaining call sites the intake audit found:
//
//   1. ChatViewModel.fetchAndCache (Chat/ChatRootView.swift) — friends/
//      groups (from fetchContacts) and agents (from fetchAgents) are two
//      independent fetches; a failure in one must not wipe the other's data.
//   2. AccountViewModel.load() (Account/AccountViewModel.swift) — agents/
//      noteCount/highlightCount/friendRequests/events are five independent
//      fetches (of 7 total, per-agent heartbeats included) sharing one
//      statsFailed flag; a failure in any one must not wipe the others, and
//      must still surface statsMsg.
//   3. AccountViewModel.loadSubscription() — a failed fetchUserSubscription
//      must leave subscription/autoRenewOff/planEndDate untouched (not null
//      them out), while a genuinely successful fetch (even one resolving to
//      "no active subscription") must still update them.
//   4. BlockedUsersView.load() (Account/BlockedUsersView.swift) — a failed
//      fetchBlockedUsers must leave the on-screen list untouched.
//
// Uses the shared ThrowingTestDataService double (AppStateAuthAccountTests.swift),
// extended in this pass with fetchFriendRequestsResult/Error,
// fetchUserSubscriptionError, and fetchBlockedUsersResult/Error seams
// (mirroring that double's existing per-fetch override convention) since
// none of the three existed before this task needed to independently drive
// AND observe those specific calls.
//
// BlockedUsersView has no separate view-model class (load() is a `private`
// method on the View struct itself, and `blocked` is `@State` local to it) —
// this file adds the same minimal, behaviorally-inert ViewInspector
// "Approach #2" test hook (`internal let inspection = Inspection<Self>()`,
// `#if DEBUG`-gated) that NoteDetailView already carries for the identical
// reason (observing @State that settles after a real async gap, which a
// plain post-host `.inspect()` can't reliably do), then drives a real
// pull-to-refresh via ViewInspector's `callRefreshable()` against the
// view's actual `.refreshable` modifier — not a bespoke stand-in.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - 1. ChatViewModel.fetchAndCache — independent-fetch preserve-on-failure

@MainActor
final class ChatViewModelCacheClobberRegressionTests: XCTestCase {

    private func freshUserId() -> String { "chat-cache-clobber-\(UUID().uuidString)" }

    func test_refresh_fetchContactsFails_leavesFriendsAndGroupsInPlace_agentsStillUpdatesIndependently() async {
        let vm = ChatViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        await vm.load(service: service, userId: userId)
        XCTAssertEqual(vm.friends.count, 2, "sanity check: the first load must populate friends from the mock fixture")
        XCTAssertEqual(vm.groups.count, 1, "sanity check: the first load must populate groups from the mock fixture")

        service.fetchContactsError = AppError.networkError("simulated contacts failure")
        service.fetchAgentsResult = [FSAgent(id: "agent-002", user_id: userId, role: "a fresh role", enabled: true, chats: [])]
        await vm.refresh(service: service, userId: userId)

        XCTAssertEqual(vm.friends.count, 2,
                       "a failed fetchContacts must not wipe the already-good friends list to empty")
        XCTAssertEqual(vm.groups.count, 1,
                       "a failed fetchContacts must not wipe the already-good groups list to empty")
        XCTAssertEqual(vm.agents.first?.id, "agent-002",
                       "fetchAgents' own success must still land independently of fetchContacts' failure")
        XCTAssertFalse(vm.isLoading, "refresh() must still complete (not hang) when fetchContacts fails")
    }

    func test_refresh_fetchAgentsFails_leavesAgentsInPlace_friendsAndGroupsStillUpdateIndependently() async {
        let vm = ChatViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        await vm.load(service: service, userId: userId)
        XCTAssertEqual(vm.agents.count, 1, "sanity check: the first load must populate agents from the mock fixture")
        let friendsAfterLoad = vm.friends.count
        let groupsAfterLoad = vm.groups.count

        service.fetchAgentsError = AppError.networkError("simulated agents failure")
        await vm.refresh(service: service, userId: userId)

        XCTAssertEqual(vm.agents.count, 1,
                       "a failed fetchAgents must not wipe the already-good agents list to empty — this is the exact regression: before the fix, `try?` collapsed the failure to [] and overwrote it unconditionally")
        XCTAssertEqual(vm.friends.count, friendsAfterLoad,
                       "fetchContacts' own success must still land independently of fetchAgents' failure")
        XCTAssertEqual(vm.groups.count, groupsAfterLoad)
        XCTAssertGreaterThan(service.fetchContactsCallCount, 1, "fetchContacts must have actually been re-invoked by refresh(), not skipped")
        XCTAssertFalse(vm.isLoading, "refresh() must still complete (not hang) when fetchAgents fails")
    }
}

// MARK: - 2. AccountViewModel.load() — independent-fetch preserve-on-failure

@MainActor
final class AccountViewModelLoadCacheClobberRegressionTests: XCTestCase {

    private func freshUser(_ label: String) -> FSUser {
        FSUser(user_id: "acct-cache-clobber-\(label)-\(UUID().uuidString)", username: "user-\(label)", email: "\(label)@example.com")
    }

    // MARK: 2a — a failed fetchAgents leaves agents (and events, since there's
    // no agent list left to walk heartbeats for) untouched, while the other
    // independent fetches in the same load() call still succeed.

    func test_load_fetchAgentsFails_leavesAgentsAndEventsInPlace_othersStillUpdate() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("agents")

        service.fetchAgentsResult = [FSAgent(id: "agent-a", user_id: user.user_id, role: "r", enabled: true, chats: [])]
        service.fetchHeartbeatsResultsByAgent["agent-a"] = [FSHeartbeat(id: "hb-a1", agent_id: "agent-a", user_id: user.user_id, prompt: "p1")]
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.agents.map(\.id), ["agent-a"], "sanity check: the first load must populate agents")
        XCTAssertEqual(vm.events.map(\.id), ["hb-a1"], "sanity check: the first load must populate events")
        XCTAssertNil(vm.statsMsg, "sanity check: a fully successful load must not surface statsMsg")

        service.fetchAgentsError = AppError.networkError("simulated agents failure")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.agents.map(\.id), ["agent-a"],
                       "a failed fetchAgents must not wipe the already-displayed agents list to empty")
        XCTAssertEqual(vm.events.map(\.id), ["hb-a1"],
                       "when fetchAgents itself fails there's no agent list to walk heartbeats for -- events must be left entirely untouched, not collapsed to an empty accumulator")
        XCTAssertGreaterThan(service.fetchNotesCountCallCount, 0, "fetchNotesCount must have still run, independent of fetchAgents' failure")
        XCTAssertGreaterThan(service.fetchHighlightsCallCount, 0, "fetchHighlights must have still run, independent of fetchAgents' failure")
        XCTAssertNotNil(vm.statsMsg, "a genuine fetch failure must surface statsMsg, not be silently swallowed")
        XCTAssertFalse(vm.isLoading, "load() must still complete (not hang) when fetchAgents fails")
    }

    // MARK: 2b — a failed fetchNotesCount leaves noteCount untouched

    func test_load_fetchNotesCountFails_leavesNoteCountInPlace_othersStillUpdate() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("notecount")

        await vm.load(service: service, user: user)
        let noteCountAfterLoad = vm.noteCount
        XCTAssertGreaterThan(noteCountAfterLoad, 0, "sanity check: the mock fixture has at least one note")

        service.fetchNotesCountError = AppError.networkError("simulated notes-count failure")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.noteCount, noteCountAfterLoad,
                       "a failed fetchNotesCount must leave the already-displayed count untouched, not reset it to 0")
        XCTAssertFalse(vm.agents.isEmpty, "fetchAgents' own success must be unaffected by fetchNotesCount's failure")
        XCTAssertNotNil(vm.statsMsg)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: 2c — a failed fetchHighlights leaves highlightCount untouched

    func test_load_fetchHighlightsFails_leavesHighlightCountInPlace_othersStillUpdate() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("highlights")

        await vm.load(service: service, user: user)
        let highlightCountAfterLoad = vm.highlightCount
        XCTAssertGreaterThan(highlightCountAfterLoad, 0, "sanity check: the mock fixture has at least one highlight")

        service.fetchHighlightsError = AppError.networkError("simulated highlights failure")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.highlightCount, highlightCountAfterLoad,
                       "a failed fetchHighlights must leave the already-displayed count untouched, not reset it to 0")
        XCTAssertFalse(vm.agents.isEmpty, "fetchAgents' own success must be unaffected by fetchHighlights' failure")
        XCTAssertNotNil(vm.statsMsg)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: 2d — a failed fetchFriendRequests leaves friendRequests untouched
    // (uses a seeded non-empty baseline so "untouched" is distinguishable
    // from "still empty either way")

    func test_load_fetchFriendRequestsFails_leavesFriendRequestsInPlace_othersStillUpdate() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("friendreqs")

        service.fetchFriendRequestsResult = [(id: "req-1", username: "charlie", profile_photo_url: nil)]
        await vm.load(service: service, user: user)
        XCTAssertEqual(vm.friendRequests.count, 1, "sanity check: the first load must populate friendRequests")

        service.fetchFriendRequestsResult = nil
        service.fetchFriendRequestsError = AppError.networkError("simulated friend-requests failure")
        await vm.load(service: service, user: user)

        XCTAssertEqual(vm.friendRequests.count, 1,
                       "a failed fetchFriendRequests must not wipe the already-displayed friend requests to empty")
        XCTAssertFalse(vm.agents.isEmpty, "fetchAgents' own success must be unaffected by fetchFriendRequests' failure")
        XCTAssertNotNil(vm.statsMsg)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: 2e — per-agent heartbeat failure: one agent's OWN fetchHeartbeats
    // fails and falls back to its previously-known events, while another
    // agent's own successful refresh still fully converges to fresh data.

    func test_load_oneAgentsHeartbeatsFetchFails_fallsBackToItsOwnPriorEvents_otherAgentStillConverges() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        let user = freshUser("heartbeats")
        let agentA = FSAgent(id: "agent-a", user_id: user.user_id, role: "r", enabled: true, chats: [])
        let agentB = FSAgent(id: "agent-b", user_id: user.user_id, role: "r", enabled: true, chats: [])
        service.fetchAgentsResult = [agentA, agentB]

        service.fetchHeartbeatsResultsByAgent["agent-a"] = [FSHeartbeat(id: "hb-a1", agent_id: "agent-a", user_id: user.user_id, prompt: "p1")]
        service.fetchHeartbeatsResultsByAgent["agent-b"] = [FSHeartbeat(id: "hb-b1", agent_id: "agent-b", user_id: user.user_id, prompt: "p1")]
        await vm.load(service: service, user: user)
        XCTAssertEqual(Set(vm.events.map(\.id)), ["hb-a1", "hb-b1"], "sanity check: the first load must populate both agents' events")

        service.fetchHeartbeatsErrorsByAgent["agent-a"] = AppError.networkError("simulated heartbeats failure")
        service.fetchHeartbeatsResultsByAgent["agent-b"] = [FSHeartbeat(id: "hb-b2", agent_id: "agent-b", user_id: user.user_id, prompt: "p2")]
        await vm.load(service: service, user: user)

        XCTAssertTrue(vm.events.contains(where: { $0.id == "hb-a1" }),
                      "agent-a's own failed heartbeats fetch must fall back to its previously-known events, not drop them")
        XCTAssertTrue(vm.events.contains(where: { $0.id == "hb-b2" }),
                      "agent-b's own successful refresh must still fully replace its stale event")
        XCTAssertFalse(vm.events.contains(where: { $0.id == "hb-b1" }),
                       "agent-b's stale event must be replaced by its fresh one, proving this fix doesn't prevent convergence for agents whose heartbeats fetch DID succeed")
        XCTAssertNotNil(vm.statsMsg, "a genuine per-agent heartbeats failure must surface statsMsg")
        XCTAssertFalse(vm.isLoading)
    }
}

// MARK: - 3. AccountViewModel.loadSubscription() — preserve-on-failure, converge-on-success

@MainActor
final class AccountViewModelLoadSubscriptionCacheClobberRegressionTests: XCTestCase {

    func test_loadSubscription_fetchFails_leavesSubscriptionAndDerivedStateInPlace() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        let uid = "sub-cache-clobber-\(UUID().uuidString)"
        let existingPlan = FSSubscription(id: "plan-1", user_id: uid, plan_type: "group", status: "active", price_cents: 999, max_members: 5)
        vm.subscription = existingPlan
        vm.autoRenewOff = true
        vm.planEndDate = Date(timeIntervalSince1970: 1_000)

        service.fetchUserSubscriptionError = AppError.networkError("simulated subscription failure")
        await vm.loadSubscription(userId: uid)

        XCTAssertEqual(vm.subscription?.id, "plan-1",
                       "a failed fetchUserSubscription must leave the previously-shown subscription untouched, not null it out")
        XCTAssertTrue(vm.autoRenewOff, "autoRenewOff must not be reset when the fetch itself failed")
        XCTAssertEqual(vm.planEndDate, Date(timeIntervalSince1970: 1_000), "planEndDate must not be reset when the fetch itself failed")
        XCTAssertNotNil(vm.subMsg, "a failed subscription fetch must surface an error message")
        XCTAssertFalse(vm.subLoading, "loadSubscription() must still complete (not hang) on failure")
    }

    func test_loadSubscription_genuineNoActiveSubscriptionSuccess_stillUpdates_notStuckStale() async {
        let vm = AccountViewModel()
        let service = ThrowingTestDataService()
        vm.service = service
        let uid = "sub-cache-clobber-\(UUID().uuidString)"
        // A stale plan with no provider set (so the Apple-reconciliation
        // StoreKit branch is skipped) that a genuinely successful fetch
        // resolving to "no active subscription" (MockDataService's own
        // default) must still be allowed to clear.
        vm.subscription = FSSubscription(id: "stale-plan", user_id: uid, plan_type: "group", status: "active", price_cents: 500, max_members: 3)

        await vm.loadSubscription(userId: uid)

        XCTAssertNil(vm.subscription,
                     "a genuinely successful fetch (even one resolving to 'no active subscription') must still update subscription, not leave a stale value stuck forever")
        XCTAssertNil(vm.subMsg, "a successful fetch must not surface the failure message")
        XCTAssertFalse(vm.subLoading)
    }
}

// MARK: - 4. BlockedUsersView.load() — preserve-on-failure, converge-on-success

final class BlockedUsersViewCacheClobberRegressionTests: XCTestCase {

    @MainActor
    func test_refresh_failedFetchBlockedUsers_leavesListIntact() throws {
        let service = ThrowingTestDataService()
        service.fetchBlockedUsersResult = [
            FSBlockedUser(user_id: "u1", username: "Alice"),
            FSBlockedUser(user_id: "u2", username: "Bob"),
        ]
        let sut = BlockedUsersView(userId: "blocked-cache-clobber-\(UUID().uuidString)", service: service)

        let expInitial = sut.inspection.inspect(after: 0.5) { view in
            let list = try view.find(ViewType.List.self)
            XCTAssertNoThrow(try list.find(text: "Alice"), "sanity check: the initial load must populate the list")
            XCTAssertNoThrow(try list.find(text: "Bob"))

            // Arm the NEXT fetch (the one pull-to-refresh will trigger) to
            // fail, then drive the view's real .refreshable closure.
            service.fetchBlockedUsersResult = nil
            service.fetchBlockedUsersError = AppError.networkError("simulated blocked-users failure")
            try await list.callRefreshable()
        }
        let expAfterRefresh = sut.inspection.inspect(after: 1.3) { view in
            let list = try view.find(ViewType.List.self)
            XCTAssertNoThrow(try list.find(text: "Alice"),
                             "a failed fetchBlockedUsers on refresh must leave the already-displayed blocked list intact, not empty it")
            XCTAssertNoThrow(try list.find(text: "Bob"))
            XCTAssertEqual(service.fetchBlockedUsersCallCount, 2, "the refresh must have actually re-invoked fetchBlockedUsers, not been skipped")
        }

        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [expInitial, expAfterRefresh], timeout: 4)
    }

    @MainActor
    func test_refresh_genuineEmptySuccess_stillClearsList_notStuckStale() throws {
        let service = ThrowingTestDataService()
        service.fetchBlockedUsersResult = [FSBlockedUser(user_id: "u1", username: "Alice")]
        let sut = BlockedUsersView(userId: "blocked-cache-clobber-\(UUID().uuidString)", service: service)

        let expInitial = sut.inspection.inspect(after: 0.5) { view in
            let list = try view.find(ViewType.List.self)
            XCTAssertNoThrow(try list.find(text: "Alice"), "sanity check: the initial load must populate the list")

            // A genuinely successful refresh resolving to an empty list (a
            // real unblock elsewhere) must still be allowed to clear it.
            service.fetchBlockedUsersResult = []
            try await list.callRefreshable()
        }
        let expAfterRefresh = sut.inspection.inspect(after: 1.3) { view in
            XCTAssertThrowsError(try view.find(ViewType.List.self),
                                  "a genuinely empty successful refresh must actually clear the list into the empty state, proving the fix doesn't make stale data permanently sticky") { _ in }
            XCTAssertNoThrow(try view.find(text: "You haven't blocked anyone."))
        }

        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [expInitial, expAfterRefresh], timeout: 4)
    }
}
