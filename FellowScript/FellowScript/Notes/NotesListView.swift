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
    }

    func saveNote(_ note: FSNote, editingId: String?, userId: String) async -> Bool {
        do {
            let savedId = try await service.saveNote(note, editingId: editingId, userId: userId)
            var updated = note; updated.id = savedId
            notes[savedId] = updated
            return true
        } catch { return false }
    }

    func deleteNote(id: String, userId: String) async {
        notes.removeValue(forKey: id)
        try? await service.deleteNote(noteId: id, userId: userId)
    }

    func saveHighlight(book: String, chapter: Int, verse: Int, color: String, userId: String) async {
        let key = "\(book)-\(chapter)-\(verse)"
        highlights[key] = color
        try? await service.saveHighlight(userId: userId, book: book, chapter: chapter, verse: verse, color: color)
    }

    func clearHighlight(key: String, userId: String) async {
        highlights.removeValue(forKey: key)
        try? await service.clearHighlight(userId: userId, key: key)
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
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Notes / Highlights segment ──────────────────────────
                    Picker("Tab", selection: $vm.activeTab) {
                        ForEach(NotesViewModel.NoteTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.navBg)

                    // ── Category chips (Personal + each group) ─────────────
                    if vm.activeTab == .notes {
                        categoryPicker
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
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Section("Sort") {
                            ForEach(NotesViewModel.SortOrder.allCases, id: \.self) { order in
                                Button(action: { vm.sortOrder = order }) {
                                    Label(
                                        order.rawValue,
                                        systemImage: vm.sortOrder == order ? "checkmark" : "arrow.up.arrow.down"
                                    )
                                }
                            }
                        }
                        Section("Visibility") {
                            ForEach(NotesViewModel.VisibilityFilter.allCases, id: \.self) { filter in
                                Button(action: { vm.visibilityFilter = filter }) {
                                    Label(
                                        filter.rawValue,
                                        systemImage: vm.visibilityFilter == filter ? "checkmark" : "eye"
                                    )
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
                        Image(systemName: vm.isFiltered
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Filter and sort notes")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: startNewNote) {
                        Image(systemName: "plus")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Create new note")
                }
            }
        }
        .task {
            if let uid = appState.currentUser?.user_id {
                await vm.load(service: appState.service, userId: uid)
            }
        }
        .sheet(isPresented: $showEditor) {
            NoteEditorView(
                note:      editingNote,
                noteId:    editingId,
                groupId:   editingGroupId,
                isReadOnly: false
            ) { saved in
                let uid = appState.currentUser?.user_id ?? ""
                Task { await vm.saveNote(saved, editingId: editingId, userId: uid) }
            }
        }
        .sheet(item: $detailNote) { note in
            NoteDetailView(note: note, onEdit: { n, id in
                editingNote    = n
                editingId      = id
                editingGroupId = n.group_id
                showEditor     = true
            })
        }
    }

    // ── Category chip row ─────────────────────────────────────────────────────
    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingSM) {
                chip(title: "Personal", id: nil)
                ForEach(vm.groups) { group in
                    chip(title: group.title, id: group.id)
                }
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, Theme.spacingSM)
        }
        .background(Theme.navBg)
        .overlay(alignment: .bottom) { Divider().background(Theme.borderGoldFaint) }
    }

    @ViewBuilder
    private func chip(title: String, id: String?) -> some View {
        let selected = vm.currentGroupId == id
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { vm.currentGroupId = id }
        }) {
            Text(title)
                .font(.lora(Theme.fontXS))
                .foregroundColor(selected ? Theme.ink : Theme.textSecondary)
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, 6)
                .background(selected ? Theme.gold : Theme.gold.opacity(0.10))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.borderGoldDim, lineWidth: 1))
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
                            .listRowSeparatorTint(Theme.borderGoldFaint)
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
                        .listRowSeparatorTint(Theme.borderGoldFaint)
                        .accessibilityLabel("Highlight in \(h.book) chapter \(h.chapter) verse \(h.verse)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.lora(Theme.fontBody, weight: .semibold))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                Spacer()
                if note.public {
                    Text("Public")
                        .font(.lora(Theme.fontXXS))
                        .tracking(2)
                        .foregroundColor(Theme.gold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.gold.opacity(0.10))
                        .clipShape(Capsule())
                }
            }

            let validVerses = note.verses.filter { $0.count >= 3 }
            if !validVerses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(validVerses.enumerated()), id: \.offset) { _, v in
                            Text(verseLabel(v))
                                .font(.verseRef(Theme.fontXXS))
                                .foregroundColor(Theme.gold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Theme.gold.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.borderGold, lineWidth: 1))
                        }
                    }
                }
            }

            Text(note.preview.isEmpty ? "No content" : note.preview)
                .font(.lora(Theme.fontSM))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)

            Text(note.formattedTimestamp)
                .font(.lora(Theme.fontXXS))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.vertical, Theme.spacingSM)
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
        }
        .padding(.vertical, Theme.spacingXS)
    }
}

// ── Note detail sheet ─────────────────────────────────────────────────────────
struct NoteDetailView: View {
    let note:   FSNote
    let onEdit: (FSNote, String) -> Void
    @Environment(\.dismiss) private var dismiss

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
                    Button("Edit") {
                        onEdit(note, note.id)
                        dismiss()
                    }
                    .foregroundColor(Theme.gold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

