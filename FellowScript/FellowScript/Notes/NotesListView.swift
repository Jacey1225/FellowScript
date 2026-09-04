// SOURCE: components/NotesSidebar.jsx (NoteCard, HighlightCard, FilterPanel, group selector)
// KEY STATE: notes, highlights, groups, currentGroupId, activeTab, filteredNotes, showFilter
// INTERACTIONS: + to create, swipe-left to delete, tap to open, group picker, filter sheet
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift, NoteEditorView.swift

import SwiftUI
import Combine

/// Keyset-pagination bookkeeping for one notes "segment" -- Personal or a
/// single group -- mirroring the cursor a backend page's response carries.
/// Anchored on the segment's own last-seen (created_at, _id), not a row
/// position, so it stays correct even if notes are created/deleted
/// elsewhere in the segment between page loads.
private struct NotesPageState {
    var cursorCreatedAt: String? = nil
    var cursorId:        String? = nil
    var hasMore:          Bool   = true
}

@MainActor
final class NotesViewModel: ObservableObject {
    var service: DataServiceProtocol = MockDataService.shared

    @Published var notes:             [String: FSNote]    = [:]
    @Published var highlights:        [String: String]    = [:]
    @Published var groups:            [FSGroup]           = []
    @Published var currentGroupId:    String?             = nil {  // nil = Personal
        didSet {
            // Re-run an active search against the newly-selected segment --
            // search is segment-scoped exactly like filteredNotes, so
            // switching groups mid-search should re-query rather than keep
            // showing stale results from the old segment.
            guard currentGroupId != oldValue, isSearchActive else { return }
            scheduleSearch()
        }
    }
    @Published var activeTab:         NoteTab             = .notes
    @Published var sortOrder:         SortOrder           = .newest
    @Published var isLoading          = true
    // True while a scroll-triggered "next page" fetch for the current
    // segment (Personal or a group) is in flight -- guards against firing a
    // duplicate request while one is already running.
    @Published var isLoadingMore      = false

    // Keyed by "personal" for the Personal tab, or a group's id.
    private var pageState: [String: NotesPageState] = [:]
    private static let personalKey = "personal"
    private func segmentKey(for groupId: String?) -> String { groupId ?? Self.personalKey }

    /// True once the currently-displayed segment (Personal, or whichever
    /// group is selected) has a further backend page to fetch. Drives
    /// whether NotesListView shows its "loading more" footer at all.
    var hasMoreForCurrentSegment: Bool {
        pageState[segmentKey(for: currentGroupId)]?.hasMore ?? false
    }

    enum NoteTab: String, CaseIterable {
        case notes      = "Notes"
        case highlights = "Highlights"
    }

    enum SortOrder: String, CaseIterable {
        case newest = "Newest First"
        case oldest = "Oldest First"
    }

    var isFiltered: Bool {
        sortOrder != .newest
    }

    func resetFilters() {
        sortOrder = .newest
    }

    // Notes filtered and sorted per active settings. Display is group_id-only
    // (task 20260903-notes-public-repurpose): `public` no longer has any say
    // in which notes are shown -- only in whether a non-owner group member
    // may edit one, so the old VisibilityFilter (Private/Public Only) menu
    // and its filter branch here were removed entirely rather than repurposed.
    var filteredNotes: [(String, FSNote)] {
        let result = notes.filter { _, note in
            if let gid = currentGroupId {
                return note.group_id == gid
            } else {
                return note.group_id.isEmpty
            }
        }
        return result.sorted {
            sortOrder == .newest
                ? $0.value.timestamp > $1.value.timestamp
                : $0.value.timestamp < $1.value.timestamp
        }
    }

    var sortedHighlights: [FSHighlight] {
        highlights.map { FSHighlight.from(key: $0.key, color: $0.value) }
                  .sorted { $0.book < $1.book || ($0.book == $1.book && $0.chapter < $1.chapter) }
    }

    var currentGroupName: String {
        guard let gid = currentGroupId else { return "Personal" }
        return groups.first { $0.id == gid }?.title ?? "Group"
    }

    // Guards against a duplicate fetch when this instance is shared between
    // StartupCoordinator (which calls load() once up front to gate the
    // startup loading screen) and this screen's own `.task` (which also
    // calls load() the first time NotesListView is lazily mounted).
    private var hasLoadedOnce = false

