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

        notes = (await notesTask)?.notes ?? [:]
        friendActivity = (await friendActivityTask) ?? .empty

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
    @StateObject private var vm = DashboardViewModel()
    @State private var showNewNote    = false
    @State private var showResumeNote = false

    private func openFriendChat(id: String, username: String) {
        appState.pendingChatContact = FSContact(id: id, name: username, type: .friend)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bgPage.ignoresSafeArea()

            // Warm gradient backdrop — anchored to the very top (bleeds under the
            // status bar) and fading into the page so the hero blends into the
            // content instead of ending on a hard edge. Fixed: content scrolls
            // over it. Stops concentrate the warmth in the top ~46%.
            LinearGradient(
                stops: [
                    .init(color: Color(hex: "#C98420"),               location: 0.00),
                    .init(color: Color(hex: "#A0641A"),               location: 0.09),
                    .init(color: Color(hex: "#6B4315"),               location: 0.20),
                    .init(color: Color(hex: "#3A2612").opacity(0.55), location: 0.32),
                    .init(color: .clear,                              location: 0.46),
                ],
                startPoint: .top, endPoint: .bottom
            )
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
