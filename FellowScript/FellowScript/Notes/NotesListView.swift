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
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @StateObject var vm: NotesViewModel
    @StateObject var hsm = HighlightSearchModel()

    // Required (no default): a bare `NotesViewModel()` default expression is
    // evaluated as MainActor-isolated under this project's default actor
    // isolation, but this init itself must stay usable from a nonisolated
    // context, so it can't carry that default safely. ContentView.mainTabView
    // is the only call site and always passes StartupCoordinator's shared
    // instance so this screen's `.task` sees already-loaded (or in-flight)
    // data instead of firing a second fetch (see NotesViewModel.hasLoadedOnce).
    init(vm: NotesViewModel, bibleVM: BibleViewModel? = nil, embedded: Bool = false, fixedTab: NotesViewModel.NoteTab? = nil) {
        _vm = StateObject(wrappedValue: vm)
        self.bibleVM = bibleVM
        self.embedded = embedded
        self.fixedTab = fixedTab
    }

    /// iPad workspace: Notes and Highlights are separate dock tabs and may be
    /// visible at once, so each pins its own tab instead of sharing `vm.activeTab`.
    let fixedTab: NotesViewModel.NoteTab?
    var shownTab: NotesViewModel.NoteTab { fixedTab ?? vm.activeTab }
    /// Embedded search field is collapsed behind a header icon.
    @State var showEmbeddedSearch = false
    @State var refreshDismissed = false

    /// iPad workspace hosts this inside a tabbed panel whose tab strip already
    /// selects Notes vs Highlights, so the in-view toggle is hidden there.
    let embedded: Bool

    /// Task 20261011-ios-share-notes-highlights: StartupCoordinator's shared Bible
    /// model, used only to look up verse text when sharing a highlight (nil = share
    /// uses the text already on the row, if any).
    let bibleVM: BibleViewModel?

    @State var showEditor       = false
    @State var editingNote:     FSNote?  = nil
    @State var editingId:       String?  = nil
    @State var editingGroupId:  String   = ""
    @State var detailNote:      FSNote?  = nil
    /// Inline (iPad) editor context: a verse draft from the Bible reader, or a reply being edited.
    @State var inlineDraft:     VerseNoteDraft? = nil
    @State var inlineIsReply    = false
    @State var sharePayload:    SharePayload? = nil
    @State var chatShare:       ChatShareDraft? = nil   // task 20261012-share-verses-notes-in-chat
    @State var shareNotice:     String?  = nil

    /// iPad: open the inline editor for a verse handed over by the Bible reader.
    private func consumePendingNoteDraft() {
        guard embedded, fixedTab != .highlights, let draft = appState.pendingNoteDraft else { return }
        appState.pendingNoteDraft = nil
        editingNote    = nil
        editingId      = nil
        editingGroupId = ""
        inlineIsReply  = false
        inlineDraft    = draft
        showEditor     = true
    }

    var body: some View {
        ZStack(alignment: .top) {
            if !embedded {
            Theme.bgPage.ignoresSafeArea()

            // Warm bloom ground (shared visual language with the Dashboard).
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()
            }

            Group {
            if embedded && showEditor {
                // iPad workspace: editor replaces the list inside the Notes panel;
                // close/cancel/save returns to the list (task 20261014 addendum 5).
                NoteEditorView(
                    note:      editingNote,
                    noteId:    editingId,
                    groupId:   editingGroupId,
                    isReadOnly: false,
                    initialVerse: inlineDraft.map { VerseRef(book: $0.book, chapter: $0.chapter, verse: $0.verse) },
                    initialBodyHTML: inlineDraft.map { VerseNotePrefill.html(book: $0.book, chapter: $0.chapter, verse: $0.verse, text: $0.text) } ?? "",
                    onSave: { saved in
                        let uid = appState.currentUser?.user_id ?? ""
                        if inlineIsReply {
                            // A reply edit never goes through the notes list (it would show up
                            // as a top-level note); same direct PUT NoteDetailView's sheet uses.
                            do {
                                _ = try await vm.service.saveNote(saved, editingId: saved.id, userId: uid)
                                return nil
                            } catch {
                                return error.localizedDescription
                            }
                        }
                        let ok = await vm.saveNote(saved, editingId: editingId, userId: uid, authorUsername: appState.currentUser?.username ?? "")
                        if ok { return nil }
                        return vm.failedSaveMessage()
                    },
                    onClose: { showEditor = false; inlineDraft = nil; inlineIsReply = false }
                )
                .id((editingId ?? "new") + (inlineDraft?.id.uuidString ?? ""))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            VStack(spacing: 0) {
                header

                if !embedded {
                    notesHighlightsToggle
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }

                if shownTab == .notes {
                    if !embedded || showEmbeddedSearch {
                        NotesSearchField(text: $vm.searchText, isSearching: vm.isSearching)
                            .padding(.horizontal, embedded ? 14 : 20)
                            .padding(.top, embedded ? 6 : 14)
                    }

                    if !embedded {
                        groupChips
                            .padding(.top, 14)
                    }
                } else if !embedded || showEmbeddedSearch {
                    highlightSearchField
                        .padding(.horizontal, embedded ? 14 : 20)
                        .padding(.top, embedded ? 6 : 14)
                }

                // Visible, warm, non-blocking signal for a background
                // segment-refresh failure (task
                // 20260910-refresh-clobber-live-rootcause, spec item (d):
                // `refreshError` has existed since 20260905 but was never
                // wired to any UI -- exactly why the user had zero on-screen
                // signal across three prior "fixed" attempts at this bug).
                // Deliberately a plain inline row, not an `.alert` (unlike
                // `saveError` below) -- a background refresh hiccup shouldn't
                // block interaction with an already-populated screen (UI/UX
                // pref Q17: warm tone, minimal, never technical/redundant) --
                // and a fixed, friendly copy rather than the raw per-segment
                // diagnostic text `refreshError` carries internally, which
                // stays useful for logs/tests but reads as too technical for
                // this screen. Pull-to-refresh (already present) is the
                // retry path; no new control is added.
                if vm.refreshError != nil && embedded {
                    // iPad workspace: slim dismissible inline row so a background
                    // refresh hiccup does not dominate the dock.
                    if !refreshDismissed {
                        HStack(spacing: 8) {
                            Text("Some notes couldn\u{2019}t be refreshed just now.")
                                .font(.inter(Theme.fontXS)).foregroundColor(Theme.error).lineLimit(1)
                            Spacer(minLength: 0)
                            Button { refreshDismissed = true } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.error)
                                    .frame(width: 32, height: 32).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss")
                        }
                        .padding(.leading, 12)
                        .frame(height: 32)
                        .background(Theme.error.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
                        .padding(.horizontal, 14).padding(.top, 6)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Some notes couldn't be refreshed just now. Showing what's already loaded.")
                    }
                } else if vm.refreshError != nil {
                    Text("Some notes couldn\u{2019}t be refreshed just now — showing what\u{2019}s already loaded. Pull down to try again.")
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.spacingSM)
                        .padding(.vertical, Theme.spacingXS + 2)
                        .background(Theme.error.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .accessibilityLabel("Some notes couldn't be refreshed just now. Showing what's already loaded. Pull down to try again.")
                }

                if vm.isLoading {
                    Spacer()
                    ProgressView().tint(Theme.gold)
                    Spacer()
                } else {
                    switch shownTab {
                    case .notes:      notesTab
                    case .highlights: highlightsTabContent
                    }
                }
            }
            }
            }
            .blur(radius: inlineBackdropBlur)
            .allowsHitTesting(!inlineDetailShowing)
            .accessibilityHidden(inlineDetailShowing)

            inlineDetailLayer
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: detailNote?.id)
        .preference(key: InlineNoteEditorShowingKey.self, value: embedded && (showEditor || inlineDetailShowing))
        .onAppear { consumePendingNoteDraft() }
        .onChange(of: appState.pendingNoteDraft?.id) { _, _ in consumePendingNoteDraft() }
        .task {
            if let uid = appState.currentUser?.user_id {
                vm.configureSearch(userId: uid)
                hsm.configure(service: appState.service, userId: uid)
                await vm.load(service: appState.service, userId: uid)
            }
        }
        // Editor sheet — used by the context-menu "Edit" shortcut only.
        // The NoteDetailView → Edit path has its own sheet to avoid two
        // competing sheets on the same parent (which races on editingNote).
        .sheet(isPresented: Binding(get: { showEditor && !embedded }, set: { showEditor = $0 })) {
            NoteEditorView(
                note:      editingNote,
                noteId:    editingId,
                groupId:   editingGroupId,
                isReadOnly: false
            ) { saved in
                let uid = appState.currentUser?.user_id ?? ""
                let ok = await vm.saveNote(saved, editingId: editingId, userId: uid, authorUsername: appState.currentUser?.username ?? "")
                if ok { return nil }
                return vm.failedSaveMessage()
            }
        }
        // "Subscribe" on the upgrade prompt: close any note sheets so the Account tab shows.
        .onReceive(NotificationCenter.default.publisher(for: .fsOpenSubscriptionPlans)) { _ in
            showEditor = false
            detailNote = nil
        }
        // iPhone/compact keep the sheet; iPad regular width shows the detail inline
        // (see `inlineDetailLayer` in NotesListView+InlineDetail.swift).
        .sheet(item: inlineDetail ? Binding<FSNote?>.constant(nil) : $detailNote) { note in
            detailView(for: note, inline: false)
        }
        .shareSheet(item: $sharePayload)
        .chatShareSheet(item: $chatShare)
        .alert("Couldn't share", isPresented: Binding(
            get: { shareNotice != nil },
            set: { if !$0 { shareNotice = nil } }
        )) {
            Button("OK") { shareNotice = nil }
        } message: {
            Text(shareNotice ?? "")
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
