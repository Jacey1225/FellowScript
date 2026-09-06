// Notes/NotesViewModel.swift — NotesListView's view model (notes/highlights/
// groups state, pagination, keyword search, save/delete). Split out of
// NotesListView.swift (readability #6, 20260904-frontend-arch-sweep): that
// file combined this view model with several unrelated view structs in one
// 2000+-line file. Pure file-organization move -- same type, same behavior,
// no interface change. See NotesListView.swift's header comment for the
// full split rationale and the list of sibling files.

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

    // filteredNotes (below) is derived from notes/sortOrder/currentGroupId,
    // so each one's didSet recomputes the cached result (optimization sweep
    // #5) instead of filteredNotes being a computed property SwiftUI re-runs
    // on every render of NotesListView -- every search-field keystroke,
    // every unrelated @State toggle -- the way it was before.
    @Published var notes:             [String: FSNote]    = [:] {
        didSet { recomputeFilteredNotes() }
    }
    @Published var highlights:        [String: String]    = [:]
    @Published var groups:            [FSGroup]           = []
    @Published var currentGroupId:    String?             = nil {  // nil = Personal
        didSet {
            guard currentGroupId != oldValue else { return }
            recomputeFilteredNotes()
            // Re-run an active search against the newly-selected segment --
            // search is segment-scoped exactly like filteredNotes, so
            // switching groups mid-search should re-query rather than keep
            // showing stale results from the old segment.
            if isSearchActive { scheduleSearch() }
        }
    }
    @Published var activeTab:         NoteTab             = .notes
    @Published var sortOrder:         SortOrder           = .newest {
        didSet { recomputeFilteredNotes() }
    }
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
    //
    // Memoized (optimization sweep #5): this used to be a computed property,
    // re-filtering + re-sorting the full `notes` dict on every SwiftUI render
    // of NotesListView. It's now a cached, published value recomputed only by
    // `recomputeFilteredNotes()` below, invoked from the didSet of each of
    // its three real dependencies (notes/sortOrder/currentGroupId) -- so a
    // render caused by, say, a keystroke in the search field or the editor
    // sheet toggling no longer re-does this work at all.
    @Published private(set) var filteredNotes: [(String, FSNote)] = []

    private func recomputeFilteredNotes() {
        let result = notes.filter { _, note in
            if let gid = currentGroupId {
                return note.group_id == gid
            } else {
                return note.group_id.isEmpty
            }
        }
        filteredNotes = result.sorted {
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
        //
        // Personal notes' outcome is captured as a `Result` (task
        // 20260905-notes-group-refresh-clobber-rootcause), not collapsed via
        // `try?`, so a thrown fetch failure's real error reaches the merge
        // logic below instead of being flattened to a bare `nil` that's
        // indistinguishable from "nothing went wrong" -- needed both for the
        // splice decision (unchanged: still skip-and-keep-stale on any
        // failure) and for the new `refreshError` visibility signal.
        // Highlights/groups aren't "segments" in the pageState/splice sense
        // this task is scoped to, so those two stay on the existing `try?`
        // pattern untouched.
        async let notesResult: Result<NotesPage, Error> = {
            do { return .success(try await service.fetchNotes(userId: userId, cursorCreatedAt: nil, cursorId: nil)) }
            catch { return .failure(error) }
        }()
        async let hlTask       = try? service.fetchHighlights(userId: userId)
        async let contactsTask = try? service.fetchContacts(userId: userId)

        // Bug fix (task 20260904-notes-group-refresh-null-data): this used to
        // build `allNotes`/`newPageState` from a fresh empty accumulator and
        // then unconditionally overwrite `notes`/`pageState` with it, even
        // though a failed personal-notes fetch or an individual failed
        // group's `fetchGroupNotes` call (`try?` collapses either to nil,
        // and the loop below's `guard let page else { continue }` simply
        // skipped merging that segment) meant the accumulator never had that
        // segment's data in it -- so one transient fetch failure silently
        // wiped that segment's (or, if the personal fetch failed, every
        // group's) already-good notes down to nothing. Mirrors the
        // DashboardViewModel.load() fix (20260901-dashboard-stale-reload-ui):
        // only ever splice a segment's fresh result into `notes`/`pageState`
        // on that segment's own proven (non-nil) success; a segment whose
        // fetch fails this round simply keeps whatever was already there.
        //
        // Root-cause correction (task 20260905-notes-group-refresh-clobber-rootcause):
        // that 20260904 fix was correct as far as it went, but it only guarded
        // against a fetch that actually *threw*. NetworkService.fetchNotes/
        // fetchGroupNotes' own decode-failure branches never threw -- they
        // fabricated a technically-successful, non-throwing EMPTY NotesPage on
        // a hard decode failure, indistinguishable right here from "the
        // segment is genuinely empty now". A group's manual JSONSerialization
        // parsing has far more silent-failure branches than personal notes'
        // single strongly-typed JSONDecoder path, which is exactly why
        // *group* refreshes were the ones observed clobbering to empty in
        // practice while personal mostly wasn't. Fixed at the source
        // (NetworkService+Notes.swift now throws on those decode failures
        // instead of returning a fabricated empty page) -- once a
        // non-throwing result is honest by construction, this splice logic's
        // existing "only trust a proven success" semantics are sufficient
        // and remain unchanged below; what's new is that a real thrown error
        // now also feeds the `refreshError` signal instead of vanishing.
        var freshNotes: [String: FSNote] = [:]
        var newPageState = pageState
        var personalSucceeded = false
        var segmentErrors: [String] = []
        switch await notesResult {
        case .success(let page):
            freshNotes.merge(page.notes) { _, new in new }
            newPageState[Self.personalKey] = NotesPageState(
                cursorCreatedAt: page.nextCursorCreatedAt, cursorId: page.nextCursorId, hasMore: page.hasMore)
            personalSucceeded = true
        case .failure(let error):
            segmentErrors.append("Personal: \(error.localizedDescription)")
        }
        if let h = await hlTask { highlights = h }

        var loadedGroups: [FSGroup] = []
        if let (_, groupMap) = await contactsTask {
            loadedGroups = Array(groupMap.values).sorted { $0.title < $1.title }
            groups = loadedGroups
        }

        // Fetch each group's first page in parallel and merge into freshNotes.
        // Same Result-capture rationale as personal notes above.
        var succeededGroupIds: Set<String> = []
        await withTaskGroup(of: (String, String, Result<NotesPage, Error>).self) { group in
            for g in loadedGroups {
                let gid = g.id
                let title = g.title
                group.addTask {
                    do {
                        let page = try await service.fetchGroupNotes(userId: userId, groupId: gid, cursorCreatedAt: nil, cursorId: nil)
                        return (gid, title, .success(page))
                    } catch {
                        return (gid, title, .failure(error))
                    }
                }
            }
            for await (gid, title, result) in group {
                switch result {
                case .success(let page):
                    freshNotes.merge(page.notes) { _, new in new }
                    newPageState[gid] = NotesPageState(
                        cursorCreatedAt: page.nextCursorCreatedAt, cursorId: page.nextCursorId, hasMore: page.hasMore)
                    succeededGroupIds.insert(gid)
                case .failure(let error):
                    // this group's fetch failed this round -- leave its existing notes/pageState alone
                    segmentErrors.append("\(title): \(error.localizedDescription)")
                }
            }
        }

        // Splice: drop the existing entries for only the segments that
        // actually succeeded this round (so their stale notes don't linger
        // alongside the fresh ones), then merge in those segments' fresh
        // notes. Any segment that failed -- or, for a group, was never even
        // attempted because contactsTask itself failed -- keeps its prior
        // notes/pageState untouched, exactly matching the acceptance bar.
        var mergedNotes = notes
        if personalSucceeded {
            mergedNotes = mergedNotes.filter { !$0.value.group_id.isEmpty }
        }
        if !succeededGroupIds.isEmpty {
            mergedNotes = mergedNotes.filter { !succeededGroupIds.contains($0.value.group_id) }
        }
        mergedNotes.merge(freshNotes) { _, new in new }

        notes     = mergedNotes
        pageState = newPageState

        // Visible, non-blocking signal (Q26/Q27 preference profile) for any
        // segment whose fetch threw this round -- see `refreshError`'s own
        // doc comment above for why this is a distinct property from
        // `saveError` rather than a reuse of it. Cleared back to nil on a
        // round with no segment failures so a stale message doesn't linger
        // past the refresh that fixed it.
        refreshError = segmentErrors.isEmpty ? nil : segmentErrors.joined(separator: "; ")

        // ── Write fresh data back to the cache ────────────────────────────────────
        await DiskCache.shared.save(mergedNotes, forKey: "notes:\(userId)")
        await DiskCache.shared.save(highlights,  forKey: "highlights:\(userId)")
        await DiskCache.shared.save(groups,      forKey: "groups:\(userId)")
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

        // Audited per task 20260905-notes-group-refresh-clobber-rootcause for
        // the same clobber gap `fetchAndCache` had: this path was never
        // actually at risk of it -- it only ever *appends* into the existing
        // `notes` dict via `merge`, and a failed fetch simply returns early
        // (below) leaving `pageState`/`hasMore` untouched, so the next scroll
        // just retries the same page. The one real gap here was the same
        // Q26 one shared with `fetchAndCache`: a thrown decode/network
        // failure was silently swallowed by `try?` with no visible signal at
        // all. Switched to do/catch so that failure now feeds the same
        // `refreshError` signal instead of vanishing.
        do {
            let page: NotesPage
            if let gid = currentGroupId {
                page = try await service.fetchGroupNotes(
                    userId: userId, groupId: gid,
                    cursorCreatedAt: state.cursorCreatedAt, cursorId: state.cursorId)
            } else {
                page = try await service.fetchNotes(
                    userId: userId,
                    cursorCreatedAt: state.cursorCreatedAt, cursorId: state.cursorId)
            }
            notes.merge(page.notes) { _, new in new }
            pageState[key] = NotesPageState(
                cursorCreatedAt: page.nextCursorCreatedAt, cursorId: page.nextCursorId, hasMore: page.hasMore)
        } catch {
            refreshError = error.localizedDescription
        }
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

    /// Visible, non-blocking signal for a background segment-refresh failure
    /// (task 20260905-notes-group-refresh-clobber-rootcause, per the
    /// Q26/Q27 preference-profile stance: surface swallowed fetch errors
    /// rather than leaving them fully silent). Deliberately a separate
    /// property from `saveError` even though it follows the exact same
    /// simple `Published String?` shape -- `saveError` already drives
    /// NotesListView's blocking "Save Failed" alert tied to the save/editor
    /// flow, and reusing it here would pop that same alert during an
    /// unrelated background pull-to-refresh. Set by `fetchAndCache`/
    /// `loadMoreIfNeeded` when a segment's fetch throws; cleared back to nil
    /// once a subsequent round has no segment failures, so a stale message
    /// doesn't linger past the refresh that fixed it. Whether/how this
    /// renders in the UI (banner/toast vs. left unbound for now) is left to
    /// whichever view-layer pass wires it up -- this task is scoped to
    /// NetworkService+Notes.swift and NotesViewModel.swift.
    @Published var refreshError: String? = nil

    func saveNote(_ note: FSNote, editingId: String?, userId: String) async -> Bool {
        print("[VM] saveNote called — editingId=\(editingId ?? "nil") text.count=\(note.text.count)")
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
