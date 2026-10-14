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
            if embedded {
                ForEach(noteBookGroups(items), id: \.title) { group in
                    Section {
                        ForEach(group.items, id: \.0) { id, note in
                            noteListRow(id: id, note: note, items: items, enablePagination: enablePagination)
                        }
                    } header: {
                        Text(group.title)
                            .font(.inter(Theme.fontHeading, weight: .bold))
                            .foregroundColor(Theme.textGoldMuted)
                            .textCase(nil)
                            .padding(.top, 6)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .listSectionSeparator(.hidden)
                }
            } else {
            ForEach(items, id: \.0) { id, note in
                noteListRow(id: id, note: note, items: items, enablePagination: enablePagination)
            }
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
        .refreshable {
            await vm.refresh(service: appState.service, userId: appState.currentUser?.user_id ?? "")
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, Theme.spacingSM, for: .scrollContent)
        .contentMargins(.bottom, embedded ? 20 : 100, for: .scrollContent)
        .scrollTopEdgeFeather()
        .padding(.top, Theme.spacingLG)
    }

    /// Notes grouped under their first verse's book heading (screenshot 1);
    /// notes without a verse go under "General". Group order follows list order.
    func noteBookGroups(_ items: [(String, FSNote)]) -> [(title: String, items: [(String, FSNote)])] {
        var order: [String] = []
        var buckets: [String: [(String, FSNote)]] = [:]
        for item in items {
            let title = item.1.verses.first(where: { $0.count >= 3 })?.first?.asString ?? "General"
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(item)
        }
        return order.map { (title: $0, items: buckets[$0] ?? []) }
    }

    @ViewBuilder
    func noteListRow(id: String, note: FSNote, items: [(String, FSNote)], enablePagination: Bool) -> some View {
                NoteRow(note: note, card: embedded,
                        onSend: embedded && canSendInChat(note) ? { sendInChat(note) } : nil,
                        onEdit: embedded && canEdit(note) ? {
                            editingNote = note; editingId = id; editingGroupId = note.group_id; showEditor = true
                        } : nil,
                        onDelete: embedded && canDelete(note) ? {
                            let uid = appState.currentUser?.user_id ?? ""
                            Task { await vm.deleteNote(id: id, userId: uid, isOwnNote: true) }
                        } : nil)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: embedded ? 12 : 20, bottom: 6, trailing: embedded ? 12 : 20))
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
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if canSendInChat(note) {
                            Button { sendInChat(note) } label: {
                                Label("Send in chat", systemImage: "paperplane")
                            }
                            .tint(Theme.gold)
                        }
                    }
                    .contextMenu {
                        if canSendInChat(note) {
                            Button("Send in Chat", systemImage: "paperplane") { sendInChat(note) }
                        }
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
                    HighlightRow(highlight: h, compact: embedded)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: embedded ? 12 : 20, bottom: 4, trailing: embedded ? 12 : 20))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Only navigate for a properly parsed reference.
                            guard h.chapter > 0, h.verse > 0 else { return }
                            appState.pendingBibleNav = BibleNavTarget(
                                book: h.book, chapter: h.chapter, verse: h.verse
                            )
                        }
                        .contextMenu {
                            if h.chapter > 0, h.verse > 0 {
                                Button("Share", systemImage: "square.and.arrow.up") {
                                    shareHighlight(book: h.book, chapter: h.chapter, verse: h.verse, knownText: nil)
                                }
                                .accessibilityLabel("Share \(h.book) \(h.chapter):\(h.verse)")
                            }
                        }
                        .accessibilityLabel("Highlight in \(h.book) chapter \(h.chapter) verse \(h.verse). Tap to open in the Bible.")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityActions {
                            if h.chapter > 0, h.verse > 0 {
                                Button("Share \(h.book) \(h.chapter):\(h.verse)") {
                                    shareHighlight(book: h.book, chapter: h.chapter, verse: h.verse, knownText: nil)
                                }
                            }
                        }
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
    // Task 20261012-share-verses-notes-in-chat: a note may go into a chat only
    // when the viewer wrote it, or it is a group note editable by the whole
    // group (public). Same split the server enforces; flag-gated; never replies.
    func canSendInChat(_ note: FSNote) -> Bool {
        appState.capabilities.sharedObjectsEnabled && !note.is_reply && canEdit(note)
    }

    func sendInChat(_ note: FSNote) {
        chatShare = ChatShareDraft(payload: .note(note, ownerUsername: note.username))
    }

    /// The picker can't stack on the detail sheet: close it, then present.
    func sendInChatFromDetail(_ note: FSNote) {
        detailNote = nil
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            sendInChat(note)
        }
    }

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
