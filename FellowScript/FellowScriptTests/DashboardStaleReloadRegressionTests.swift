// DashboardStaleReloadRegressionTests.swift — testing coverage for task
// 20260901-dashboard-stale-reload-ui, testing step 2, covering frontend step
// 1's two-part fix for "Dashboard shows stale/old UI on reload":
//
// Live reproduction (this environment has no interactive
// device/simulator tap-through) confirmed hypothesis 2 as the real trigger:
// ContentView's `if startup.isReady { mainTabView } else { LoadingScreenView() }`
// is a structural branch swap, so every isReady:false->true transition (a
// real StartupCoordinator.reset()+start() sign-out/sign-in cycle) destroys
// and rebuilds the whole mainTabView subtree. DashboardView used to own its
// view model locally (`@StateObject private var vm = DashboardViewModel()`),
// the one tab NOT covered by StartupCoordinator's shared-instance model, so
// it alone lost all state and started over from a blank view model on that
// swap while its three siblings (fed StartupCoordinator-owned instances)
// didn't. Fixed by adding `dashboardVM` to StartupCoordinator (recreated in
// reset(), mirroring notesVM/bibleVM/chatVM) and switching DashboardView to
// a required `init(vm:)`, with ContentView.mainTabView now passing
// `startup.dashboardVM`.
//
// Also fixed, independently of which trigger reproduced it, the
// code-provable bug named directly in the acceptance criteria:
// DashboardViewModel.load() used to unconditionally overwrite
// `notes`/`friendActivity` with an empty fallback (`?? [:]` / `?? .empty`)
// whenever the fresh fetch failed, wiping out good cache-warmed (or
// previously-fetched) data. It now only overwrites on an actual successful
// (non-nil) result, leaving prior good data in place on failure.
//
// This file proves, using the shared ThrowingTestDataService double
// (AppStateAuthAccountTests.swift, extended in this pass with a
// fetchNotesError/fetchNotesDelayNanoseconds seam mirroring the existing
// fetchContactsError/fetchFriendActivityError ones):
//
//   1/2. A failed fresh fetch (notes, then friendActivity) after a prior
//        successful load leaves the already-good data in place instead of
//        wiping it to empty -- the specific regression named in the
//        acceptance criteria ("a failed fetch must not silently wipe
//        already-good cached data down to empty").
//   3.   Convergence still holds: a failed load followed by a later
//        successful one does pick up the fresh data -- this fix is about
//        not wiping on failure, not about caching forever.
//   4/5/6. StartupCoordinator's new `dashboardVM` behaves like its three
//        siblings: the same instance persists across repeated access/start()
//        calls (proving DashboardView(vm:) really would see unchanged state
//        across ContentView's mainTabView rebuild, the actual mechanism
//        behind the reported bug), start() does not fold it into the
//        startup-readiness load race (a deliberate, documented choice), and
//        reset() hands out a fresh instance so a later sign-in doesn't leak
//        the previous account's Dashboard state -- mirroring
//        StartupCoordinatorTests' notesVM-identity assertions but for
//        dashboardVM.
//   7/8. Source-pinning: ContentView.mainTabView actually wires
//        `DashboardView(vm: startup.dashboardVM)` (not a locally-owned
//        instance), and DashboardView no longer exposes a no-argument
//        initializer that could silently reintroduce the bug.

import XCTest
@testable import FellowScript

@MainActor
final class DashboardStaleReloadRegressionTests: XCTestCase {

    /// A fresh, per-test user id -- DashboardViewModel.load() is cache-first
    /// via the real on-disk DiskCache.shared, keyed by userId, so it
    /// persists across test runs in the same simulator container (same
    /// rationale as DashboardFriendActivityLoadTests.freshUserId()).
    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    // MARK: 1 — a failed notes fetch must not wipe already-good notes to empty

    func test_load_notesFetchFails_afterPriorSuccess_leavesGoodNotesInPlace_doesNotWipeToEmpty() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        // Prior successful load populates vm.notes from the mock fixture data.
        await vm.load(service: service, userId: userId)
        let noteIdsAfterSuccess = Set(vm.notes.keys)
        let noteCountAfterSuccess = vm.notes.count
        XCTAssertFalse(noteIdsAfterSuccess.isEmpty, "sanity check: the first load must actually populate notes")

        // A second load whose fresh notes fetch fails outright.
        service.fetchNotesError = AppError.networkError("simulated failure")
        await vm.load(service: service, userId: userId)

