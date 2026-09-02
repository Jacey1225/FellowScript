// SOURCE: reference "FellowScript Dashboard" mockup (DashboardRedesign.swift).
// The home screen: a warm hero header + real-data cards. Every widget is fed by
// existing backend endpoints or client-side derivation of already-fetched data —
// no placeholder content. Empty sources render empty/hidden states.
// DEPENDENCY: AppState.swift, Theme.swift, DashboardComponents.swift, Models.swift

import SwiftUI
import Combine

@MainActor
final class DashboardViewModel: ObservableObject {
    var service: DataServiceProtocol = MockDataService.shared

    @Published var notes:          [String: FSNote]        = [:]
    @Published var isLoading       = true
    // Editorial Hero's Friend Activity card + check-in nudge — GET
    // /friends/{userId}/activity, a new targeted endpoint alongside this
    // view's existing per-resource calls (see backend step 2 of this task:
    // consolidating the other 5 was out of scope, this is the read surface
    // that didn't exist at all before).
    @Published var friendActivity: FSFriendActivityFeed    = .empty

    func load(service: DataServiceProtocol, userId: String) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }

        // ── Cache-first: warm the cards from last-known data ─────────────────────
        if let cached: [String: FSNote] = await DiskCache.shared.load([String: FSNote].self, forKey: "notes:\(userId)") {
            notes = cached
            isLoading = false
        }
        if let cached: FSFriendActivityFeed = await DiskCache.shared.load(FSFriendActivityFeed.self, forKey: "friendActivity:\(userId)") {
            friendActivity = cached
        }

        // ── Fresh fetch (all via the injected service — the real backend) ────────
        // Notes here are only ever used for the most-recent-note card, which
        // reads fine off the first backend-capped page (15, newest first) --
        // this view doesn't need to page through the full collection like
        // NotesListView does.
        async let notesTask          = try? service.fetchNotes(userId: userId, cursorCreatedAt: nil, cursorId: nil)
        async let friendActivityTask = try? service.fetchFriendActivity(userId: userId)

        // Bug fix (task 20260901-dashboard-stale-reload-ui): a failed/thrown
        // fetch used to unconditionally overwrite `notes`/`friendActivity`
        // with an empty fallback (`?? [:]` / `?? .empty`), discarding the
        // real, already-good cache-warmed (or previous-fetch) value that was
        // on screen a moment earlier -- so a reload that hit a transient
        // network failure could wipe good data down to nothing instead of
        // leaving the last-known-good snapshot visible. `try?` collapses any
        // thrown error to nil, and a *successful* fetch always yields a
        // non-nil result (even a genuinely empty one, e.g. no notes yet) --
        // so nil here always means "the fetch failed," never "the backend
        // said there's nothing." Only overwrite on an actual non-nil (i.e.
        // successful) result; on failure, simply leave whatever was already
        // there (cache-warmed or otherwise) in place -- it still always
        // converges to current data the next time a fetch succeeds.
        if let freshNotes = (await notesTask)?.notes {
            notes = freshNotes
        }
        if let freshActivity = await friendActivityTask {
            friendActivity = freshActivity
        }

        // ── Write fresh data back to the shared cache ────────────────────────────
        await DiskCache.shared.save(notes, forKey: "notes:\(userId)")
        await DiskCache.shared.save(friendActivity, forKey: "friendActivity:\(userId)")
    }

    var recentNote: (String, FSNote)? {
        notes.max(by: { $0.value.timestamp < $1.value.timestamp })
             .map { ($0.key, $0.value) }
    }

    /// Saves a note (new or edited) through the injected service, updates the
    /// local `notes` dict on success, and returns nil — mirrors
    /// NotesViewModel.saveNote's contract so NoteEditorView's `onSave`
    /// closure (nil error → dismiss, non-nil → stay open and show it) behaves
    /// identically from the Dashboard's quick-create and note-resume sheets.
    func saveNote(_ note: FSNote, editingId: String?, userId: String) async -> String? {
        do {
            let savedId = try await service.saveNote(note, editingId: editingId, userId: userId)
            var updated = note; updated.id = savedId
            notes[savedId] = updated
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// ── Dashboard root ────────────────────────────────────────────────────────────
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm: DashboardViewModel

    // Required (no default): task 20260901-dashboard-stale-reload-ui moved
    // DashboardViewModel to be a StartupCoordinator-owned shared instance
    // (mirroring BibleViewModel/NotesViewModel/ChatViewModel -- see
    // BibleReaderView's identical init(vm:) rationale). Previously this was
    // `@StateObject private var vm = DashboardViewModel()`, created locally
    // by this view alone -- unlike its three tab siblings, which are all
    // mounted with StartupCoordinator's shared instances. That made
    // DashboardView the one screen whose view model was NOT preserved
    // across ContentView's `if startup.isReady { mainTabView } else {
    // LoadingScreenView() }` structural swap: any isReady:false->true
    // transition (i.e. a real reset()/start() sign-out-then-sign-in cycle)
    // destroys and rebuilds the whole mainTabView subtree, which used to
    // hand this screen a brand-new DashboardViewModel() with no memory of
    // what was already on screen -- while Bible/Notes/Chat's shared
    // instances (owned above that swap, on StartupCoordinator itself)
    // survived it untouched. ContentView.mainTabView is the only call site
    // and always passes StartupCoordinator's shared `dashboardVM`.
    //
    // Deliberately NOT added to StartupCoordinator.start()'s own async load
    // race (unlike notesVM/bibleVM/chatVM): Dashboard doesn't need to gate
    // the startup loading screen, and doing so would need this view model to
    // grow the same hasLoadedOnce-guarded load()/refresh() split those three
    // have (to dedupe StartupCoordinator's own preload against this screen's
    // `.task`) -- which would in turn require `.refreshable` below to switch
    // from `vm.load()` to a new `vm.refresh()`, a real behavior change this
    // task doesn't need to make. `load()` stays exactly as re-callable as it
    // already was (`.task` and `.refreshable` both still call it directly);
    // only its *ownership* moved.
    init(vm: DashboardViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    @State private var showNewNote    = false
    @State private var showResumeNote = false

    private func openFriendChat(id: String, username: String) {
        appState.pendingChatContact = FSContact(id: id, name: username, type: .friend)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bgPage.ignoresSafeArea()

            // Warm bloom ground (shared visual language with Account/Notes/
            // Chat/Bible) — task 20260901-dashboard-background-consistency
            // replaced Dashboard's bespoke top-anchored linear "hero" gradient
            // (the one visible outlier) with the same two-RadialGradient
            // treatment every other screen already uses, so Dashboard's
            // background now reads as the same system as its tab siblings.
            // Identical hex/opacity/anchor/radius to AccountView.swift,
            // NotesListView.swift, ChatRootView.swift, BibleReaderView.swift.
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    HeroHeader(username: appState.currentUser?.username ?? "friend")

                    // ── Editorial Hero: Friend Activity ───────────────────────────────
                    FriendActivityHeroCard(feed: vm.friendActivity) { entry in
                        openFriendChat(id: entry.friend_id, username: entry.username)
                    }

                    if let checkIn = vm.friendActivity.check_in {
                        CheckInRow(checkIn: checkIn) {
                            openFriendChat(id: checkIn.friend_id, username: checkIn.username)
                        }
                    }

                    NoteResumeCard(note: vm.recentNote?.1) {
                        if vm.recentNote != nil {
                            showResumeNote = true
                        } else {
                            showNewNote = true
                        }
                    }
                }
                .padding(.bottom, 150) // clears the floating tab bar
            }
            // Pull-to-refresh (task 20260831-interaction-polish-conventions):
            // wired directly to this screen's existing reload method.
            // `vm.isLoading` isn't read anywhere in this view's body (unlike
            // NotesListView/ChatRootView, which gate their whole list on it),
            // so re-running `load()` here can't blank the screen mid-refresh
            // the way it would there — no separate refresh()/showLoadingSpinner
            // split is needed for this screen.
            .refreshable {
                if let uid = appState.currentUser?.user_id {
                    await vm.load(service: appState.service, userId: uid)
                }
            }
        }
        .task {
            if let uid = appState.currentUser?.user_id {
                await vm.load(service: appState.service, userId: uid)
            }
        }
        .sheet(isPresented: $showNewNote) {
            NoteEditorView(note: nil, noteId: nil, isReadOnly: false) { saved in
                await vm.saveNote(saved, editingId: nil, userId: appState.currentUser?.user_id ?? "")
            }
        }
        .sheet(isPresented: $showResumeNote) {
            if let recent = vm.recentNote {
                NoteEditorView(note: recent.1, noteId: recent.0, isReadOnly: false) { saved in
                    await vm.saveNote(saved, editingId: recent.0, userId: appState.currentUser?.user_id ?? "")
                }
            }
        }
    }
}

// ── Shared section label (also used by ChatThreadView / BibleReaderView) ───────
@ViewBuilder
func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.inter(Theme.fontXXS))
        .tracking(5)
        .textCase(.uppercase)
        .foregroundColor(Theme.textGoldMuted)
}
