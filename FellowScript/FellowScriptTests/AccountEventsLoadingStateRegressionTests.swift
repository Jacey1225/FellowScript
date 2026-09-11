// AccountEventsLoadingStateRegressionTests.swift — testing-gate coverage for
// task 20260910-account-events-refresh-regression, step 5 (testing),
// covering the frontend gate's re-entry fix to AccountView+Events.swift's
// eventsSection.
//
// Root cause (frontend gate, this task's re-entry after testing's step 6
// bounce): AccountViewModel.load() is a single all-or-nothing round -- it
// commits nothing to `agents`/`events` until every one of its 7 concurrent
// fetches AND the per-agent heartbeats TaskGroup has resolved, gated by one
// `generation`-guarded commit point at the very end. AccountView's own
// `.task`/`.refreshable` deliberately never gate this screen's body on
// `vm.isLoading` (correct, so a refresh never blanks already-shown content),
// but eventsSection had only ONE empty-state branch (`if vm.events.isEmpty`)
// shared between two genuinely different situations -- "load() hasn't
// finished this round yet" and "load() finished and this account really has
// zero events" -- both rendering the identical "No events yet" copy with no
// loading affordance. A user who checked (or force-quit) before a round
// finished saw the confirmed-empty copy every time, even though the round
// was still in flight and would have succeeded. The fix: eventsSection now
// branches three ways -- `vm.events.isEmpty && vm.isLoading` shows a
// "Loading your events…" row; `vm.events.isEmpty` alone (unchanged) is the
// genuinely-empty case; the populated ForEach branch is untouched.
//
// Two levels of coverage, since eventsSection is a computed extension
// property on AccountView -- a large, environment-dependent root view with
// no existing ViewInspector seam. AccountViewBaselineComponentTests.swift's
// own header comment already draws this exact coverage line: only the
// self-contained, stateless row/component types (StatBox, EventRow) get
// direct ViewInspector coverage, not the sections themselves.
//
//   1. AccountViewModel-level (dynamic, against the real ViewModel, not a
//      source read): proves the actual race window the fix depends on is
//      real and reachable -- during a genuine in-flight load() call,
//      vm.isLoading == true and vm.events.isEmpty == true simultaneously,
//      before any commit has happened, even though the account genuinely
//      has an event that will land once the round finishes -- and that it
//      resolves correctly once load() completes.
//   2. Source-structural: proves AccountView+Events.swift's eventsSection
//      actually has the three-way branch this fix added, in the right
//      order, with the right copy -- mirrors AttachmentLightboxTests.swift's
//      established source-read convention (lightboxViewSource()) for a view
//      branch that can't be independently instantiated/rendered in
//      isolation. Confirmed by hand that reverting eventsSection to the
//      pre-fix plain two-way `if vm.events.isEmpty { ... } else { ForEach
//      ... } ` branch fails every test in part 2 immediately (no
//      `vm.isLoading` reference, no loading copy/branch to find).
//
// The previously-flagged-but-unverified fetchHeartbeats decode-failure-
// throws and refreshError-banner gaps (spec scope item, Q19-20) are NOT
// re-covered here -- they're already closed by
// AccountEventsDecodeFailureRegressionTests.swift
// (test_fetchHeartbeats_genuinelyMalformedShape_decodeFails_throwsAndFiresBeacon,
// test_load_genuineHeartbeatsFailure_alertCopyMentionsEvents), which this
// task's own investigation (backend step 1, frontend step 2/3) confirmed is
// still valid and unrelated to the actual root cause found here.

import XCTest
@testable import FellowScript

// MARK: - 1. AccountViewModel: the race window itself is real

@MainActor
final class AccountEventsLoadingStateViewModelTests: XCTestCase {

    private func makeUser(_ id: String) -> FSUser {
        FSUser(user_id: id, username: "alice", email: "alice@example.com")
    }

