// DEPENDENCY: AppState.swift, NotesListView.swift (NotesViewModel),
//             BibleReaderView.swift (BibleViewModel), ChatRootView.swift (ChatViewModel)
//
// Owns the single shared instance of each startup-critical screen's view
// model and drives the readiness gate LoadingScreenView (and ContentView)
// watch. This composes readiness from the *same* .load(service:userId:)
// calls each screen's own view model already makes on its own `.task` — it
// never issues a new/duplicate fetch. ContentView injects these owned
// instances into NotesListView / BibleReaderView / ChatRootView, so when
// each of those screens is later lazily mounted (TabView selection), its own
// `.task` sees the shared, already-loaded (or still in-flight) instance
// rather than a fresh one — each view model's own `load()` no-ops on a
// second call (see `hasLoadedOnce` there) to guard against a duplicate fetch
// in that case.
//
// Account/user info isn't tracked separately here: by the time ContentView
// can even reach the authenticated branch that calls start(), it's already
// resident on AppState.currentUser (see AppState.persist/restoreSession).

import SwiftUI
import Combine

@MainActor
final class StartupCoordinator: ObservableObject {
    /// True once every startup-critical data source has resolved (success or
    /// handled failure — each load() swallows its own per-call errors, same
    /// as it always has) or the fixed timeout below has elapsed, whichever
    /// is first.
    @Published private(set) var isReady = false

    /// Set once VersionGateService.checkForUpdate() confirms a newer version
    /// is live, so ContentView can present the update-nudge sheet. Populated
    /// by an independent Task inside start() — deliberately NOT part of the
    /// `async let` race above, so a slow/stalled/failing App Store lookup
    /// can never delay `isReady` or extend LoadingScreenView's own timeout
    /// (task 20260909-ios-version-gate-popup: this is an availability
    /// nudge, not a startup-critical data source, so it fails open and
    /// stays off the readiness critical path entirely).
    @Published private(set) var updateAvailable: AppUpdateInfo?

    // Shared instances — the same objects NotesListView / BibleReaderView /
    // ChatRootView mount with (see ContentView.mainTabView), so their own
    // `.task` blocks observe already-loaded (or in-flight) data instead of
    // triggering a second fetch. Recreated by reset() on sign-out so a
    // subsequent sign-in starts every screen with fresh state rather than
    // the previous account's cached data.
    private(set) var notesVM = NotesViewModel()
    private(set) var bibleVM = BibleViewModel()
    private(set) var chatVM  = ChatViewModel()
    // Added by task 20260901-dashboard-stale-reload-ui: DashboardView used to
    // own its own local `DashboardViewModel()`, the one screen not covered
    // by this shared-instance model -- so it alone got a brand-new,
    // memoryless view model whenever ContentView's `if isReady { mainTabView
    // } else { LoadingScreenView() }` swap tore the whole subtree down and
    // rebuilt it (a real reset()/start() sign-out-then-sign-in cycle).
    // Recreated by reset() below, same as the other three, so a subsequent
    // sign-in starts Dashboard fresh too rather than showing the previous
    // account's leftover state. Deliberately NOT included in start()'s async
    // load race below -- see DashboardView.init(vm:)'s comment for why.
    private(set) var dashboardVM = DashboardViewModel()

    /// Startup readiness ceiling. Kept inside one loading-screen video loop
    /// (~9.7s) so the user never sees it visibly loop back to the start
    /// before the gate gives up and falls through to mainTabView, where any
    /// still-pending source shows its own existing per-panel loading state.
    static let timeoutNanoseconds: UInt64 = 8_000_000_000

    private var started = false

    /// Begins the readiness race for the current session. Safe to call more
    /// than once — only the first call after init (or after reset()) does
    /// anything, so re-invoking from e.g. a second onChange firing is a no-op.
    ///
    /// `versionCheck` mirrors this method's existing `service:` injection
    /// seam — defaults to the real VersionGateService.checkForUpdate() (what
    /// every real call site gets, unchanged) but lets tests substitute a
    /// stub instead of making a real network call to itunes.apple.com, the
    /// same reason `service` is `DataServiceProtocol` rather than a hardcoded
    /// `NetworkService.shared`.
    func start(
        service: DataServiceProtocol,
        userId: String,
        versionCheck: @escaping () async -> AppUpdateInfo? = { await VersionGateService.checkForUpdate() }
    ) {
        guard !started else { return }
        started = true

        // Runs independently of the timeout race below — if it's still in
        // flight when the timeout wins, it keeps going in the background and
        // simply lands in each screen's own per-panel loading/error state
        // once it resolves, rather than being torn down mid-fetch.
        Task {
            async let notes: Void = notesVM.load(service: service, userId: userId)
            // bibleVM.load() here is deliberately lightweight (highlights/
            // bookmarks only) — the 4.2MB bible.json decode is NOT part of
            // this startup race. It's loaded lazily, gated behind the Bible
            // tab's own first appearance (see BibleViewModel.loadBibleContent(),
            // called only from BibleReaderView's `.task`), so cold launch
            // never pays that decode cost. Task 20260904-compliance-performance-fixes.
            async let bible: Void = bibleVM.load(service: service, userId: userId)
            async let chat: Void  = chatVM.load(service: service, userId: userId)
            _ = await (notes, bible, chat)
            if !isReady { isReady = true }
        }

        Task {
            try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
            if !isReady { isReady = true }
        }

        // Version-gate check — see updateAvailable's doc comment above for
        // why this is its own Task rather than folded into the readiness
        // race. Not awaited, not gated on isReady, and its failure is
        // invisible to the user by design (VersionGateService.checkForUpdate
        // fails open).
        Task {
            if let update = await versionCheck() {
                updateAvailable = update
            }
        }
    }

    /// Dismisses the update nudge for this session (user tapped "Update
    /// Now" or "Not Now", or swiped the sheet away). Frequency/snooze
    /// persistence across launches was left unspecified by the intake spec
    /// ("left to architecture/design") — this keeps the simplest behavior
    /// consistent with that: the nudge may reappear on a future launch
    /// while the installed version is still behind, with no cross-launch
    /// state to manage.
    func dismissUpdateNudge() {
        updateAvailable = nil
    }

    /// Called when the app goes back to signed-out (see ContentView's
    /// onChange of appState.isAuthenticated) so a subsequent sign-in gets a
    /// fresh readiness gate and fresh view-model instances instead of
    /// reusing the previous account's already-`hasLoadedOnce` ones.
    func reset() {
        started = false
        isReady = false
        updateAvailable = nil
        notesVM = NotesViewModel()
        bibleVM = BibleViewModel()
        chatVM  = ChatViewModel()
        dashboardVM = DashboardViewModel()
    }
}
