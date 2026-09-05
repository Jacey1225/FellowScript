// NotesListView+List.swift — Notes tab (search results / paginated list /
// empty states) and Highlights tab content, plus the new-note action and
// edit/delete authorship gating. Split out of NotesListView.swift
// (readability #6, 20260904-frontend-arch-sweep) -- same type, same
// behavior, just this section's own file. See NotesListView.swift's header
// comment for the full split rationale and the list of sibling section
// files.

import SwiftUI

extension NotesListView {

    // ── Notes tab ─────────────────────────────────────────────────────────────
    // While a search is active, the segment-scoped search results (already a
    // flat, non-paginated match set from the backend -- see
    // NotesViewModel.runSearch) replace the normal paginated `filteredNotes`
    // list entirely, so pagination/loadMoreIfNeeded never fires for search
    // results. Clearing search (NotesViewModel.isSearchActive false again)
    // falls straight back through to the untouched original list path below.
    var notesTab: some View {
        Group {
            if vm.isSearchActive {
                if vm.searchResults.isEmpty {
                    if vm.isSearching {
                        // Plain spinner placeholder (UI/UX pref Q17) while the
                        // debounced query for this text is in flight and
                        // there's nothing to show yet.
                        VStack { Spacer(); ProgressView().tint(Theme.gold); Spacer() }
                    } else {
                        searchNoResultsState
                    }
                } else {
                    notesList(vm.searchResults, enablePagination: false)
                }
            } else if vm.filteredNotes.isEmpty {
                notesEmptyState
            } else {
                notesList(vm.filteredNotes, enablePagination: true)
            }
        }
    }