    /// The exact precondition AccountView+Events.swift's fix branches on:
    /// mid-flight, before load()'s single generation-guarded commit point,
    /// vm.isLoading is true AND vm.events is still empty (nothing committed
    /// yet) even though the account genuinely has an event that will land
    /// once the round finishes. Before the fix this window rendered "No
    /// events yet" (a false negative); this proves the window itself is
    /// real and reachable, independent of the view.
    func test_midFlightLoad_isLoadingTrueAndEventsEmpty_beforeAnyCommit() async throws {
        let vm = AccountViewModel()
        let user = makeUser("account-events-loading-race-user-1")
        let service = ThrowingTestDataService()
        let agent = FSAgent(id: "agent-1", user_id: user.user_id, name: "Guide", role: "guide", enabled: true, chats: [])
        service.fetchAgentsResult = [agent]
        service.fetchAgentsDelayNanoseconds = 300_000_000
        service.fetchHeartbeatsResultsByAgent["agent-1"] = [
            FSHeartbeat(id: "hb-real", agent_id: "agent-1", user_id: user.user_id,
                        timestamps: Array(repeating: "09:00", count: 31), prompt: "Reflect on grace.", group_id: nil)
        ]
        service.fetchHeartbeatsDelayNanoseconds = 300_000_000

        // AccountViewModel.isLoading defaults to `true` at declaration (matches
        // BlockedUsersView's identical `@State private var isLoading = true`
        // convention) -- correct, since a freshly-created view model hasn't run
        // its first `.task`-driven load() yet either. The interesting sanity
        // check here is events, not isLoading.
        XCTAssertTrue(vm.events.isEmpty, "sanity check: a fresh view model must start with no events")

        let loadTask = Task { await vm.load(service: service, user: user) }
        // Give load() time to set isLoading, bump loadGeneration, and begin
        // its delayed fetches, but nowhere near enough time for either
        // 300ms-delayed fetch (let alone both -- fetchAgents must resolve
        // before the per-agent heartbeats TaskGroup can even start) to have
        // resolved.
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(vm.isLoading,
                      "THE RACE: mid-flight, isLoading must still be true -- this is exactly the condition AccountView+Events.swift's fix checks before deciding whether to show a loading row instead of asserting emptiness")
        XCTAssertTrue(vm.events.isEmpty,
                      "THE RACE: mid-flight, events must still be empty -- load()'s single generation-guarded commit point hasn't run yet, even though this account genuinely has a real event that will land once the round finishes. Pre-fix, the view had no way to distinguish this from a genuinely empty account and showed \"No events yet\" here.")

        await loadTask.value

        XCTAssertFalse(vm.isLoading, "once load() completes, isLoading must clear")
        XCTAssertEqual(vm.events.map(\.id), ["hb-real"],
                       "once load() completes, the real event must have committed -- proving the mid-flight empty read above was genuinely transient, not a real failure")
    }

    /// Regression / no-false-positive companion: a load() that completes
    /// with a genuinely empty account (real agent, zero configured events,
    /// no failure) must still end with isLoading == false and events == []
    /// -- the plain "No events yet" branch must remain reachable for a real
    /// empty account once loading has actually finished, not just avoided
    /// during the mid-flight snapshot above.
    func test_completedLoad_realZeroEvents_isLoadingFalseAndEventsEmpty() async {
        let vm = AccountViewModel()
        let user = makeUser("account-events-loading-race-user-2")
        let service = ThrowingTestDataService()
        let agent = FSAgent(id: "agent-1", user_id: user.user_id, name: "Guide", role: "guide", enabled: true, chats: [])
        service.fetchAgentsResult = [agent]
        service.fetchHeartbeatsResultsByAgent["agent-1"] = []

        await vm.load(service: service, user: user)

        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.events.isEmpty,
                      "a genuinely completed, genuinely empty load must still render the plain empty state, not get stuck showing a loading row forever")
    }
}

// MARK: - 2. AccountView+Events.swift: the three-way branch itself is present

final class AccountEventsSectionLoadingBranchRegressionTests: XCTestCase {