    func load(service: DataServiceProtocol, userId: String) async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await fetchAndCache(service: service, userId: userId, showLoadingSpinner: true)
    }

    /// Pull-to-refresh entry point (task 20260831-interaction-polish-conventions):
    /// re-runs the exact same fetch+cache-write flow as `load()`, deliberately
    /// bypassing `hasLoadedOnce` — that guard exists only to stop a duplicate
    /// INITIAL fetch racing StartupCoordinator's own preload of this same
    /// view model, not to block a later, explicit, user-triggered
    /// pull-to-refresh. Keeps `showLoadingSpinner: false` so the screen's
    /// existing populated list stays on screen throughout — refreshing
    /// "behind" SwiftUI's own native `.refreshable` spinner — instead of
    /// flipping `isLoading` and replacing the whole list with this screen's
    /// full-screen "no data yet" spinner, which would lose scroll position
    /// (the "no regressions to existing scroll ... behavior" requirement).
    func refresh(service: DataServiceProtocol, userId: String) async {
        await fetchAndCache(service: service, userId: userId, showLoadingSpinner: false)
    }

    private func fetchAndCache(service: DataServiceProtocol, userId: String, showLoadingSpinner: Bool) async {
        self.service = service
        if showLoadingSpinner { isLoading = true }
        defer { if showLoadingSpinner { isLoading = false } }

        // ── Cache-first: show last-known data instantly, then revalidate ──────────
        if let cached: [String: FSNote] = await DiskCache.shared.load([String: FSNote].self, forKey: "notes:\(userId)") {
            notes = cached
            if showLoadingSpinner { isLoading = false }
        }
        if let cached: [String: String] = await DiskCache.shared.load([String: String].self, forKey: "highlights:\(userId)") {
            highlights = cached
        }
        if let cached: [FSGroup] = await DiskCache.shared.load([FSGroup].self, forKey: "groups:\(userId)") {
            groups = cached
        }

        // First page only (nil cursor) for Personal and every group -- the
        // backend caps each at NOTES_PAGE_SIZE (15) by the SQL query itself.
        async let notesTask    = try? service.fetchNotes(userId: userId, cursorCreatedAt: nil, cursorId: nil)
        async let hlTask       = try? service.fetchHighlights(userId: userId)
        async let contactsTask = try? service.fetchContacts(userId: userId)

        var allNotes: [String: FSNote] = [:]
        var newPageState: [String: NotesPageState] = [:]
        if let page = await notesTask {
            allNotes.merge(page.notes) { _, new in new }
            newPageState[Self.personalKey] = NotesPageState(
                cursorCreatedAt: page.nextCursorCreatedAt, cursorId: page.nextCursorId, hasMore: page.hasMore)
        }
        if let h = await hlTask { highlights = h }

        var loadedGroups: [FSGroup] = []
        if let (_, groupMap) = await contactsTask {
            loadedGroups = Array(groupMap.values).sorted { $0.title < $1.title }
            groups = loadedGroups
        }

        // Fetch each group's first page in parallel and merge into allNotes.
        await withTaskGroup(of: (String, NotesPage?).self) { group in
            for g in loadedGroups {
                group.addTask {
                    (g.id, try? await service.fetchGroupNotes(userId: userId, groupId: g.id, cursorCreatedAt: nil, cursorId: nil))
                }
            }
            for await (gid, page) in group {
                guard let page else { continue }
                allNotes.merge(page.notes) { _, new in new }
                newPageState[gid] = NotesPageState(
                    cursorCreatedAt: page.nextCursorCreatedAt, cursorId: page.nextCursorId, hasMore: page.hasMore)
            }
        }

        notes     = allNotes
        pageState = newPageState

        // ── Write fresh data back to the cache ────────────────────────────────────
        await DiskCache.shared.save(allNotes,   forKey: "notes:\(userId)")
        await DiskCache.shared.save(highlights, forKey: "highlights:\(userId)")
        await DiskCache.shared.save(groups,     forKey: "groups:\(userId)")
    }

    /// Fetches and appends the next backend-capped page of 15 for whichever
    /// segment (Personal or the selected group) is currently on screen,
    /// using that segment's own cursor -- never an offset counter, and no
    /// client-side slicing/capping anywhere in this path. Called when the
    /// last visible row scrolls into view. No-ops (rather than firing a
    /// duplicate request) if a fetch for this segment is already in flight,
    /// and stops once the segment's has_more is false -- the true end of
    /// that list, not just a short page.
    func loadMoreIfNeeded(userId: String) async {
        guard !isLoadingMore else { return }
        let key = segmentKey(for: currentGroupId)
        guard let state = pageState[key], state.hasMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let page: NotesPage?
        if let gid = currentGroupId {
            page = try? await service.fetchGroupNotes(
                userId: userId, groupId: gid,
                cursorCreatedAt: state.cursorCreatedAt, cursorId: state.cursorId)
        } else {
            page = try? await service.fetchNotes(
                userId: userId,
                cursorCreatedAt: state.cursorCreatedAt, cursorId: state.cursorId)
        }
        guard let page else { return }

        notes.merge(page.notes) { _, new in new }
        pageState[key] = NotesPageState(
            cursorCreatedAt: page.nextCursorCreatedAt, cursorId: page.nextCursorId, hasMore: page.hasMore)
    }

    // ── Keyword search (task 20260903-notes-keyword-search) ────────────────
    // Search is segment-scoped exactly like filteredNotes (Personal vs the
    // selected group) and queries the dedicated backend search endpoints --
    // bounded by the query itself, not paginated -- rather than filtering
    // `notes`, so results aren't silently capped to whatever pages happen
    // to already be loaded client-side (the whole point of this feature:
    // finding an older, not-yet-paginated-in note).
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var searchResults: [(String, FSNote)] = []
    @Published private(set) var isSearching = false

    private var searchTask: Task<Void, Never>? = nil
    private var searchUserId: String = ""
    // ~300ms: no specific value was requested by the spec; this is a
    // sensible default for a keystroke-driven live search that avoids
    // firing a network request per character.
    private static let searchDebounceNanoseconds: UInt64 = 300_000_000

    // Post-pass hardening (crash-investigation addendum, 2026-09-03): every
    // other cancellation site (scheduleSearch's own re-schedule, clearSearch)
    // already cancels searchTask, but nothing previously cancelled it if this
    // instance was deallocated while a debounce/search was still in flight
    // (e.g. StartupCoordinator.reset() swapping in a fresh NotesViewModel
    // mid-search). The in-flight Task already captures self weakly, so this
    // was never a retain-cycle/leak risk, but explicitly cancelling here is
    // correct hygiene -- it stops the pending debounce sleep or in-flight
    // network call promptly instead of letting it run to completion against
    // a nil weak self. Investigated a reported SIGABRT/malloc-corruption
    // crash in NotesViewModel deinit (via DashboardStaleReloadRegressionTests.
    // test_reset_recreatesDashboardVM_freshInstance_notReusingPreviousAccountsState,
    // surfaced by a different task's testing gate) but could not reproduce it
    // here across 8 separate runs (6x that test in isolation, the full
    // DashboardStaleReloadRegressionTests class, and a 13-class cluster run
    // covering every Notes*/Dashboard*/StartupCoordinator test file) -- all
    // passed cleanly. Adding this deinit regardless as defense-in-depth,
    // since it's a genuine (if previously harmless) gap either way.
    deinit {
        searchTask?.cancel()
    }

    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Called once (alongside `load`) from NotesListView's `.task` so every
    /// later debounced search knows which user to query without threading
    /// userId through every keystroke.
    func configureSearch(userId: String) {
        searchUserId = userId
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearchActive else {
            isSearching = false
            searchResults = []
            return
        }
        let query = searchText
        let gid = currentGroupId
        let uid = searchUserId
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.runSearch(query: query, groupId: gid, userId: uid)
        }
    }

    private func runSearch(query: String, groupId: String?, userId: String) async {
        guard !userId.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }

        let matches: [String: FSNote]
        if let gid = groupId {
            matches = (try? await service.searchGroupNotes(userId: userId, groupId: gid, query: query)) ?? [:]
        } else {
            matches = (try? await service.searchNotes(userId: userId, query: query)) ?? [:]
        }
        guard !Task.isCancelled else { return }
        // Guard against a slow response landing after the user has since
        // changed the query or cleared search entirely (query != searchText
        // means a newer keystroke/debounce already superseded this result).
        guard query == searchText, isSearchActive else { return }
        searchResults = matches.sorted {
            sortOrder == .newest
                ? $0.value.timestamp > $1.value.timestamp
                : $0.value.timestamp < $1.value.timestamp
        }
    }

    /// Clears the query and any in-flight/completed search state, returning
    /// the Notes tab to the normal unfiltered, paginated list with nothing
    /// left lingering (per the "no lingering state bugs" acceptance
    /// criterion).
    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        isSearching = false
    }

    @Published var saveError: String? = nil

    func saveNote(_ note: FSNote, editingId: String?, userId: String) async -> Bool {
        print("[VM] saveNote called — editingId=\(editingId ?? "nil") text.count=\(note.text.count) text.prefix=\(note.text.prefix(60))")
        do {
            let savedId = try await service.saveNote(note, editingId: editingId, userId: userId)
            var updated = note; updated.id = savedId
            notes[savedId] = updated
            print("[VM] saveNote succeeded — savedId=\(savedId)")
            return true
        } catch {
            print("[VM] saveNote FAILED — \(error)")
            saveError = error.localizedDescription
            return false
        }
    }

    // `isOwnNote` (task 20260829-notes-edit-author-gate): the UI already
    // hides the swipe/context-menu Delete affordance for a group note the
    // caller doesn't author (NotesListView.canModify), so this should always
    // be true by the time this is called. Guarding here too is
    // defense-in-depth, deny-by-default: a non-author delete attempt now
    // no-ops entirely rather than optimistically vanishing the note from the
    // local `notes` dict before the backend's real 403 rejection lands —
    // previously it removed the note client-side unconditionally and
    // swallowed that rejection via `try?`, so the note misleadingly stayed
    // gone from the caller's own list until the next full reload.
    func deleteNote(id: String, userId: String, isOwnNote: Bool) async {
        guard isOwnNote else { return }
        let previous = notes[id]
        notes.removeValue(forKey: id)
        do {
            try await service.deleteNote(noteId: id, userId: userId)
        } catch {
            // Revert the optimistic removal -- contrast with saveHighlight/
            // clearHighlight right below, which already do/catch, revert,
            // and set saveError on failure (compile-errors #2).
            if let previous { notes[id] = previous }
            saveError = error.localizedDescription
        }
    }

    func saveHighlight(book: String, chapter: Int, verse: Int, color: String, userId: String) async {
        let key = "\(book)-\(chapter)-\(verse)"
        let previous = highlights[key]
        highlights[key] = color   // optimistic
        do {
            try await service.saveHighlight(userId: userId, book: book, chapter: chapter, verse: verse, color: color)
        } catch {
            // Revert the optimistic mutation and surface the real failure —
            // saveHighlight now uses checkedRequestRaw, so a rejected write
            // (expired session, free-tier limit, etc.) throws instead of
            // silently looking like it succeeded.
            if let previous { highlights[key] = previous } else { highlights.removeValue(forKey: key) }
            saveError = error.localizedDescription
        }
    }

    func clearHighlight(key: String, userId: String) async {
        let previous = highlights[key]
        highlights.removeValue(forKey: key)   // optimistic
        do {
            try await service.clearHighlight(userId: userId, key: key)
        } catch {
            if let previous { highlights[key] = previous }
            saveError = error.localizedDescription
        }
    }
}

