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
    // Task 20260902-dashboard-friend-randomization: the friend actually
    // surfaced in FriendActivityHeroCard/CheckInRow, picked at random from
    // `friendActivity`'s already-fetched lists. Stored here (not derived as
    // a computed property inside a View's `body`) and only ever reassigned
    // once, at the end of `load()` below -- so a re-render triggered by some
    // unrelated @Published change (`notes`, `isLoading`, ...) never reshuffles
    // who's shown; only an actual completed load does. `.randomElement()` on
    // an empty list is nil, so 0-candidate feeds fall back to the same "no
    // pick" behavior the old deterministic `.first`/single-candidate code
    // had -- no special-casing needed for the 0/1-friend empty states.
    @Published var heroFriendPick: FSFriendActivityEntry?
    @Published var checkInPick:    FSCheckInCandidate?

    // Task 20260906-friend-nudges: UI state for CheckInRow's send action,
    // driven entirely by the shared `DataServiceProtocol.sendNudge` response
    // contract (see NudgeResult) rather than each surface re-deriving its
    // own success/rate-limited/failed mapping. Reset to `.idle` every time
    // `load()` rolls a new `checkInPick` below, so a stale sent/rate-limited
    // look from a previous candidate never carries over onto a different
    // friend.
    @Published var checkInNudgeState: NudgeUIState = .idle

    // Forward-compatible plumbing only (task 20260906-friend-nudges): keyed
    // by friend_id, for the avatar-tile nudge control specced in the sibling
    // /design task 20260906-friend-activity-avatar-row. That control's own
    // tile restyle hasn't landed in FriendActivityHeroCard yet, so nothing
    // reads this dict today -- it exists so the eventual tile-restyle
    // follow-up only needs to call `onNudge`/read this state, not add any
    // new network wiring of its own.
    @Published var friendNudgeStates: [String: NudgeUIState] = [:]

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

        // Task 20260902-dashboard-friend-randomization: re-roll exactly once
        // per `load()` call, here, after `friendActivity` has fully settled
        // for this call (cache-warm, then possibly superseded by a
        // successful fresh fetch per the stale-reload fix above). Rolling
        // separately at the cache-warm assignment too would re-randomize the
        // pick a second time within the same call even when the underlying
        // data hasn't actually changed -- a visible thrash the acceptance
        // criteria specifically calls out, not the same thing as the
        // existing (accepted) cache-then-fresh data transition itself.
        heroFriendPick = friendActivity.friends_active.randomElement()
        checkInPick    = friendActivity.check_in_candidates.randomElement()
        // A fresh candidate (even the same friend re-picked) starts tappable
        // again -- see checkInNudgeState's own doc comment above.
        checkInNudgeState = .idle
        friendNudgeStates = [:]

        // ── Write fresh data back to the shared cache ────────────────────────────
        await DiskCache.shared.save(notes, forKey: "notes:\(userId)")
        await DiskCache.shared.save(friendActivity, forKey: "friendActivity:\(userId)")
    }

    var recentNote: (String, FSNote)? {
        notes.max(by: { $0.value.timestamp < $1.value.timestamp })
             .map { ($0.key, $0.value) }
    }

    // Task 20260906-friend-nudges: CheckInRow's send action. Guards against a
    // double-tap mid-flight the same way openFriendNote's isLoadingFriendNote
    // guard does -- `.sending` is itself the re-entrancy lock, no separate
    // Bool needed.
    func sendCheckInNudge(userId: String) async {
        guard let checkIn = checkInPick, checkInNudgeState != .sending else { return }
        checkInNudgeState = .sending
        switch await service.sendNudge(userId: userId, friendId: checkIn.friend_id) {
        case .sent:        checkInNudgeState = .sent
        case .rateLimited: checkInNudgeState = .rateLimited
        case .failed:
            // Brief, transient pulse (mirrors the sibling /design task's
            // tile-control error state) then back to tappable -- a low-
            // stakes social action getting a quick "that didn't land, try
            // again" rather than a persistent error surface.
            checkInNudgeState = .failed
            try? await Task.sleep(nanoseconds: 300_000_000)
            checkInNudgeState = .idle
        }
    }

    // Forward-compatible plumbing only -- see friendNudgeStates' doc comment.
    // Not called anywhere in this build yet (no real avatar-tile control
    // exists to call it), but implemented now against the exact same
    // sendNudge contract as sendCheckInNudge above so the eventual tile
    // restyle's onNudge wiring is a pure call-site change, not new logic.
    func sendNudge(to friendId: String, userId: String) async {
        guard friendNudgeStates[friendId] != .sending else { return }
        friendNudgeStates[friendId] = .sending
        switch await service.sendNudge(userId: userId, friendId: friendId) {
        case .sent:        friendNudgeStates[friendId] = .sent
        case .rateLimited: friendNudgeStates[friendId] = .rateLimited
        case .failed:
            friendNudgeStates[friendId] = .failed
            try? await Task.sleep(nanoseconds: 300_000_000)
            friendNudgeStates[friendId] = .idle
        }
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
    // Task 20260903-friend-activity-note-navigation: presented via
    // `.sheet(item:)` exactly like NotesListView's own `detailNote`, in
    // place on Dashboard -- no tab switch, no new cross-tab navigation
    // infrastructure (appState.pendingChatContact below is the one existing
    // exception to that, predating this task, for chat only).
    @State private var friendNote:          FSNote? = nil
    @State private var isLoadingFriendNote  = false
    @State private var friendNoteLoadError: String? = nil

    private func openFriendChat(id: String, username: String) {
        appState.pendingChatContact = FSContact(id: id, name: username, type: .friend)
    }

    // Fetches the full note behind a Friend Activity note-preview tap.
    // Server-side permission-checked on every call (GET
    // /notes/{user_id}/note/{note_id} -- never trusts the preview data
    // already on screen as proof the note is still visible), so this
    // gracefully surfaces the "deleted/no-longer-visible between preview
    // load and tap time" case via `friendNoteLoadError` rather than
    // crashing or silently doing nothing.
    private func openFriendNote(_ preview: FSFriendNotePreview) {
        guard let uid = appState.currentUser?.user_id, !isLoadingFriendNote else { return }
        isLoadingFriendNote = true
        Task {
            do {
                friendNote = try await appState.service.fetchNote(userId: uid, noteId: preview.note_id)
            } catch {
                friendNoteLoadError = error.localizedDescription
            }
            isLoadingFriendNote = false
        }
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
                    HeroHeader(
                        username: appState.currentUser?.username ?? "friend",
                        photoURL: appState.currentUser?.profile_photo_url
                    )

                    // ── Editorial Hero: Friend Activity ───────────────────────────────
                    FriendActivityHeroCard(
                        feed: vm.friendActivity,
                        primary: vm.heroFriendPick,
                        onOpenFriend: { entry in
                            openFriendChat(id: entry.friend_id, username: entry.username)
                        },
                        onOpenNote: { preview in
                            openFriendNote(preview)
                        },
                        // Task 20260906-friend-nudges: forward-compatible
                        // wiring only -- see FriendActivityHeroCard's own
                        // onNudge doc comment. Wired here so the sibling
                        // /design task's eventual tile-restyle follow-up
                        // only needs to attach a control that calls
                        // `onNudge(entry)`; the network call and per-friend
                        // state are already live.
                        onNudge: { entry in
                            if let uid = appState.currentUser?.user_id {
                                Task { await vm.sendNudge(to: entry.friend_id, userId: uid) }
                            }
                        },
                        nudgeStates: vm.friendNudgeStates,
                        isLoadingNotePreview: isLoadingFriendNote
                    )

                    if let checkIn = vm.checkInPick {
                        // Task 20260906-friend-nudges: this row's send action
                        // now nudges the friend (fixed push copy, via the
                        // shared sendCheckInNudge/sendNudge contract) instead
                        // of opening their chat thread -- chat for this
                        // friend is still one tap away via the friend
                        // activity card / contacts list above, so nothing is
                        // actually lost, and "check in" already meant
                        // "prompt a quiet friend," which a nudge now does for
                        // real instead of just opening a blank-feeling chat.
                        CheckInRow(checkIn: checkIn, nudgeState: vm.checkInNudgeState) {
                            if let uid = appState.currentUser?.user_id {
                                Task { await vm.sendCheckInNudge(userId: uid) }
                            }
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
        // Task 20260903-friend-activity-note-navigation: mirrors
        // NotesListView's `.sheet(item: $detailNote)` -- presented in place
        // on Dashboard, no tab switch. Saves go straight through
        // `appState.service` rather than `vm.saveNote` deliberately: this is
        // a friend's shared group note, not one of this screen's own
        // `notes` (which back `recentNote`/NoteResumeCard) -- merging it
        // into that dict would risk NoteResumeCard picking up a friend's
        // note as "your" most recent note to resume.
        .sheet(item: $friendNote) { note in
            NoteDetailView(
                note:     note,
                userId:   appState.currentUser?.user_id ?? "",
                username: appState.currentUser?.username ?? "",
                service:  appState.service
            ) { saved in
                do {
                    _ = try await appState.service.saveNote(saved, editingId: note.id, userId: appState.currentUser?.user_id ?? "")
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
        .alert("Could Not Open Note", isPresented: Binding(
            get: { friendNoteLoadError != nil },
            set: { if !$0 { friendNoteLoadError = nil } }
        )) {
            Button("OK") { friendNoteLoadError = nil }
        } message: {
            Text(friendNoteLoadError ?? "That note is no longer available.")
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