    /// AccountView.swift (and its split-out section files, per task
    /// 20260904-compliance-readability-cleanup) has no ViewInspector seam --
    /// see AccountViewBaselineComponentTests.swift's header comment, which
    /// deliberately draws the coverage line at the self-contained
    /// StatBox/EventRow component level, not the sections. Reading the
    /// actual on-disk source (same convention as
    /// AttachmentLightboxTests.swift's lightboxViewSource()) proves a
    /// specific branch structure is present without instantiating the
    /// whole environment-dependent root view.
    private func eventsSectionSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Account/AccountView+Events.swift")
        let full = try String(contentsOf: file, encoding: .utf8)
        guard let start = full.range(of: "var eventsSection: some View {") else {
            XCTFail("eventsSection not found in AccountView+Events.swift")
            return ""
        }
        guard let end = full.range(of: "func agentName(for agentId: String)") else {
            XCTFail("agentName(for:) not found after eventsSection in AccountView+Events.swift")
            return ""
        }
        return String(full[start.lowerBound..<end.lowerBound])
    }

    func test_eventsSection_hasThreeWayBranch_loadingBeforeGenuinelyEmptyBeforePopulated() throws {
        let source = try eventsSectionSource()

        guard let loadingRange = source.range(of: "if vm.events.isEmpty && vm.isLoading {") else {
            XCTFail("eventsSection must branch on `vm.events.isEmpty && vm.isLoading` -- THE FIX for the reported \"never see events on refresh\" bug -- distinguishing \"still fetching\" from \"confirmed empty\" instead of folding both into one `if vm.events.isEmpty` check")
            return
        }
        guard let emptyRange = source.range(of: "} else if vm.events.isEmpty {") else {
            XCTFail("eventsSection must still have a plain `vm.events.isEmpty` branch (without `isLoading`) for the genuinely-finished-and-empty case")
            return
        }
        guard let populatedRange = source.range(of: "} else {") else {
            XCTFail("eventsSection must still have the populated ForEach branch")
            return
        }

        XCTAssertTrue(loadingRange.lowerBound < emptyRange.lowerBound,
                      "the loading branch (isLoading && empty) must be checked BEFORE the plain empty branch, so a mid-flight round never falls through to the genuinely-empty branch just because isLoading happens to be true at the same moment events is empty")
        XCTAssertTrue(emptyRange.lowerBound < populatedRange.lowerBound,
                      "the genuinely-empty branch must come before the populated ForEach fallback")
    }

    func test_eventsSection_loadingBranch_showsProgressViewAndLoadingCopy_matchingExistingConvention() throws {
        let source = try eventsSectionSource()
        guard let loadingRange = source.range(of: "if vm.events.isEmpty && vm.isLoading {"),
              let emptyRange = source.range(of: "} else if vm.events.isEmpty {") else {
            XCTFail("expected branch markers not found -- see the branch-order test for the specific failure")
            return
        }
        let loadingBranch = String(source[loadingRange.upperBound..<emptyRange.lowerBound])

        XCTAssertTrue(loadingBranch.contains("ProgressView().tint(Theme.gold)"),
                      "the loading row must use the same plain gold-tinted spinner convention as BlockedUsersView/AttachmentLightboxView, not a bespoke loading treatment")
        XCTAssertTrue(loadingBranch.contains("Loading your events…"),
                      "the loading row must show explicit loading copy, not silently reuse the confirmed-empty text")
        XCTAssertFalse(loadingBranch.contains("No events yet"),
                       "the loading branch must not also contain the confirmed-empty copy -- the two states must render distinctly")
    }

    func test_eventsSection_genuinelyEmptyBranch_stillHasOriginalCopyUnchanged() throws {
        let source = try eventsSectionSource()
        guard let emptyRange = source.range(of: "} else if vm.events.isEmpty {") else {
            XCTFail("plain empty branch not found -- see the branch-order test for the specific failure")
            return
        }
        let afterEmpty = String(source[emptyRange.upperBound...])
        guard let populatedMarker = afterEmpty.range(of: "} else {") else {
            XCTFail("populated branch marker not found after the empty branch")
            return
        }
        let emptyBranch = String(afterEmpty[..<populatedMarker.lowerBound])

        XCTAssertTrue(emptyBranch.contains("No events yet. Tap + to schedule one."),
                      "the genuinely-empty branch's copy must be unchanged by this fix -- only the loading branch is new")
        XCTAssertFalse(emptyBranch.contains("ProgressView"),
                       "the genuinely-empty branch must not show a spinner -- that would contradict its own \"confirmed empty\" claim")
    }

    /// Regression guard against the exact pre-fix shape: the old code was a
    /// plain two-way `if vm.events.isEmpty { ... } else { ForEach ... }`
    /// with no `isLoading` check anywhere. If this fix were ever reverted,
    /// `vm.isLoading` would stop appearing in eventsSection entirely -- this
    /// fails immediately in that case, independent of the more specific
    /// branch-content assertions above.
    func test_eventsSection_referencesIsLoading_regressionGuardAgainstPreFixTwoWayBranch() throws {
        let source = try eventsSectionSource()
        XCTAssertTrue(source.contains("vm.isLoading"),
                      "REGRESSION: eventsSection no longer references vm.isLoading at all -- this is the exact pre-fix shape that caused the reported bug (a mid-flight refresh rendering indistinguishable from a genuinely empty account)")
    }
}
