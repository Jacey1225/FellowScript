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
    @Published var highlights:     [FSHighlight]           = []
    @Published var bookmarks:      [FSBookmark]            = []
    @Published var agents:         [FSAgent]               = []
    @Published var lastAgentMsg:   FSAgentMessage?         = nil
    @Published var isLoading       = true
    // Editorial Hero's Friend Activity card + check-in nudge — GET
    // /friends/{userId}/activity, a new targeted endpoint alongside this
    // view's existing per-resource calls (see backend step 2 of this task:
    // consolidating the other 5 was out of scope, this is the read surface
    // that didn't exist at all before).
    @Published var friendActivity: FSFriendActivityFeed    = .empty

    // Redesign-derived, all from real data (see load()).
    @Published var myGroups:       [GroupSummary]          = []
    @Published var notesThisWeek:  [Int]                   = Array(repeating: 0, count: 7)
    @Published var revisitVerse:   FSHighlight?            = nil
    @Published var lastReadTarget: BibleNavTarget?         = nil
    @Published var subtitleLine:   String                  = ""

    func load(service: DataServiceProtocol, userId: String) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }

        // Synchronous, local-only fields render instantly (before any fetch).
        lastReadTarget = decodeLastRead()

        // ── Cache-first: warm the cards from last-known data ─────────────────────
        if let cached: [String: FSNote] = await DiskCache.shared.load([String: FSNote].self, forKey: "notes:\(userId)") {
            notes = cached
            isLoading = false
        }
        if let cachedHl: [String: String] = await DiskCache.shared.load([String: String].self, forKey: "highlights:\(userId)") {
            highlights = cachedHl.map { FSHighlight.from(key: $0.key, color: $0.value) }.sorted { $0.book < $1.book }
        }
        if let cached: [FSAgent] = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(userId)") {
            agents = cached
        }
        if let cached: FSAgentMessage = await DiskCache.shared.load(FSAgentMessage.self, forKey: "lastAgentMsg:\(userId)") {
            lastAgentMsg = cached
        }
        if let cached: FSFriendActivityFeed = await DiskCache.shared.load(FSFriendActivityFeed.self, forKey: "friendActivity:\(userId)") {
            friendActivity = cached
        }
        recomputeDerived()

        // ── Fresh fetch (all via the injected service — the real backend) ────────
        // Notes here are only ever used for the "this week" sparkline and the
        // most-recent-note card, both of which read fine off the first
        // backend-capped page (15, newest first) -- this view doesn't need
        // to page through the full collection like NotesListView does.
        async let notesTask          = try? service.fetchNotes(userId: userId, cursorCreatedAt: nil, cursorId: nil)
        async let hlTask             = try? service.fetchHighlights(userId: userId)
        async let bookmarksTask      = try? service.fetchBookmarks(userId: userId)
        async let agentsTask         = try? service.fetchAgents(userId: userId)
        async let contactsTask       = try? service.fetchContacts(userId: userId)
        async let friendActivityTask = try? service.fetchFriendActivity(userId: userId)

        notes  = (await notesTask)?.notes ?? [:]
        agents = (await agentsTask) ?? []

        var hlDict: [String: String] = [:]
        if let hl = await hlTask {
            hlDict = hl
            highlights = hl.map { FSHighlight.from(key: $0.key, color: $0.value) }.sorted { $0.book < $1.book }
        }
        if let bm = await bookmarksTask {
            bookmarks = bm.map { FSBookmark.from(key: $0.key, label: $0.value) }.sorted { $0.book < $1.book }
        }

        // Last agent message for the (still-supported) agent quick action.
        if let firstAgent = agents.first,
           let msgs = try? await service.fetchAgentMessages(userId: userId, agentId: firstAgent.id) {
            lastAgentMsg = msgs.last
        }

        let (contactList, _) = (await contactsTask) ?? ([], [:])
        myGroups = buildMyGroups(contacts: contactList)
        friendActivity = (await friendActivityTask) ?? .empty
        recomputeDerived()

        // ── Write fresh data back to the shared cache ────────────────────────────
        await DiskCache.shared.save(notes,  forKey: "notes:\(userId)")
        await DiskCache.shared.save(agents, forKey: "agents:\(userId)")
        await DiskCache.shared.save(hlDict, forKey: "highlights:\(userId)")
        if let m = lastAgentMsg { await DiskCache.shared.save(m, forKey: "lastAgentMsg:\(userId)") }
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
            recomputeDerived()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // ── Derivations (pure, from already-loaded data) ─────────────────────────────

    private func recomputeDerived() {
        notesThisWeek = computeNotesThisWeek()
        revisitVerse  = pickRevisit()
        subtitleLine  = computeSubtitle()
    }

    private func buildMyGroups(contacts: [FSContact]) -> [GroupSummary] {
        contacts.filter { $0.type == .group }.map { c in
            let initials = c.memberNames.prefix(3).map { String($0.prefix(1)).uppercased() }
            let count    = max(c.memberNames.count, c.toUsers.count)
            return GroupSummary(
                id:             c.id,
                title:          c.name.isEmpty ? "Group" : c.name,
                subtitle:       count == 1 ? "1 member" : "\(count) members",
                memberInitials: initials.isEmpty ? [String((c.name.isEmpty ? "G" : c.name).prefix(1)).uppercased()] : Array(initials)
            )
        }
    }

    private func computeNotesThisWeek() -> [Int] {
        // index 0 = 6 days ago … index 6 = today (chronological, for the sparkline).
        var buckets = Array(repeating: 0, count: 7)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for n in notes.values {
            guard let d = Self.parseDate(n.timestamp) else { continue }
            let day  = cal.startOfDay(for: d)
            let diff = cal.dateComponents([.day], from: day, to: today).day ?? 99
            if diff >= 0 && diff < 7 { buckets[6 - diff] += 1 }
        }
        return buckets
    }

    private func pickRevisit() -> FSHighlight? {
        if let h = highlights.randomElement() { return h }
        // Fallback: a bookmark (chapter-level) presented as a verse-1 target.
        if let b = bookmarks.randomElement() {
            return FSHighlight(id: b.id, book: b.book, chapter: b.chapter, verse: 1, color: "#D4922A", username: nil)
        }
        return nil
    }

    private func computeSubtitle() -> String {
        let weekCount  = notesThisWeek.reduce(0, +)
        let notePhrase = weekCount == 1 ? "1 note this week" : "\(weekCount) notes this week"
        if let t = lastReadTarget {
            return "Last read \(t.book) \(t.chapter) · \(notePhrase)"
        }
        return notePhrase
    }

    private func decodeLastRead() -> BibleNavTarget? {
        guard let data = UserDefaults.standard.data(forKey: "fs_bible_pos"),
              let pos  = try? JSONDecoder().decode([String: String].self, from: data),
              let book = pos["book"], !book.isEmpty
        else { return nil }
        let chapter = Int(pos["chapter"] ?? "1") ?? 1
        return BibleNavTarget(book: book, chapter: chapter, verse: 1)
    }

    private static func parseDate(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// ── Dashboard root ────────────────────────────────────────────────────────────
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = DashboardViewModel()
    @State private var showNewNote    = false
    @State private var showResumeNote = false
    @State private var showAgentChat  = false

    private func openFriendChat(id: String, username: String) {
        appState.pendingChatContact = FSContact(id: id, name: username, type: .friend)
    }

    // Quick actions are built from availability so there are never dead buttons.
    private var quickActions: [QuickAction] {
        var actions: [QuickAction] = [
            QuickAction(label: "New note", symbol: "square.and.pencil", tint: Theme.gold) {
                showNewNote = true
            },
            QuickAction(label: "Read", symbol: "book", tint: Color(hex: "#6DBF7E")) {
                appState.pendingBibleNav = vm.lastReadTarget ?? BibleNavTarget(book: "John", chapter: 1, verse: 1)
            },
        ]
        if !vm.agents.isEmpty {
            actions.append(QuickAction(label: "Ask agent", symbol: "sparkles", tint: Color(hex: "#7EB8E0")) {
                showAgentChat = true
            })
        }
        return actions
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
                    HeroHeader(username: appState.currentUser?.username ?? "friend",
                               subtitle: vm.subtitleLine)

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

                    if let verse = vm.revisitVerse {
                        RevisitVerseCard(verse: verse) {
                            appState.pendingBibleNav = BibleNavTarget(book: verse.book, chapter: verse.chapter, verse: verse.verse)
                        }
                    }

                    if !vm.bookmarks.isEmpty {
                        BookmarksWidget(bookmarks: vm.bookmarks) { b in
                            appState.pendingBibleNav = BibleNavTarget(book: b.book, chapter: b.chapter, verse: 1)
                        }
                    }

                    HStack(spacing: 12) {
                        NotesSparklineCard(counts: vm.notesThisWeek)
                        HighlightsCountCard(highlights: vm.highlights)
                    }
                    .padding(.horizontal, 20)

                    if !vm.myGroups.isEmpty {
                        MyGroupsRow(groups: vm.myGroups)
                    }

                    QuickActionsRow(actions: quickActions)
                }
                .padding(.bottom, 150) // clears the floating tab bar
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
        .sheet(isPresented: $showAgentChat) {
            if let a = vm.agents.first { AgentChatView(agent: a) }
        }
    }
}

// ── Shared section label (also used by ChatThreadView / BibleReaderView) ───────
@ViewBuilder
func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.lora(Theme.fontXXS))
        .tracking(5)
        .textCase(.uppercase)
        .foregroundColor(Theme.textGoldMuted)
}