        XCTAssertEqual(Set(vm.notes.keys), noteIdsAfterSuccess,
                        "a failed fresh fetch must leave the already-good notes untouched, not overwrite them with an empty fallback")
        XCTAssertEqual(vm.notes.count, noteCountAfterSuccess)
        XCTAssertFalse(vm.notes.isEmpty,
                        "regression guard for the exact bug: notes must never collapse to empty just because the fresh fetch failed")
        XCTAssertFalse(vm.isLoading, "load() must still complete (not hang) when the fresh fetch fails")
    }

    // MARK: 2 — same contract for friendActivity

    func test_load_friendActivityFetchFails_afterPriorSuccess_leavesGoodFeedInPlace_doesNotWipeToEmpty() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        await vm.load(service: service, userId: userId)
        let feedAfterSuccess = vm.friendActivity
        XCTAssertFalse(feedAfterSuccess.friends_active.isEmpty, "sanity check: the first load must actually populate friendActivity")

        service.fetchFriendActivityError = AppError.networkError("simulated failure")
        await vm.load(service: service, userId: userId)

        XCTAssertEqual(vm.friendActivity, feedAfterSuccess,
                        "a failed fresh fetch must leave the already-good friendActivity feed untouched, not overwrite it with .empty")
        XCTAssertFalse(vm.friendActivity.friends_active.isEmpty,
                        "regression guard for the exact bug: friendActivity must never collapse to .empty just because the fresh fetch failed")
    }

    // MARK: 3 — still converges to current data once a later fetch succeeds

    func test_load_afterAFailedFetch_aSubsequentSuccessfulLoad_stillConvergesToFreshData() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        await vm.load(service: service, userId: userId)
        let originalNoteIds = Set(vm.notes.keys)

        service.fetchNotesError = AppError.networkError("simulated failure")
        await vm.load(service: service, userId: userId)
        XCTAssertEqual(Set(vm.notes.keys), originalNoteIds, "sanity check: the failed load left the old data in place")

        // A distinct, freshly-shaped notes payload (a single note, a
        // different id than anything in the original fixture data) proves
        // the NEXT successful load genuinely overwrites, rather than this
        // fix accidentally making stale data "sticky" forever.
        service.fetchNotesError = nil
        let newNote = FSNote(
            id: "new-note", user: "user-1", title: "Fresh", text: "fresh body",
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-09-01 00:00:00", verses: [], replies: []
        )
        service.fetchNotesPageQueue = [
            NotesPage(notes: ["new-note": newNote], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
        ]
        await vm.load(service: service, userId: userId)

        XCTAssertEqual(Set(vm.notes.keys), ["new-note"],
                        "this fix must not prevent convergence -- a subsequent successful fetch must still fully replace the old data")
        XCTAssertEqual(vm.notes["new-note"]?.title, "Fresh")
    }

    // MARK: 4 — StartupCoordinator.dashboardVM: same instance survives repeated access/start()

    func test_dashboardVM_sameInstance_acrossRepeatedStartCalls() {
        let coordinator = StartupCoordinator()
        let service = ThrowingTestDataService()
        let userId = freshUserId()
        let originalDashboardVM = coordinator.dashboardVM

        coordinator.start(service: service, userId: userId)
        // Mirrors ContentView calling start() from both `.task` and a later
        // `.onChange(of: appState.isAuthenticated)` -- must not disturb
        // dashboardVM's identity, since that identity (not a fresh
        // DashboardViewModel()) is exactly what now survives ContentView's
        // `if isReady { mainTabView }` subtree rebuild.
        coordinator.start(service: service, userId: userId)

        XCTAssertTrue(coordinator.dashboardVM === originalDashboardVM,
                       "dashboardVM's identity must not change across repeated start() calls -- ContentView.mainTabView " +
                       "always passes this same instance to DashboardView(vm:), which is the fix for the reported bug")
    }

    // MARK: 5 — dashboardVM is deliberately NOT folded into start()'s own fetch race

    func test_start_doesNotTriggerDashboardVMsOwnLoad() async {
        let coordinator = StartupCoordinator()
        let service = ThrowingTestDataService()
        let userId = freshUserId()

        coordinator.start(service: service, userId: userId)
        // Give the readiness race a real chance to run to completion.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !coordinator.isReady {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(coordinator.isReady)

        XCTAssertTrue(coordinator.dashboardVM.isLoading,
                       "dashboardVM.isLoading must still be at its untouched default (true) -- start()'s own load race " +
                       "covers only notesVM/bibleVM/chatVM by design; DashboardView's own `.task` is what calls " +
                       "dashboardVM.load(), not StartupCoordinator")
    }

    // MARK: 6 — reset() hands out a fresh dashboardVM, same as its three siblings

    func test_reset_recreatesDashboardVM_freshInstance_notReusingPreviousAccountsState() {
        let coordinator = StartupCoordinator()
        let dashboardVMBeforeReset = coordinator.dashboardVM

        coordinator.reset()

        XCTAssertFalse(coordinator.dashboardVM === dashboardVMBeforeReset,
                        "reset() must hand out a fresh DashboardViewModel instance, not reuse the previous " +
                        "account's already-loaded one -- mirrors reset()'s existing notesVM/bibleVM/chatVM contract")
    }

    // MARK: 7/8 — source-pinning: the actual wiring fix is in place

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_contentView_mainTabView_passesStartupCoordinatorsSharedDashboardVM() throws {
        let source = try readSource("FellowScript/ContentView.swift")
        XCTAssertTrue(source.contains("DashboardView(vm: startup.dashboardVM)"),
                      "ContentView.mainTabView must mount DashboardView with StartupCoordinator's shared dashboardVM " +
                      "(mirroring BibleReaderView/NotesListView/ChatRootView), not a locally-owned instance")
    }

    func test_dashboardView_hasNoDefaultNoArgInit_thatCouldReintroduceALocallyOwnedViewModel() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardView.swift")
        // Only real (non-comment) source lines count -- DashboardView's own
        // comment narrating this exact fix legitimately quotes the old,
        // buggy declaration verbatim as history, which must not itself trip
        // this regression guard.
        let activeLines = source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        XCTAssertFalse(activeLines.contains(where: { $0.contains("@StateObject private var vm = DashboardViewModel()") }),
                       "DashboardView must not go back to owning a locally-created, un-injected view model -- " +
                       "that was the exact root cause of the reported bug (it alone lost state on ContentView's " +
                       "mainTabView subtree rebuild)")
        XCTAssertTrue(activeLines.contains(where: { $0.contains("@StateObject private var vm: DashboardViewModel") }),
                      "DashboardView's vm property must be declared typed-only (no inline default instance), " +
                      "so it can only ever come from the required init(vm:) below")
        XCTAssertTrue(activeLines.contains(where: { $0.contains("init(vm: DashboardViewModel)") }),
                      "DashboardView must take its view model via a required init(vm:), matching BibleReaderView")
    }
}
