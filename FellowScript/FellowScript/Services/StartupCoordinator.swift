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

    // Shared instances — the same objects NotesListView / BibleReaderView /
    // ChatRootView mount with (see ContentView.mainTabView), so their own
    // `.task` blocks observe already-loaded (or in-flight) data instead of
    // triggering a second fetch. Recreated by reset() on sign-out so a
    // subsequent sign-in starts every screen with fresh state rather than
    // the previous account's cached data.
    private(set) var notesVM = NotesViewModel()
    private(set) var bibleVM = BibleViewModel()
    private(set) var chatVM  = ChatViewModel()

    /// Startup readiness ceiling. Kept inside one loading-screen video loop
    /// (~9.7s) so the user never sees it visibly loop back to the start
    /// before the gate gives up and falls through to mainTabView, where any
    /// still-pending source shows its own existing per-panel loading state.
    static let timeoutNanoseconds: UInt64 = 8_000_000_000

    private var started = false

    /// Begins the readiness race for the current session. Safe to call more
    /// than once — only the first call after init (or after reset()) does
    /// anything, so re-invoking from e.g. a second onChange firing is a no-op.
    func start(service: DataServiceProtocol, userId: String) {
        guard !started else { return }
        started = true

        // Runs independently of the timeout race below — if it's still in
        // flight when the timeout wins, it keeps going in the background and
        // simply lands in each screen's own per-panel loading/error state
        // once it resolves, rather than being torn down mid-fetch.
        Task {
            async let notes: Void = notesVM.load(service: service, userId: userId)
            async let bible: Void = bibleVM.load(service: service, userId: userId)
            async let chat: Void  = chatVM.load(service: service, userId: userId)
            _ = await (notes, bible, chat)
            if !isReady { isReady = true }
        }

        Task {
            try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
            if !isReady { isReady = true }
        }
    }

    /// Called when the app goes back to signed-out (see ContentView's
    /// onChange of appState.isAuthenticated) so a subsequent sign-in gets a
    /// fresh readiness gate and fresh view-model instances instead of
    /// reusing the previous account's already-`hasLoadedOnce` ones.
    func reset() {
        started = false
        isReady = false
        notesVM = NotesViewModel()
        bibleVM = BibleViewModel()
        chatVM  = ChatViewModel()
    }
}
