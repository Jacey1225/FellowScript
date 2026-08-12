// SOURCE: components/NotesSidebar.jsx (NoteCard, HighlightCard, FilterPanel, group selector)
// KEY STATE: notes, highlights, groups, currentGroupId, activeTab, filteredNotes, showFilter
// INTERACTIONS: + to create, swipe-left to delete, tap to open, group picker, filter sheet
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift, NoteEditorView.swift

import SwiftUI
import Combine

@MainActor
final class NotesViewModel: ObservableObject {
    var service: DataServiceProtocol = MockDataService.shared

    @Published var notes:             [String: FSNote]    = [:]
    @Published var highlights:        [String: String]    = [:]
    @Published var groups:            [FSGroup]           = []
    @Published var currentGroupId:    String?             = nil   // nil = Personal
    @Published var activeTab:         NoteTab             = .notes
    @Published var sortOrder:         SortOrder           = .newest
    @Published var visibilityFilter:  VisibilityFilter    = .all
    @Published var isLoading          = true

    enum NoteTab: String, CaseIterable {
        case notes      = "Notes"
        case highlights = "Highlights"
    }

    enum SortOrder: String, CaseIterable {
        case newest = "Newest First"
        case oldest = "Oldest First"
    }

    enum VisibilityFilter: String, CaseIterable {
        case all     = "All Notes"
        case privateOnly = "Private Only"
        case publicOnly  = "Public Only"
    }

    var isFiltered: Bool {
        sortOrder != .newest || visibilityFilter != .all
    }

    func resetFilters() {
        sortOrder        = .newest
        visibilityFilter = .all
    }

    // Notes filtered and sorted per active settings
    var filteredNotes: [(String, FSNote)] {
        var result = notes.filter { _, note in
            if let gid = currentGroupId {
                return note.group_id == gid
            } else {
                return note.group_id.isEmpty
            }
        }
        switch visibilityFilter {
        case .all:         break
        case .privateOnly: result = result.filter { !$0.value.public }
        case .publicOnly:  result = result.filter {  $0.value.public }
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

    func load(service: DataServiceProtocol, userId: String) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }

        // ── Cache-first: show last-known data instantly, then revalidate ──────────
        if let cached: [String: FSNote] = await DiskCache.shared.load([String: FSNote].self, forKey: "notes:\(userId)") {
            notes = cached
            isLoading = false
        }
        if let cached: [String: String] = await DiskCache.shared.load([String: String].self, forKey: "highlights:\(userId)") {
            highlights = cached
        }
        if let cached: [FSGroup] = await DiskCache.shared.load([FSGroup].self, forKey: "groups:\(userId)") {
            groups = cached
        }

        async let notesTask    = try? service.fetchNotes(userId: userId)
        async let hlTask       = try? service.fetchHighlights(userId: userId)
        async let contactsTask = try? service.fetchContacts(userId: userId)

        var allNotes: [String: FSNote] = [:]
        if let n = await notesTask { allNotes.merge(n) { _, new in new } }
        if let h = await hlTask    { highlights = h }

        var loadedGroups: [FSGroup] = []
        if let (_, groupMap) = await contactsTask {
            loadedGroups = Array(groupMap.values).sorted { $0.title < $1.title }
            groups = loadedGroups
        }

        // Fetch notes for every group in parallel and merge into allNotes.
        await withTaskGroup(of: [String: FSNote].self) { group in
            for g in loadedGroups {
                group.addTask {
                    (try? await service.fetchGroupNotes(userId: userId, groupId: g.id)) ?? [:]
                }
            }
            for await batch in group {
                allNotes.merge(batch) { _, new in new }
            }
        }

        notes = allNotes

        // ── Write fresh data back to the cache ────────────────────────────────────
        await DiskCache.shared.save(allNotes,   forKey: "notes:\(userId)")
        await DiskCache.shared.save(highlights, forKey: "highlights:\(userId)")
        await DiskCache.shared.save(groups,     forKey: "groups:\(userId)")
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

    func deleteNote(id: String, userId: String) async {
        notes.removeValue(forKey: id)
        try? await service.deleteNote(noteId: id, userId: userId)
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
    @StateObject private var vm = NotesViewModel()

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
            NoteDetailView(note: note) { saved in
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
                Section("Visibility") {
                    ForEach(NotesViewModel.VisibilityFilter.allCases, id: \.self) { filter in
                        Button(action: { vm.visibilityFilter = filter }) {
                            Label(filter.rawValue, systemImage: vm.visibilityFilter == filter ? "checkmark" : "eye")
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
    private var notesTab: some View {
        Group {
            if vm.filteredNotes.isEmpty {
                notesEmptyState
            } else {
                List {
                    ForEach(vm.filteredNotes, id: \.0) { id, note in
                        NoteRow(note: note)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            .onTapGesture { detailNote = note }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    let uid = appState.currentUser?.user_id ?? ""
                                    Task { await vm.deleteNote(id: id, userId: uid) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") {
                                    editingNote    = note
                                    editingId      = id
                                    editingGroupId = note.group_id
                                    showEditor     = true
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    let uid = appState.currentUser?.user_id ?? ""
                                    Task { await vm.deleteNote(id: id, userId: uid) }
                                }
                            }
                            .accessibilityLabel("Note: \(note.title.isEmpty ? "Untitled" : note.title). \(note.preview)")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 10, for: .scrollContent)
                .contentMargins(.bottom, 100, for: .scrollContent)
            }
        }
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
                        .font(.lora(Theme.fontSM))
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
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 10, for: .scrollContent)
                .contentMargins(.bottom, 100, for: .scrollContent)
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
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
            } else {
                Text("No notes in \(vm.currentGroupName)")
                    .font(.playfair(Theme.fontHeading))
                    .foregroundColor(Theme.textSecondary)
                Text("Tap **+** to add the first note to this group.")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            Button(action: startNewNote) {
                Label("New Note", systemImage: "plus")
                    .font(.lora(Theme.fontSM))
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
}

// ── Note row (mirrors NoteCard in NotesSidebar.jsx) ───────────────────────────
struct NoteRow: View {
    let note: FSNote

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 16.5, weight: .heavy))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                Spacer()
                if note.public {
                    Text("PUBLIC")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.5)
                        .foregroundColor(Theme.goldLight)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.gold.opacity(0.14))
                        .overlay(Capsule().stroke(Theme.gold.opacity(0.32), lineWidth: 1))
                        .clipShape(Capsule())
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

            Text(note.formattedTimestamp)
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
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
                    .font(.lora(Theme.fontXXS))
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
struct NoteDetailView: View {
    let note:   FSNote
    // Returns nil on success, or an error message on failure (mirrors
    // NoteEditorView.onSave so a content-filter rejection keeps both sheets open).
    let onSave: (FSNote) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var showEditor = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        Text(note.title.isEmpty ? "Untitled" : note.title)
                            .font(.playfair(Theme.fontDisplayMD))
                            .foregroundColor(Theme.parchment)

                        if !note.formattedTimestamp.isEmpty {
                            Text(note.formattedTimestamp)
                                .font(.lora(Theme.fontXS))
                                .foregroundColor(Theme.textMuted)
                        }

                        Divider().background(Theme.borderGoldFaint)

                        NoteHTMLView(html: note.text)
                    }
                    .padding(Theme.spacingLG)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }.foregroundColor(Theme.gold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") { showEditor = true }.foregroundColor(Theme.gold)
                }
            }
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
        }
        .preferredColorScheme(.dark)
    }
}