    // Minimal single-message no-results state (UI/UX pref Q17: empty states
    // default to minimal, not an illustrated/on-brand production).
    var searchNoResultsState: some View {
        VStack {
            Spacer()
            Text("No notes found for \u{201C}\(vm.searchText)\u{201D}")
                .font(.inter(Theme.fontSM))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingXL)
            Spacer()
        }
        .accessibilityLabel("No notes found for \(vm.searchText)")
    }

    // Shared list rendering for both the normal paginated notes list and an
    // active search's flat result set -- identical row content/affordances
    // (tap to open, swipe/context-menu edit-delete gating) either way;
    // `enablePagination` just gates whether the bottom-of-list trigger fires
    // `loadMoreIfNeeded` (search results are already the full match set, so
    // there's nothing further to page in).
    @ViewBuilder
    func notesList(_ items: [(String, FSNote)], enablePagination: Bool) -> some View {
        List {
            ForEach(items, id: \.0) { id, note in
                NoteRow(note: note)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                    .onTapGesture { detailNote = note }
                    .onAppear {
                        // Bottom-of-list trigger for the next backend-capped page
                        // (15 at a time). Firing on the last row lets the fetch
                        // start slightly before the user hits the true bottom.
                        guard enablePagination, id == items.last?.0 else { return }
                        let uid = appState.currentUser?.user_id ?? ""
                        Task { await vm.loadMoreIfNeeded(userId: uid) }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if canDelete(note) {
                            Button(role: .destructive) {
                                let uid = appState.currentUser?.user_id ?? ""
                                Task { await vm.deleteNote(id: id, userId: uid, isOwnNote: true) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .contextMenu {
                        if canEdit(note) {
                            Button("Edit", systemImage: "pencil") {
                                editingNote    = note
                                editingId      = id
                                editingGroupId = note.group_id
                                showEditor     = true
                            }
                        }
                        if canDelete(note) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                let uid = appState.currentUser?.user_id ?? ""
                                Task { await vm.deleteNote(id: id, userId: uid, isOwnNote: true) }
                            }
                        }
                    }
                    .accessibilityLabel("Note: \(note.title.isEmpty ? "Untitled" : note.title). \(note.preview)")
            }
            if enablePagination && vm.isLoadingMore && vm.hasMoreForCurrentSegment {
                HStack {
                    Spacer()
                    ProgressView().tint(Theme.gold)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityLabel("Loading more notes")
            }
        }
        .listStyle(.plain)
        // Pull-to-refresh (task 20260831-interaction-polish-conventions):
        // wired straight to NotesViewModel's existing reload method
        // (its new `refresh()` entry point — see that method's own
        // comment for why this isn't just `vm.load()` again). Both
        // tabs below share this same view model/underlying fetch, so
        // either tab's `.refreshable` refreshes notes, highlights,
        // and groups together.
        .refreshable {
            await vm.refresh(service: appState.service, userId: appState.currentUser?.user_id ?? "")
        }
        .scrollContentBackground(.hidden)
        // Breathing room + top-edge feather (task
        // 20260831-notes-messages-list-scroll-blur): groupChips sits
        // directly above this List with no gap, so rows scrolling up
        // used to hit a hard clip flush against the chip row -- a
        // live scrolled-state screenshot showed a card visibly
        // colliding with/reading as overlapping the chips, not just
        // "unblurred." `.contentMargins(.top:)` alone only offsets
        // the AT-REST position (scrollOffset 0); it does not create
        // a persistent gap once scrolled, since content still
        // travels all the way to the List's own top-edge frame
        // boundary while scrolling. The real fix needs both halves:
        // the `.padding(.top:)` below (OUTSIDE the List, after the
        // mask) moves the List's own clipping frame a genuine,
        // scroll-independent Theme.spacingLG away from groupChips,
        // so even a fully-scrolled row's top edge stays clear of the
        // chip row -- no overlap, ever, regardless of scroll offset.
        // `.contentMargins(.top:)` keeps a smaller matching inset so
        // the first row also isn't flush against the List's own
        // (now further-away) top edge at rest. scrollTopEdgeFeather
        // (Theme.swift) adapts NoteDetailView's ScrollView `.mask`
        // precedent for List so rows fade out smoothly as they
        // approach that inner top edge while scrolling, instead of
        // hard-clipping there. Neither of these is a background
        // overlay/panel -- both operate on the List's own frame/
        // alpha, nothing new is drawn behind or in front of it.
        .contentMargins(.top, Theme.spacingSM, for: .scrollContent)
        .contentMargins(.bottom, 100, for: .scrollContent)
        .scrollTopEdgeFeather()
        .padding(.top, Theme.spacingLG)
    }

    // ── Highlights tab ────────────────────────────────────────────────────────
    var highlightsTab: some View {
        Group {
            if vm.sortedHighlights.isEmpty {
                VStack(spacing: Theme.spacingMD) {
                    Spacer()
                    Image(systemName: "highlighter")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(Theme.gold.opacity(0.30))
                    Text("No highlights yet")
                        .font(.playfair(Theme.fontBody))
                        .foregroundColor(Theme.textSecondary)
                    Text("Long-press a verse while reading to highlight it.")
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.spacingXL)
                    Spacer()
                }
                .accessibilityLabel("No highlights yet. Long-press a verse while reading to highlight it.")
            } else {
                List(vm.sortedHighlights) { h in
                    HighlightRow(highlight: h)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Only navigate for a properly parsed reference.
                            guard h.chapter > 0, h.verse > 0 else { return }
                            appState.pendingBibleNav = BibleNavTarget(
                                book: h.book, chapter: h.chapter, verse: h.verse
                            )
                        }
                        .accessibilityLabel("Highlight in \(h.book) chapter \(h.chapter) verse \(h.verse). Tap to open in the Bible.")
                        .accessibilityAddTraits(.isButton)
                }
                .listStyle(.plain)
                // See notesTab's identical treatment above (task
                // 20260831-interaction-polish-conventions) — same vm.refresh(),
                // same shared underlying fetch.
                .refreshable {
                    await vm.refresh(service: appState.service, userId: appState.currentUser?.user_id ?? "")
                }
                .scrollContentBackground(.hidden)
                // See notesTab's identical treatment above (task
                // 20260831-notes-messages-list-scroll-blur) -- same header,
                // same seam, same fix.
                .contentMargins(.top, Theme.spacingSM, for: .scrollContent)
                .contentMargins(.bottom, 100, for: .scrollContent)
                .scrollTopEdgeFeather()
                .padding(.top, Theme.spacingLG)
            }
        }
    }

    var notesEmptyState: some View {
        VStack(spacing: Theme.spacingMD) {
            Spacer()
            Text("✦")
                .font(.custom("Georgia-Italic", size: 40))
                .foregroundColor(Theme.gold.opacity(0.25))
            if vm.currentGroupId == nil {
                Text("Your study begins here")
                    .font(.playfair(Theme.fontHeading))
                    .foregroundColor(Theme.textSecondary)
                Text("Tap **+** to capture your first personal note.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
            } else {
                Text("No notes in \(vm.currentGroupName)")
                    .font(.playfair(Theme.fontHeading))
                    .foregroundColor(Theme.textSecondary)
                Text("Tap **+** to add the first note to this group.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            Button(action: startNewNote) {
                Label("New Note", systemImage: "plus")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.gold)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius)
                            .stroke(Theme.borderGold, lineWidth: 1)
                    )
            }
            .accessibilityLabel("Create new note")
            Spacer()
        }
        .padding()
    }

    func startNewNote() {
        editingNote    = nil
        editingId      = nil
        editingGroupId = vm.currentGroupId ?? ""
        showEditor     = true
    }

    // Gates the swipe/context-menu Delete (and, via canEdit below, the
    // context-menu Edit) affordances (task 20260829-notes-edit-author-gate,
    // extended by 20260903-notes-public-repurpose step 5): a group note is
    // always deletable/editable by its author — `filteredNotes` returns
    // every group member's notes filtered only by group_id, with no
    // authorship filter, so without this check every member saw Edit/Delete
    // on every note in the segment even though the backend was always going
    // to reject a non-author's write with 403. Personal notes (no group_id)
    // need no check: they're always self-authored already. Mirrors
    // NoteRow.showsAuthorChip's deny-by-default fallback: an empty/undecoded
    // `note.username` for a group note hides the affordance rather than
    // assuming authorship.
    func canDelete(_ note: FSNote) -> Bool {
        Self.isAuthor(of: note, currentUsername: appState.currentUser?.username)
    }

    // Edit is a strictly wider gate than Delete (task
    // 20260903-notes-public-repurpose): a non-author group member may also
    // edit (never delete) a group note whose author left `public`
    // (edit-permission) on -- the server enforces the identical split
    // between update_note's new non-owner branch and delete_note's
    // still-owner-only gate; this only drives which affordance(s) appear.
    func canEdit(_ note: FSNote) -> Bool {
        canDelete(note) || (!note.group_id.isEmpty && note.public)
    }

    // Testability seam (task 20260829-notes-edit-author-gate, testing gate):
    // the actual authorship comparison above, pulled out as a pure static
    // function so it's directly unit-testable without hosting a live SwiftUI
    // render pass just to get an EnvironmentObject<AppState> resolved --
    // ViewInspector 0.10.3 (this project's checked-in version) has no
    // support for inspecting `.swipeActions`/`.contextMenu` conditionals, so
    // that route (used elsewhere in this file for `closeAction`/
    // `editAction`) isn't available here. No behavior change: `canDelete`
    // above still reads `appState.currentUser?.username` at both real call
    // sites (swipeActions Delete, contextMenu Edit/Delete); this only
    // exposes the comparison itself for testing. Deny-by-default: an empty/
    // nil `currentUsername` or empty `note.username` on a group note
    // returns false, mirroring NoteRow.showsAuthorChip's same fallback.
    static func isAuthor(of note: FSNote, currentUsername: String?) -> Bool {
        guard !note.group_id.isEmpty else { return true }
        guard !note.username.isEmpty, let me = currentUsername, !me.isEmpty else { return false }
        return note.username == me
    }
}
