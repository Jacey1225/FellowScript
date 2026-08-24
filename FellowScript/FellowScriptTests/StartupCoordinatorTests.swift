// StartupCoordinatorTests.swift — regression coverage for
// task: 20260823-app-loading-screen, testing step (3), covering frontend
// step 2's new StartupCoordinator.swift (the startup-readiness gate behind
// the new video-backed LoadingScreenView).
//
// StartupCoordinator composes readiness across notesVM/bibleVM/chatVM's own
// existing `.load(service:userId:)` calls (never a new/duplicate fetch) and
// gates ContentView's transition from LoadingScreenView into mainTabView on
// `isReady`. This file proves, using the shared ThrowingTestDataService
// double (defined in AppStateAuthAccountTests.swift, extended here with a
// controllable/observable `fetchContacts` seam — see that file):
//
//   1. When every data source resolves quickly, `isReady` flips true well
//      before the fixed 8s timeout ceiling — the gate doesn't artificially
//      wait out the full timeout on the happy path.
//   2. A single data source's fetch throwing (fetchContacts, shared by both
//      NotesViewModel.load and ChatViewModel.load) is handled gracefully —
//      each `.load()` already swallows its own per-call errors via `try?`,
//      so the coordinator must still resolve promptly and must not crash or
//      leave the affected view model in a broken state; the acceptance
//      criterion is "success or a handled failure state", not that failures
//      never happen.
//   3. When a data source genuinely hangs (never resolves), the coordinator
//      does NOT hang forever: its fixed 8s timeout fires and `isReady`
//      becomes true anyway, falling through to mainTabView (whatever's still
//      pending resolves later into that screen's own existing per-panel
//      loading state, per the design note — not exercised by this file,
//      which only covers the coordinator's own gate logic).
//   4. `start()` is safe to call more than once (ContentView calls it from
//      both a `.task` and an `.onChange(of: appState.isAuthenticated)`) —
//      a second call while already started must not re-fetch.
//   5. `reset()` (called on sign-out) clears `isReady`, hands out fresh
//      per-source view-model instances, and a subsequent `start()` really
//      does fetch again (a later sign-in must not reuse a signed-out
//      account's stale, already-`hasLoadedOnce` state).
//   6. The shared view-model instances StartupCoordinator hands to
//      NotesListView/BibleReaderView/ChatRootView (via ContentView.mainTabView)
//      do not re-fetch when that screen's own `.task` later calls `load()`
//      again on first mount — proving "no regression to existing per-page/
//      per-panel loading states... doesn't remove the panels' own loading
//      indicators" doesn't come at the cost of a duplicate fetch.
//
// Real-time waits (not mocked time) are used throughout, matching this
// target's established convention for timing-dependent async code (see
// ChatWebSocketReconnectRegressionTests.swift's real `Task.sleep` waits).

import XCTest
@testable import FellowScript

@MainActor
final class StartupCoordinatorTests: XCTestCase {

    /// A fresh, per-test user id -- NotesViewModel/ChatViewModel's `load()`
    /// is cache-first (DiskCache.shared, keyed by userId, backed by the
    /// *real* on-disk Caches directory, so it persists across test runs in
    /// the same simulator container). Reusing one fixed id across tests
    /// would let an earlier test's successful fetch leak in as this test's
    /// "cached" data even when the live fetch is deliberately failing/
    /// delayed here -- a fresh id per test keeps each one's DiskCache state
    /// genuinely empty.
    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    /// Polls `coordinator.isReady` in short increments up to `timeout`,
    /// rather than a single fixed sleep — lets the "resolves promptly" tests
    /// return as soon as readiness flips instead of always paying the full
    /// poll ceiling.
    private func waitUntilReady(_ coordinator: StartupCoordinator, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if coordinator.isReady { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return coordinator.isReady
    }

    // MARK: 1 — happy path: ready well before the 8s timeout ceiling

    func test_start_allSourcesResolveQuickly_marksReadyWellBeforeTimeout() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()

        coordinator.start(service: service, userId: freshUserId())

        let becameReady = await waitUntilReady(coordinator, timeout: 3)
        XCTAssertTrue(becameReady,
                       "with a fast, all-succeeding service, isReady must flip true well inside the 8s timeout ceiling")
        XCTAssertEqual(service.fetchNotesCallCount, 1, "notesVM.load() must fetch exactly once")
        XCTAssertEqual(service.fetchContactsCallCount, 2,
                        "fetchContacts is called independently by both NotesViewModel.load (for its groups list) " +
                        "and ChatViewModel.load (for friends/groups) -- 2 total, not more, confirms neither one " +
                        "fires it more than once for itself")
    }

    // MARK: 2 — one source throws: handled gracefully, still resolves promptly

    func test_start_oneSourceThrows_othersSucceed_stillReadyPromptly_doesNotCrashOrHang() async {
        let service = ThrowingTestDataService()
        service.fetchContactsError = AppError.networkError("simulated failure")
        let coordinator = StartupCoordinator()

        coordinator.start(service: service, userId: freshUserId())

        let becameReady = await waitUntilReady(coordinator, timeout: 3)
        XCTAssertTrue(becameReady,
                       "a single failing data source must not hang the gate -- NotesViewModel/ChatViewModel's " +
                       "own `try?` around fetchContacts already treats a thrown error as a handled/resolved outcome")

        XCTAssertEqual(service.fetchContactsCallCount, 2,
                        "the failing call must be attempted exactly once each by NotesViewModel and ChatViewModel, not retried in a loop")
        XCTAssertTrue(coordinator.chatVM.friends.isEmpty,
                       "ChatViewModel must land in a sane empty state (not crash) when fetchContacts throws")
        XCTAssertTrue(coordinator.notesVM.groups.isEmpty,
                       "NotesViewModel's groups (also sourced from fetchContacts) must land empty, not crash, on failure")
    }