// ── Root notes list ───────────────────────────────────────────────────────────
struct NotesListView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm: NotesViewModel

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

    @State private var showEditor       = false
    @State private var editingNote:     FSNote?  = nil
    @State private var editingId:       String?  = nil
    @State private var editingGroupId:  String   = ""
    @State private var detailNote:      FSNote?  = nil

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
            NoteDetailView(
                note:     note,
                userId:   appState.currentUser?.user_id ?? "",
                username: appState.currentUser?.username ?? "",
                service:  vm.service
            ) { saved in
                let uid = appState.currentUser?.user_id ?? ""
                let ok = await vm.saveNote(saved, editingId: note.id, userId: uid)
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

    // ── Header: filter/sort menu · title · new note ───────────────────────────
    // The reference's hamburger opens the (already-built) sort/visibility menu
    // rather than a non-existent side menu, so no functionality is lost.
    private var header: some View {
        HStack {
            Menu {
                Section("Sort") {
                    ForEach(NotesViewModel.SortOrder.allCases, id: \.self) { order in
                        Button(action: { vm.sortOrder = order }) {
                            Label(order.rawValue, systemImage: vm.sortOrder == order ? "checkmark" : "arrow.up.arrow.down")
                        }
                    }
                }
                if vm.isFiltered {
                    Divider()
                    Button(role: .destructive, action: { vm.resetFilters() }) {
                        Label("Clear Filters", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Circle()
                    .strokeBorder(Theme.parchment.opacity(0.18), lineWidth: 1)
                    .background(Circle().fill(Theme.parchment.opacity(0.08)))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundColor(vm.isFiltered ? Theme.goldLight : Theme.parchment.opacity(0.8))
                    )
            }
            .accessibilityLabel("Filter and sort notes")

            Spacer()
            Text("Notes")
                .font(.system(size: 27, weight: .heavy))
                .foregroundColor(Theme.parchment)
            Spacer()

            Button(action: startNewNote) {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundColor(Color(hex: "#24170A")))
                    .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 6)
            }
            .accessibilityLabel("Create new note")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // ── Notes / Highlights gold segmented toggle ──────────────────────────────
    private var notesHighlightsToggle: some View {
        HStack(spacing: 4) {
            toggleSegment(.notes, "Notes")
            toggleSegment(.highlights, "Highlights")
        }
        .padding(5)
        .background(
            Capsule().fill(Theme.parchment.opacity(0.07))
                .overlay(Capsule().stroke(Theme.parchment.opacity(0.13), lineWidth: 1))
        )
    }

    private func toggleSegment(_ tab: NotesViewModel.NoteTab, _ label: String) -> some View {
        let isActive = vm.activeTab == tab
        return Button(action: { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { vm.activeTab = tab } }) {
            Text(label)
                .font(.system(size: 14.5, weight: .heavy))
                .foregroundColor(isActive ? Color(hex: "#24170A") : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    isActive
                        ? LinearGradient(colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // ── Group filter chips (Personal + each group) ────────────────────────────
    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Personal", id: nil)
                ForEach(vm.groups) { group in
                    chip(title: group.title, id: group.id)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func chip(title: String, id: String?) -> some View {
        let selected = vm.currentGroupId == id
        Button(action: { withAnimation(.easeOut(duration: 0.18)) { vm.currentGroupId = id } }) {
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(selected ? Color(hex: "#24170A") : Theme.parchment.opacity(0.7))
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(
                    selected
                        ? LinearGradient(colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [Theme.parchment.opacity(0.07), Theme.parchment.opacity(0.07)], startPoint: .leading, endPoint: .trailing)
                )
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.parchment.opacity(0.14), lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // ── Notes tab ─────────────────────────────────────────────────────────────
    // While a search is active, the segment-scoped search results (already a
    // flat, non-paginated match set from the backend -- see
    // NotesViewModel.runSearch) replace the normal paginated `filteredNotes`
    // list entirely, so pagination/loadMoreIfNeeded never fires for search
    // results. Clearing search (NotesViewModel.isSearchActive false again)
    // falls straight back through to the untouched original list path below.
    private var notesTab: some View {
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
    private var searchNoResultsState: some View {
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
    private func notesList(_ items: [(String, FSNote)], enablePagination: Bool) -> some View {
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
    private var highlightsTab: some View {
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

    private var notesEmptyState: some View {
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

    private func startNewNote() {
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
    private func canDelete(_ note: FSNote) -> Bool {
        Self.isAuthor(of: note, currentUsername: appState.currentUser?.username)
    }

    // Edit is a strictly wider gate than Delete (task
    // 20260903-notes-public-repurpose): a non-author group member may also
    // edit (never delete) a group note whose author left `public`
    // (edit-permission) on -- the server enforces the identical split
    // between update_note's new non-owner branch and delete_note's
    // still-owner-only gate; this only drives which affordance(s) appear.
    private func canEdit(_ note: FSNote) -> Bool {
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

// ── Notes search field (task 20260903-notes-keyword-search) ──────────────────
// Custom-styled to this app's glass/gold visual language (UI/UX pref Q12:
// build custom to fit the synthesized visual system, not a bare/system
// `.searchable()`/SearchBar skin) -- mirrors ChatRootView.ChatSearchField's
// same capsule/glass treatment, plus a plain-spinner loading affordance
// (UI/UX pref Q17) swapped in for the magnifying-glass icon while a
// debounced query is in flight, and a subtle functional fade on the clear
// button's appearance (UI/UX pref Q18: functional, not purely decorative).
private struct NotesSearchField: View {
    @Binding var text: String
    var isSearching: Bool

    var body: some View {
        HStack(spacing: 9) {
            if isSearching {
                ProgressView()
                    .tint(Theme.parchment.opacity(0.5))
                    .scaleEffect(0.75)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.parchment.opacity(0.4))
            }
            TextField("", text: $text, prompt: Text("Search notes")
                .foregroundColor(Theme.parchment.opacity(0.4)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.parchment)
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Search notes")
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.parchment.opacity(0.35))
                }
                .transition(.opacity)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Capsule().fill(Theme.parchment.opacity(0.06)))
        .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: text.isEmpty)
    }
}

// ── Note row (mirrors NoteCard in NotesSidebar.jsx) ───────────────────────────
struct NoteRow: View {
    let note: FSNote

    // Author chip shows only for group-segment notes with a successfully
    // captured author username — never for Personal notes (always the
    // viewer, so an identity chip is just noise) and never a placeholder
    // for a group note whose username failed to decode/capture (an honest
    // "no chip" is a harmless diagnostic signal, not a bug to paper over).
    private var showsAuthorChip: Bool { !note.group_id.isEmpty && !note.username.isEmpty }

    // Edit-permission indicator (task 20260903-notes-public-repurpose,
    // step 5): `note.public` no longer means "visible" -- it means "other
    // group members may edit this note" -- so, like the web NoteCard badge,
    // it's only meaningful (and only shown) on a group note. A Personal note
    // has no other group member who could edit it regardless of this flag,
    // so no indicator renders there at all (unlike the old globe/lock
    // visibility cue, which intentionally applied to both segments).
    private var showsEditableIndicator: Bool { !note.group_id.isEmpty && note.public }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 16.5, weight: .heavy))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                Spacer()
                if showsAuthorChip {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.gold.opacity(0.14))
                            .overlay(Circle().stroke(Theme.gold.opacity(0.32), lineWidth: 1))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Text(String(note.username.prefix(1)).uppercased())
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(Theme.goldLight)
                            )
                        Text(note.username)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(Theme.parchment.opacity(0.75))
                            .lineLimit(1)
                    }
                }
            }

            let validVerses = note.verses.filter { $0.count >= 3 }
            if !validVerses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(validVerses.enumerated()), id: \.offset) { _, v in
                            Text(verseLabel(v))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Theme.goldLight)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Theme.gold.opacity(0.14))
                                .overlay(Capsule().stroke(Theme.gold.opacity(0.32), lineWidth: 1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Text(note.preview.isEmpty ? "No content" : note.preview)
                .font(.system(size: 13))
                .foregroundColor(Theme.parchment.opacity(0.62))
                .lineLimit(2)

            HStack(spacing: 5) {
                Text(note.formattedTimestamp)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                if showsEditableIndicator {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.goldLight.opacity(0.8))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(showsEditableIndicator
                ? "\(note.formattedTimestamp), editable by group"
                : note.formattedTimestamp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .glassCard(cornerRadius: 20)
    }

    private func verseLabel(_ components: [FSVerseComponent]) -> String {
        guard components.count >= 3 else { return "" }
        return "\(components[0].asString) \(components[1].asString):\(components[2].asString)"
    }
}

// ── Highlight row (mirrors HighlightCard) ─────────────────────────────────────
struct HighlightRow: View {
    let highlight: FSHighlight

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            Circle()
                .fill(Color(hex: highlight.color))
                .frame(width: 10, height: 10)
                .shadow(color: .black.opacity(0.30), radius: 2)
                .accessibilityHidden(true)
            Text("\(highlight.book) \(highlight.chapter):\(highlight.verse)")
                .font(.verseRef(Theme.fontBody))
                .foregroundColor(Theme.gold)
            Spacer()
            if let name = highlight.username {
                Text(name)
                    .font(.inter(Theme.fontXXS))
                    .foregroundColor(Theme.gold.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.gold.opacity(0.10))
                    .clipShape(Capsule())
            }
            // Subtle affordance signalling the row opens the verse.
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.gold.opacity(0.40))
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.spacingXS)
    }
}

// ── Note detail sheet ─────────────────────────────────────────────────────────
// Direction B ("Elevated CTA, lighter chrome") of the approved restyle —
// see .claude/pipeline/20260813-note-viewer-mockups/design-notes.md. Adopts
// the warm-bloom background for family resemblance with NoteEditorView/
// ChatRootView/Dashboard, but intentionally skips the glass-card body
// wrapper (this is read-only content — a long note's reading column stays
// full width) and promotes Edit to a solid gradient CTA pill against a
// secondary ghost-outline Close, mirroring AccountView's pill hierarchy.
// Appearance only — every interaction below is byte-for-byte unchanged.
struct NoteDetailView: View {
    let note:   FSNote

    // ── Reply data-layer wiring (task 20260828-note-reply-continuation-ios) ──
    // Defaulted (not required) so every existing call site/test that only
    // supplies note+onSave keeps compiling unchanged — in particular
    // NoteDetailViewDirectionBTests, which hosts this view directly via
    // ViewHosting with no AppState in the environment. Deliberately plain
    // stored properties rather than @EnvironmentObject var appState: AppState
    // for the same reason, mirroring the existing
    // BlockedUsersView(userId:service:) pattern instead. The real call site
    // (NotesListView's `.sheet(item: $detailNote)`) passes all three from its
    // own `appState`. Declared before `onSave` below (not after) so that
    // trailing-closure call sites -- both the pre-existing
    // `NoteDetailView(note: note) { ... }` and the new
    // `NoteDetailView(note:userId:username:service:) { ... }` -- resolve the
    // trailing closure to `onSave` correctly: it stays the last
    // non-defaulted (required) stored property in the synthesized init.
    var userId:   String              = ""
    var username: String              = ""
    var service:  DataServiceProtocol = MockDataService.shared

    // Returns nil on success, or an error message on failure (mirrors
    // NoteEditorView.onSave so a content-filter rejection keeps both sheets open).
    let onSave: (FSNote) async -> String?

    @Environment(\.dismiss) private var dismiss
    // Not `private` (unlike NoteEditorView's analogous @State vars) so
    // FellowScriptTests can assert on it directly after simulating an Edit
    // tap via ViewInspector — see NoteDetailViewDirectionBTests.swift. No
    // runtime behavior difference; access-control only.
    @State var showEditor = false

    // Toolbar button actions, extracted to named methods (task
    // 20260829-note-detail-toolbar-visual-fix) rather than inline closures.
    // Not `private`, for the same reason `showEditor` above isn't: this
    // toolbar's `ToolbarItem`s now carry `.suppressAutomaticGlassChrome()`
    // (task 20260902-ios-deployment-target-lower's iOS-26-only-gated wrapper
    // around what was `.sharedBackgroundVisibility(.hidden)` directly — the
    // fix for the doubled system/custom pill outline), and ViewInspector
    // 0.10.3 cannot traverse a `ToolbarItem` wrapped in that modifier down to
    // its `Button` (confirmed live — it reports an opaque
    // `ModifiedContent<ToolbarItem, PlatterVisibilityModifier>` it doesn't
    // know how to unwrap, for both `.toolbar().item(_)` and a plain
    // `find(button:)`). Exposing the exact same action closures the buttons
    // call lets tests still exercise the real dismiss()/showEditor wiring
    // without simulating a tap through that now-unreachable wrapper. No
    // runtime behavior difference from the previous inline closures.
    internal func closeAction() { dismiss() }
    internal func editAction()  { showEditor = true }

    // Gates the toolbar Edit pill (task 20260829-notes-edit-author-gate,
    // extended by 20260903-notes-public-repurpose step 5): this view
    // previously showed Edit unconditionally, despite already having both
    // `note.username` (the author, used by NoteRow's showsAuthorChip) and
    // `username` (the viewer, passed in from the call site) available to
    // compare. A group note is editable by its author, OR by any group
    // member (mirroring the server's update_note non-owner branch) when the
    // note's own `public` flag grants group-edit permission; a personal note
    // (no group_id) needs no check — always self-authored already.
    // Deny-by-default: an empty/undecoded `note.username` or `username` for
    // a group note hides Edit rather than assuming authorship, mirroring
    // NoteRow.showsAuthorChip's same fallback -- the public-flag branch below
    // is purely additive on top of that, never a way around it.
    internal var canEdit: Bool {
        guard !note.group_id.isEmpty else { return true }
        if note.public { return true }
        guard !note.username.isEmpty, !username.isEmpty else { return false }
        return note.username == username
    }

    // ── Reply section state ───────────────────────────────────────────────
    // Group notes only (mid-task product-intent correction, task
    // 20260828-note-reply-continuation-ios): replies are a group-note-only
    // feature, not a personal-notes one, despite backend step 1 having added
    // a personal-notes GET-replies route and NetworkService.fetchReplies
    // being able to call it -- NoteDetailView itself never invokes that
    // branch (isGroupNote guards both the fetch and the render below).
    private var isGroupNote: Bool { !note.group_id.isEmpty }
    @State private var replies:            [FSNote] = []
    // True once a load attempt has actually completed (success or failure)
    // for a group note -- gates the whole section so it never flashes
    // "REPLIES · 0" or stale content before the fetch resolves. Stays false
    // forever for a personal note, which is fine: isGroupNote already gates
    // the section before repliesLoaded is even consulted.
    @State private var repliesLoaded       = false
    @State private var showAllReplies      = false
    @State private var showReplyComposer   = false

    private var displayedReplies: [FSNote] {
        showAllReplies ? replies : Array(replies.prefix(5))
    }

    // Test-only hook (ViewInspector's documented minimal-intrusion pattern
    // for inspecting @State after an interaction — never set outside
    // NoteDetailViewDirectionBTests.swift; inert in production since nothing
    // assigns it). No behavior change: `.onAppear` below is a no-op unless a
    // test supplies a closure.
    internal var didAppear: ((Self) -> Void)?

    // Test-only hook, ViewInspector's "Approach #2" (Inspection.swift) —
    // added for task 20260828-note-reply-continuation-ios, testing step,
    // since `didAppear` above only fires once at `.onAppear`, before the
    // async `.task(id:)` reply fetch below has had a chance to resolve.
    // `sut.inspection.inspect(after:)` lets tests observe the view after a
    // real time gap once `replies`/`repliesLoaded` have actually settled.
    // Inert in production: `.onReceive` below is a no-op unless a test
    // registers a callback via `inspection.inspect(...)`.
    // Gated to Debug (task 20260902-ios-deployment-target-lower), matching
    // Inspection.swift's own `#if DEBUG` — see that file for why (test-only
    // scaffolding that also happens to trigger a Release/WMO compiler crash
    // at the lowered 18.0 deployment target). Tests build against Debug, so
    // this is a no-op change for FellowScriptTests/FellowScriptUITests.
    #if DEBUG
    internal let inspection = Inspection<Self>()
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                // Warm bloom ground (shared visual language with Dashboard/
                // Chat/Notes/NoteEditorView) — identical hex/opacity/anchor/
                // radius to ChatRootView.swift:41-46 / NoteEditorView.swift:82-87.
                RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                               center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                    .ignoresSafeArea()
                RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                               center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                    .ignoresSafeArea()

                ScrollView {
                    // No glassCard wrapper (per Direction B) — body flows
                    // directly on the bloom background, full width, same
                    // structure as before, just re-themed.
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        Text(note.title.isEmpty ? "Untitled" : note.title)
                            .font(.playfair(Theme.fontDisplayMD))
                            .foregroundColor(Theme.parchment)

                        if !note.formattedTimestamp.isEmpty {
                            sectionLabel(note.formattedTimestamp)
                        }

                        Rectangle()
                            .fill(Theme.goldGradient)
                            .frame(height: 1)

                        NoteHTMLView(html: note.text)

                        // ── Replies (Option A "Continuation" — task
                        // 20260828-note-reply-continuation-ios). Group notes
                        // only, per mid-task product-intent correction: a
                        // personal note (group_id empty) renders exactly as
                        // it did before this task, no fetch, no section.
                        // Also gated on repliesLoaded so a still-in-flight
                        // fetch never flashes "REPLIES · 0" -- an
                        // unresolved/absent state behaves like the empty
                        // state, and neither branch below renders before
                        // repliesLoaded is true. Reply UI is earned by
                        // content, never rendered speculatively.
                        //
                        // Zero-replies empty state (task
                        // 20260829-notes-first-reply-empty-state): the prior
                        // task's own gating made a zero-reply group note
                        // render nothing at all below the note body -- no
                        // way to start the first reply, despite the backend
                        // write path already handling that case fine. The
                        // hairline/label/card-list/"See all" machinery below
                        // stays gated on !replies.isEmpty exactly as before
                        // (still correctly earned-by-content), but the
                        // composer entry point itself is no longer inside
                        // that same gate -- it now always renders once a
                        // group note's replies have loaded, with a minimal
                        // muted line standing in for the earned content when
                        // there isn't any yet. Per the UI/UX preference
                        // profile's empty-state guidance (minimal, not
                        // illustrated), this reuses ghostPill/
                        // showReplyComposer/postReplyDraft verbatim rather
                        // than introducing anything new.
                        if isGroupNote && repliesLoaded {
                            if !replies.isEmpty {
                                Rectangle()
                                    .fill(Theme.goldGradient)
                                    .frame(height: 1)

                                repliesSectionLabel(replies.count)

                                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                                    ForEach(displayedReplies) { reply in
                                        replyCard(reply)
                                    }
                                }

                                if replies.count > 5 && !showAllReplies {
                                    Button { showAllReplies = true } label: {
                                        ghostPill("See all \(replies.count)")
                                            .frame(minHeight: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Text("No replies yet.")
                                    .font(.inter(Theme.fontSM))
                                    .foregroundColor(Theme.textMuted)
                            }

                            // Composer affordance is likewise group-notes-only
                            // -- POST /notes/reply/{note_id} technically
                            // already accepts replies to personal notes
                            // (pre-existing backend behavior, unrelated to
                            // this task), but this UI never newly exposes
                            // that path. Reachable in both the populated and
                            // zero-reply branches above.
                            Button { showReplyComposer = true } label: {
                                ghostPill("Add a reply")
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.spacingLG)
                }
                // Content-edge feather (task
                // 20260830-note-detail-scroll-fade-toolbar-bg): the user's
                // actual ask, corrected from the prior
                // 20260829-note-detail-toolbar-edge-blur task, which feathered
                // the TOOLBAR's own background instead -- the real hard,
                // ruler-straight cutoff (IMG_3048.png, attached to this
                // request) is the note title/body's own scrolling content
                // disappearing abruptly as it passes under the nav bar.
                // `.mask` is applied to the ScrollView itself (not to content
                // inside it), so the gradient is anchored to the ScrollView's
                // fixed on-screen frame rather than scrolling with the
                // content -- that's what makes text sliding toward the top
                // fade out smoothly instead of hitting a hard clip edge.
                // Fixed 120pt height (nav bar ~44pt + top safe-area/Dynamic
                // Island inset, generously covering both across device
                // sizes) rather than a GeometryReader-derived
                // `safeAreaInsets.top` -- mask content isn't reliably in the
                // same safe-area context as the view it masks, so a
                // hand-picked constant is the more predictable, purpose-fit
                // choice here (Q12 component philosophy: custom over
                // reaching for a generic/derived mechanism whose behavior
                // isn't verified). Fades to fully transparent well before the
                // Close/Edit pills' row, which is also what makes the toolbar
                // background removal below safe: there's no legible text
                // left to visually collide with the pills by the time
                // content is that close to the top, replacing the old
                // toolbar-tint gradient's collision-guard duty without
                // needing a separate non-visible guard.
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.55), location: 0.55),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 120)
                        Color.black
                    }
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // .sharedBackgroundVisibility(.hidden) (task
                // 20260829-note-detail-toolbar-visual-fix): confirmed live
                // (Simulator screenshot) that iOS 26 wraps each ToolbarItem's
                // content in its own automatic Liquid Glass capsule chrome
                // -- including its own border -- layered on top of whatever
                // the item draws, regardless of `.buttonStyle(.plain)`
                // (already applied below). That produced a visibly doubled
                // outline on both pills: the system's automatic glass
                // capsule stroke plus ghostPill/gradientPill's own deliberate
                // stroke. Per this app's established "build custom, don't
                // skin a system primitive" component philosophy, this hides
                // the automatic glass background instead of stripping the
                // app's own pill stroke -- same technique NoteEditorView's
                // analogous cancelChip/doneChip sidestep by simply never
                // living inside a ToolbarItem at all.
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: closeAction) {
                        ghostPill("Close", compact: true)
                    }
                    .buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                if canEdit {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: editAction) {
                            gradientPill("Edit", compact: true)
                        }
                        .buttonStyle(.plain)
                    }
                    .suppressAutomaticGlassChrome()
                }
            }
            // R1 (critique polish, task 20260828-note-reply-continuation-ios),
            // corrected by task 20260829-note-detail-toolbar-visual-fix,
            // feathered by task 20260829-note-detail-toolbar-edge-blur,
            // removed outright by task
            // 20260830-note-detail-scroll-fade-toolbar-bg: NoteDetailView had
            // no scroll-edge treatment at all before R1, so long-note body
            // text could visibly scroll under/collide with the Close/Edit
            // toolbar pills. Through R1 and the two 08-29 tasks, the fix was
            // always some flavor of a visible tint/gradient painted behind
            // the toolbar via `.toolbarBackground` -- first plain
            // `.ultraThinMaterial` (rejected live for compositing as a flat
            // neutral-gray band against this screen's warm amber-bloom
            // background), then a flat warm tint, then a top-opaque/
            // bottom-clear gradient version of that same tint. All three
            // versions produced a visible, distinct band behind the
            // Close/Edit pills, which is exactly what this task's request
            // asked to remove entirely -- "no distinct visible background
            // band at all," pills reading as sitting directly on the bloom.
            //
            // That's safe now because the anti-scroll-collision duty this
            // background always also carried has moved to a different
            // mechanism: the `.mask` feather on the ScrollView above (see
            // its comment) fades note content to fully transparent well
            // before it reaches the pills' row, so there's no legible text
            // left for the pills to visually collide with by the time
            // content is that close to the top -- no separate non-visible
            // guard (inset, reduced-opacity scrim, etc.) is needed alongside
            // it. Confirmed by direct source read that `.toolbarBackground`
            // and `.sharedBackgroundVisibility(.hidden)` (on both
            // `ToolbarItem`s below) are unrelated, independent modifiers --
            // hiding this background has no bearing on the doubled-outline
            // fix; that fix stays exactly as `20260829-note-detail-toolbar-visual-fix`
            // left it.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // Editor sheet lives here — note is a guaranteed let constant,
            // so NoteEditorView always receives the correct content.
            .sheet(isPresented: $showEditor) {
                NoteEditorView(
                    note:       note,
                    noteId:     note.id,
                    groupId:    note.group_id,
                    isReadOnly: false
                ) { saved in
                    let msg = await onSave(saved)
                    if msg == nil { dismiss() }
                    return msg
                }
                // Root cause of the Save/Cancel overlap regression (task
                // 20260810-note-editor-save-cancel-overlap-v2), confirmed via
                // a screenshot captured mid-investigation: a sheet presented
                // from a view that is itself already inside a sheet (this
                // "sheet-on-a-sheet" path, as opposed to NotesListView's own
                // direct, single-level .sheet) can genuinely — at the real
                // UIKit level, not just a SwiftUI layout-proposal quirk —
                // adopt a small, centered "form sheet" compact-adaptation
                // presentation instead of the normal near-full-screen "page
                // sheet" style, racy across launches. .presentationDetents
                // alone (kept below) did not reliably prevent this — .large
                // only controls which DETENT a resizable sheet rests at, not
                // which ADAPTATION style is used when the presentation
                // context is compact/nested, which is the actual thing
                // going wrong here. .presentationCompactAdaptation(.fullScreenCover)
                // explicitly overrides that adaptation so the nested sheet
                // always renders full-screen, matching the direct
                // (non-nested) sheet's behavior instead of racily falling
                // back to a small form-sheet card.
                .presentationDetents([.large])
                .presentationCompactAdaptation(.fullScreenCover)
            }
            .sheet(isPresented: $showReplyComposer) {
                ReplyComposerSheet(onPost: postReplyDraft)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { didAppear?(self) }
        // Group notes only -- see isGroupNote. `.task(id:)` re-fires if the
        // sheet is ever re-hosted for a different note (item-presented
        // sheets already tear down/rebuild per note, but id: is a cheap,
        // correct guard either way) and is a no-op for a personal note.
        .task(id: note.id) {
            await loadReplies()
        }
        #if DEBUG
        .onReceive(inspection.notice) { self.inspection.visit(self, $0) }
        #endif
    }

    // ── Replies: data ──────────────────────────────────────────────────────
    private func loadReplies() async {
        guard isGroupNote, !userId.isEmpty else { repliesLoaded = false; return }
        let fetched = (try? await service.fetchReplies(
            userId: userId, noteId: note.id, groupId: note.group_id)) ?? []
        replies = fetched
        repliesLoaded = true
    }

    /// Posts via the existing `POST /notes/reply/{note_id}` route (wired in
    /// step 2) and appends the returned id locally rather than refetching --
    /// the same optimistic id-swap pattern `NotesViewModel.saveNote` already
    /// uses for the main note save round-trip. Returns nil on success, or an
    /// error message the composer sheet shows inline (mirrors onSave above).
    private func postReplyDraft(_ text: String) async -> String? {
        guard isGroupNote, !userId.isEmpty else {
            return "Replies aren't available for this note."
        }
        var draft = FSNote()
        draft.user     = userId
        draft.username = username
        draft.text     = text
        draft.group_id = note.group_id
        draft.is_reply = true
        do {
            let id = try await service.postReply(draft, noteId: note.id)
            draft.id = id
            draft.timestamp = ISO8601DateFormatter().string(from: Date())
            replies.append(draft)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // ── Replies: section label ─────────────────────────────────────────────
    // Distinct from the shared top-level `sectionLabel(_:)` (DashboardView.swift)
    // used for the date eyebrow above -- the design spec calls for a heavier
    // weight/larger size/brighter color for this one (SemiBold 12pt, tracking
    // ~1.2, full-opacity textGold) rather than reusing that helper's XXS/
    // tracking-5/textGoldMuted styling verbatim.
    private func repliesSectionLabel(_ count: Int) -> some View {
        Text("REPLIES · \(count)")
            .font(.inter(Theme.fontXS, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundColor(Theme.textGold)
    }

    // ── Replies: card ───────────────────────────────────────────────────────
    private func replyCard(_ reply: FSNote) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            if !reply.username.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    replyMonogram(reply.username)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reply.username)
                            .font(.interScaled(Theme.fontSM, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        if !reply.formattedTimestamp.isEmpty {
                            Text("·")
                                .font(.interScaled(Theme.fontXS))
                                .foregroundColor(Theme.textGold.opacity(0.5))
                            Text(reply.formattedTimestamp)
                                .font(.interScaled(Theme.fontXS))
                                .foregroundColor(Theme.textGold)
                        }
                    }
                }
            } else if !reply.formattedTimestamp.isEmpty {
                // Author-less reply (username empty) -- a real, documented
                // state (Models.swift:183-189), not hypothetical: omit the
                // monogram + name entirely and show only the timestamp.
                Text(reply.formattedTimestamp)
                    .font(.interScaled(Theme.fontXS))
                    .foregroundColor(Theme.textGold)
            }

            // R3 (critique polish): real inter-paragraph spacing via
            // Theme.spacingSM between paragraph Text views (this VStack's
            // uniform spacing), rather than one dense block with zero gap
            // between paragraphs.
            ForEach(Array(replyParagraphs(reply.text).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.interScaled(Theme.fontBody))
                    .foregroundColor(Theme.textPrimary)
                    .lineSpacing(7)   // ~1.45 line-height at a 16pt base size
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetCard(padding: Theme.spacingMD)
    }

    private func replyMonogram(_ username: String) -> some View {
        Circle()
            .fill(Theme.goldGradient)
            .frame(width: 28, height: 28)
            .overlay(
                Text(String(username.prefix(1)).uppercased())
                    .font(.inter(Theme.fontSM, weight: .bold))
                    .foregroundColor(Color(hex: "#24170A"))
            )
    }

    /// Splits reply body text into paragraphs (critique R3). Reply cards use
    /// Inter sans-serif per the design spec, not NoteHTMLView (which forces
    /// serif Lora at 19px), so this does its own light HTML-paragraph-aware
    /// split rather than routing through that view: `</p>`/`<br>`-family tags
    /// (present if a reply was composed with rich formatting elsewhere in the
    /// app) become paragraph breaks, any remaining tags are stripped, and
    /// blank paragraphs are dropped. Plain text with no tags at all just
    /// falls through as a single paragraph, unchanged.
    private func replyParagraphs(_ text: String) -> [String] {
        var normalized = text
        for tag in ["</p>", "<br>", "<br/>", "<br />", "</div>"] {
            normalized = normalized.replacingOccurrences(of: tag, with: "\n\n", options: .caseInsensitive)
        }
        normalized = normalized.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.isEmpty
            ? [text.trimmingCharacters(in: .whitespacesAndNewlines)]
            : paragraphs
    }

    // ── Pill controls (AccountView idiom — AccountView.swift:1554-1576 —
    // reused as local view-scoped helpers here since those are `private`
    // instance methods on AccountView itself, the same pattern NoteEditorView
    // already follows for its own cancelChip/doneChip icon-chip helpers) ────
    private func gradientPill(_ title: String, compact: Bool = false) -> some View {
        Text(title)
            .font(.inter(compact ? Theme.fontXS : Theme.fontSM, weight: .semibold))
            .foregroundColor(Color(hex: "#24170A"))
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? 32 : 36)
            .background(
                LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Capsule())
    }

    private func ghostPill(_ title: String, compact: Bool = false,
                            labelColor: Color = Theme.textSecondary,
                            strokeColor: Color = Theme.parchment.opacity(0.14)) -> some View {
        Text(title)
            .font(.inter(compact ? Theme.fontXS : Theme.fontSM))
            .foregroundColor(labelColor)
            // The leading toolbar slot proposes a very narrow width on iOS
            // 26 (as if sizing for a single icon), which without this wraps
            // "Close" letter-by-letter and truncates it. fixedSize forces
            // the text to report/keep its natural single-line width instead
            // of accepting that narrow proposal.
            .fixedSize()
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 32 : 36)
            // Explicit (near-invisible) fill, not just a stroke overlay —
            // AccountView's original ghostPill is stroke-only, which is fine
            // in normal body content but collapses to a circular icon slot
            // when used as toolbar item content on iOS 26: without an opaque
            // background shape, the toolbar's Liquid Glass layout has no
            // real width to size against and truncates the label.
            .background(Capsule().fill(Theme.parchment.opacity(0.04)))
            .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
    }
}

// ── Reply composer sheet ──────────────────────────────────────────────────────
// Visual redesign (task 20260903-notes-reply-submenu-restyle): migrated off
// the plain Form/Section layout onto the same warm-bloom-ground +
// widgetCard() + PillButton/ghost-chip-Cancel recipe already established for
// AddFriendSheet (Chat/ChatRootView.swift) and EventSetupSheet's Details step
// (Account/EventSetupSheet.swift) — this was the one submenu sheet the two
// prior redesign tasks (20260902-submenu-visual-redesign,
// 20260902-submenu-followup-polish) missed. Single-field shape mirrors
// AddFriendSheet directly (caption + one field, Cancel leading / primary
// action trailing) rather than reusing the full rich-text NoteEditorView,
// which is scoped to notes, not replies. Group-notes-only gating
// (NoteDetailView.isGroupNote / postReplyDraft) all lives in the caller —
// this sheet is presentation-agnostic.
private struct ReplyComposerSheet: View {
    /// Returns nil on success (dismisses), or an error message shown inline.
    let onPost: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    // A reply composer is a distinct, independent editing session from any
    // open NoteEditorView, so it gets its own controller instance rather
    // than sharing one (task 20260903-notes-reply-rich-text).
    @StateObject private var rtc = RichTextEditorController()
    @State private var isPosting = false
    @State private var errorMessage: String?
    @State private var showColorPicker = false

    // Fallback chain mirrors NoteEditorView.handleSave(): prefer the live
    // UITextView content, then the tracked @Published value, then a
    // plain-text-to-<br> fallback read straight from the live text view —
    // defense against transient empty-string conditions. A reply has no
    // prior note text to fall back to, so the final fallback is "".
    private func extractedHTML() -> String {
        let liveHTML    = rtc.currentHTML()
        let trackedHTML = rtc.htmlOutput
        let tvText      = rtc.textView?.text ?? ""
        if !liveHTML.isEmpty {
            return liveHTML
        } else if !trackedHTML.isEmpty {
            return trackedHTML
        } else if !tvText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tvText
                .replacingOccurrences(of: "\u{2029}", with: "<br>")
                .replacingOccurrences(of: "\u{2028}", with: "<br>")
                .replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\r", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
        } else {
            return ""
        }
    }

    private var canPost: Bool {
        !extractedHTML().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPosting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingLG) {
                    // ── Format toolbar (verbatim from NoteEditorView's
                    // toolbar, adapted to this sheet's compact layout — no
                    // isReadOnly gate since a reply composer is always
                    // editable, no verse/title affordances since a reply
                    // has neither) ───────────────────────────────────────
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FormatButton(label: "Bold",      bold: true,           isActive: rtc.isBold)         { rtc.toggleBold() }
                            FormatButton(label: "Italic",    italic: true,         isActive: rtc.isItalic)       { rtc.toggleItalic() }
                            FormatButton(label: "Underline", underline: true,      isActive: rtc.isUnderline)    { rtc.toggleUnderline() }
                            FormatButton(label: "Highlight", highlightStyle: true, isActive: rtc.isHighlight)    { rtc.toggleHighlight() }

                            // Color button: lights up when cursor is in custom-colored text.
                            // Clicking while active resets the color; otherwise opens the picker.
                            FormatButton(label: "Text color", colorBar: true, isActive: rtc.hasCustomColor) {
                                if rtc.hasCustomColor { rtc.resetColor() }
                                else { showColorPicker.toggle() }
                            }

                            if showColorPicker {
                                // Reset to default
                                Button {
                                    showColorPicker = false
                                    rtc.resetColor()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Theme.parchment.opacity(0.50))
                                        .font(.system(size: 24))
                                }
                                ForEach(Array(zip(Theme.highlightColors, Theme.highlightHex)), id: \.1) { color, hex in
                                    Button {
                                        showColorPicker = false
                                        rtc.applyTextColor(UIColor(color))
                                    } label: {
                                        Circle()
                                            .fill(color)
                                            .frame(width: 28, height: 28)
                                            .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5))
                                            .shadow(color: color.opacity(0.45), radius: 4, x: 0, y: 2)
                                    }
                                    .transition(.scale.combined(with: .opacity))
                                    .accessibilityLabel("Apply \(hex) color")
                                }
                            }
                        }
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.vertical, 10)
                    }
                    .animation(.spring(response: 0.25), value: showColorPicker)
                    .glassCard(cornerRadius: 16)

                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("REPLY")
                            .font(.inter(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)

                        // Body — rich text editor. Same ZStack structure as
                        // NoteEditorView: the placeholder Text stays in the
                        // ZStack unconditionally so SwiftUI never recreates
                        // the UIViewRepresentable and resets htmlOutput.
                        ZStack(alignment: .topLeading) {
                            Text("Write a reply…")
                                .font(.inter(Theme.fontBody))
                                .foregroundColor(Theme.textMuted)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                                .opacity(rtc.htmlOutput.isEmpty ? 1 : 0)
                            RichTextEditorView(
                                controller:  rtc,
                                initialHTML: "",
                                placeholder: "Write a reply…"
                            )
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .accessibilityLabel("Reply text")
                        }
                    }
                    .glassCard(cornerRadius: 20)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.interScaled(Theme.fontSM))
                            .foregroundColor(Theme.error)
                    }
                }
                .padding(Theme.spacingLG)
            }
            .warmBloomBackground()
            // Shared keyboard-dismiss convention (task
            // 20260831-interaction-polish-conventions) — this sheet's
            // rich-text editor is the reply body.
            .dismissesKeyboardOnScrollAndTap()
            .navigationTitle("Add a Reply")
            .navigationBarTitleDisplayMode(.inline)
            // Follow-up polish recipe (ChatRootView.swift's AddFriendSheet /
            // EventSetupSheet's Details step): ghost-chip Cancel leading,
            // gold PillButton primary action trailing, a `.principal` title
            // item so "Add a Reply" centers independent of the asymmetric
            // Cancel/Post widths (the exact shape that caused visible
            // off-centering last time), and `.suppressAutomaticGlassChrome()`
            // on both custom items so iOS 26's automatic Liquid Glass toolbar
            // chrome doesn't double up against each item's own capsule/pill
            // chrome.
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) { cancelGhostChip }
                        .buttonStyle(.plain)
                        .disabled(isPosting)
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .principal) {
                    Text("Add a Reply")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    PillButton(title: isPosting ? "Posting…" : "Post") {
                        Task {
                            isPosting = true
                            errorMessage = await onPost(extractedHTML())
                            isPosting = false
                            if errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(!canPost)
                }
                .suppressAutomaticGlassChrome()
            }
        }
        .preferredColorScheme(.dark)
    }

    // Ghost-chip Cancel label (see ChatRootView.swift's sheetGhostCancelLabel
    // for the shared recipe/rationale comment -- bespoke per-sheet copy here
    // rather than a new cross-file shared component, matching
    // EventSetupSheet's cancelGhostChip precedent).
    private var cancelGhostChip: some View {
        Text("Cancel")
            .font(.inter(Theme.fontSM))
            .foregroundColor(Theme.textSecondary)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Theme.parchment.opacity(0.06)))
            .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
    }
}

