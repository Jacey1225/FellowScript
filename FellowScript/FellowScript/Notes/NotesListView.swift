// SOURCE: components/NotesSidebar.jsx (NoteCard, HighlightCard, FilterPanel, group selector)
// KEY STATE: notes, highlights, groups, currentGroupId, activeTab, filteredNotes, showFilter
// INTERACTIONS: + to create, swipe-left to delete, tap to open, group picker, filter sheet
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift, NoteEditorView.swift
//
// readability #6 (20260904-frontend-arch-sweep): this file used to combine
// NotesViewModel and several unrelated view structs (NoteRow, HighlightRow,
// NoteDetailView, ReplyComposerSheet) in one 2024-line file. Split into a
// view-model file, this core file (struct declaration/state/body), two
// section files, and one file per already-independent view struct --
// mirroring the split already applied to AccountView.swift (#6) and
// NetworkService.swift (#H16). Pure file-organization work -- same types,
// same behavior, no interface change. Every member that used to be
// `private` and is now called from an extension in another file dropped
// that modifier (Swift's `private` only extends to same-file extensions) --
// still invisible outside this app target.
//
// Files: NotesViewModel.swift, NotesListView.swift (this file),
// NotesListView+Toolbar.swift (header/tab-toggle/group-chips),
// NotesListView+List.swift (notes/highlights tab content, empty/no-results
// states, edit/delete gating), NotesRowViews.swift (NotesSearchField/
// NoteRow/HighlightRow), NoteDetailView.swift, ReplyComposerSheet.swift.

import SwiftUI
import Combine

// ── Root notes list ───────────────────────────────────────────────────────────
struct NotesListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @StateObject var vm: NotesViewModel

    // Required (no default): a bare `NotesViewModel()` default expression is
    // evaluated as MainActor-isolated under this project's default actor
    // isolation, but this init itself must stay usable from a nonisolated
    // context, so it can't carry that default safely. ContentView.mainTabView
    // is the only call site and always passes StartupCoordinator's shared
    // instance so this screen's `.task` sees already-loaded (or in-flight)
    // data instead of firing a second fetch (see NotesViewModel.hasLoadedOnce).
    init(vm: NotesViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    @State var showEditor       = false
    @State var editingNote:     FSNote?  = nil
    @State var editingId:       String?  = nil
    @State var editingGroupId:  String   = ""
    @State var detailNote:      FSNote?  = nil

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bgPage.ignoresSafeArea()

            // Warm bloom ground (shared visual language with the Dashboard).
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                notesHighlightsToggle
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                if vm.activeTab == .notes {
                    NotesSearchField(text: $vm.searchText, isSearching: vm.isSearching)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)

                    groupChips
                        .padding(.top, 14)
                }

                if vm.isLoading {
                    Spacer()
                    ProgressView().tint(Theme.gold)
                    Spacer()
                } else {
                    switch vm.activeTab {
                    case .notes:      notesTab
                    case .highlights: highlightsTab
                    }
                }
            }
        }
        .task {
            if let uid = appState.currentUser?.user_id {
                vm.configureSearch(userId: uid)
                await vm.load(service: appState.service, userId: uid)
            }
        }
        // Editor sheet — used by the context-menu "Edit" shortcut only.
        // The NoteDetailView → Edit path has its own sheet to avoid two
        // competing sheets on the same parent (which races on editingNote).
        .sheet(isPresented: $showEditor) {
            NoteEditorView(
                note:      editingNote,
                noteId:    editingId,
                groupId:   editingGroupId,
                isReadOnly: false
            ) { saved in
                let uid = appState.currentUser?.user_id ?? ""
                let ok = await vm.saveNote(saved, editingId: editingId, userId: uid)
                if ok { return nil }
                let msg = vm.saveError
                vm.saveError = nil
                return msg ?? "That note could not be saved. Please revise and try again."
            }
        }
        .sheet(item: $detailNote) { note in
            // `editingId: saved.id` (not the outer `note.id`) -- task
            // 20260904-reply-edit-button: this closure now backs both the
            // parent note's own Edit flow AND NoteDetailView's new per-reply
            // Edit flow, which passes a *different* note (the reply) through
            // to `saved`. `NoteEditorView.handleSave` always stamps
            // `saved.id` from whichever `noteId` it was opened with (see
            // NoteEditorView.swift), so `saved.id` already correctly
            // identifies the row actually being edited -- the parent note's
            // own id when editing the parent, or a reply's real row id
            // (surfaced by backend step 1 / NetworkService.fetchReplies) when
            // editing a reply. Closing over the outer `note.id` instead would
            // silently PUT every reply edit onto the parent note's row
            // (found during intake verification), so this is a required fix,
            // not a stylistic one -- `saved.id` and `note.id` were previously
            // always equal for the parent-note-only case this closure used
            // to serve, so this is a no-op change for that existing flow.
            NoteDetailView(
                note:     note,
                userId:   appState.currentUser?.user_id ?? "",
                username: appState.currentUser?.username ?? "",
                service:  vm.service
            ) { saved in
                let uid = appState.currentUser?.user_id ?? ""
                let ok = await vm.saveNote(saved, editingId: saved.id, userId: uid)
                if ok { return nil }
                let msg = vm.saveError
                vm.saveError = nil
                return msg ?? "That note could not be saved. Please revise and try again."
            }
        }
        .alert("Save Failed", isPresented: Binding(
            get: { vm.saveError != nil },
            set: { if !$0 { vm.saveError = nil } }
        )) {
            Button("OK") { vm.saveError = nil }
        } message: {
            Text(vm.saveError ?? "")
        }
    }
}