    // MARK: 3 — a genuinely hanging source: the fixed timeout still fires

    func test_start_sourceHangsIndefinitely_timeoutFiresAndMarksReadyAnyway() async {
        let service = ThrowingTestDataService()
        // Comfortably longer than StartupCoordinator's 8s timeout so the
        // readiness race can never win it -- only the timeout branch can.
        service.fetchContactsDelayNanoseconds = 20_000_000_000
        let coordinator = StartupCoordinator()

        let start = Date()
        coordinator.start(service: service, userId: freshUserId())

        // Must NOT be ready almost immediately -- proves this test is
        // actually exercising the timeout path, not a false pass because the
        // hang wasn't real.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(coordinator.isReady,
                        "with fetchContacts hung for 20s, isReady must still be false 1s in -- readiness must not " +
                        "win a race it can't actually win")

        // Generous upper bound (18s, well under the 20s hang): under real
        // CI/full-suite load (many other tests' simulator/XCTest overhead
        // sharing the same machine) wall-clock Task.sleep delivery can drift
        // well past its nominal duration without the underlying timer logic
        // being wrong -- observed empirically up to ~24s for an 8s nominal
        // timeout when run as part of the full FellowScriptTests suite vs.
        // ~8.0s in isolation. The important invariant this test protects is
        // "the ~8s timeout is what unblocks this, not the 20s hang itself
        // eventually completing on its own" -- 18s still cleanly
        // distinguishes those two cases without being tuned to an unrealistic
        // single-test-in-isolation timing budget.
        let becameReady = await waitUntilReady(coordinator, timeout: 17)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(becameReady, "the fixed 8s timeout must mark isReady true even though the hung source never resolved")
        XCTAssertGreaterThanOrEqual(elapsed, 6.0,
                                     "isReady must not flip true meaningfully earlier than the documented ~8s timeout ceiling")
        XCTAssertLessThan(elapsed, 18.0,
                           "isReady must flip true at (roughly) the timeout, not only once the 20s hung fetch itself eventually completes")
    }

    // MARK: 4 — start() is idempotent once already started

    func test_start_calledTwice_doesNotRefetch() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()
        let userId = freshUserId()

        coordinator.start(service: service, userId: userId)
        // Mirrors ContentView calling start() from both its `.task` and a
        // subsequent `.onChange(of: appState.isAuthenticated)` firing.
        coordinator.start(service: service, userId: userId)

        _ = await waitUntilReady(coordinator, timeout: 3)

        XCTAssertEqual(service.fetchNotesCallCount, 1,
                        "a second start() call while already started must be a no-op -- exactly one fetch total")
    }

    // MARK: 5 — reset() clears state and a later start() really refetches

    func test_reset_clearsReadiness_andSubsequentStartRefetchesWithFreshInstances() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()
        let userId = freshUserId()

        coordinator.start(service: service, userId: userId)
        let firstReady = await waitUntilReady(coordinator, timeout: 3)
        XCTAssertTrue(firstReady)
        XCTAssertEqual(service.fetchNotesCallCount, 1)

        let notesVMBeforeReset = coordinator.notesVM

        coordinator.reset()
        XCTAssertFalse(coordinator.isReady, "reset() must clear isReady so a re-signed-in session shows the loading screen again")
        XCTAssertFalse(coordinator.notesVM === notesVMBeforeReset,
                        "reset() must hand out a fresh NotesViewModel instance, not reuse the previous " +
                        "account's already-hasLoadedOnce one")

        coordinator.start(service: service, userId: userId)
        let secondReady = await waitUntilReady(coordinator, timeout: 3)
        XCTAssertTrue(secondReady, "a fresh start() after reset() must reach ready again")
        XCTAssertEqual(service.fetchNotesCallCount, 2,
                        "the fresh instance must actually refetch -- a later sign-in must not silently reuse stale data")
    }

    // MARK: 6 — no duplicate fetch when a screen's own `.task` later re-calls load()

    func test_sharedNotesViewModel_secondLoadCallFromScreenTaskDoesNotRefetch() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()
        let userId = freshUserId()

        coordinator.start(service: service, userId: userId)
        _ = await waitUntilReady(coordinator, timeout: 3)
        XCTAssertEqual(service.fetchNotesCallCount, 1)

        // Simulates NotesListView's own `.task { await vm.load(...) }` firing
        // the first time it's lazily mounted, AFTER StartupCoordinator already
        // loaded this exact shared instance up front.
        await coordinator.notesVM.load(service: service, userId: userId)

        XCTAssertEqual(service.fetchNotesCallCount, 1,
                        "mounting NotesListView after the startup gate already loaded its shared view model must " +
                        "not fire a second, duplicate fetch -- this is the 'no regression / no duplicate fetch' " +
                        "acceptance criterion at the view-model level")
    }
}
