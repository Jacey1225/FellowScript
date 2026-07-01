// SOURCE: components/NotesSidebar.jsx (NoteCard, HighlightCard, FilterPanel, group selector)
// KEY STATE: notes, highlights, groups, currentGroupId, activeTab, filteredNotes, showFilter
// INTERACTIONS: + to create, swipe-left to delete, tap to open, group picker, filter sheet
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift, NoteEditorView.swift

import SwiftUI

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes:          [String: FSNote]    = [:]
    @Published var highlights:     [String: String]    = [:]
    @Published var groups:         [FSGroup]           = []
    @Published var currentGroupId: String?             = nil
    @Published var activeTab:      NoteTab             = .notes
    @Published var isLoading       = true

    enum NoteTab: String, CaseIterable {
        case notes      = "Notes"
        case highlights = "Highlights"
    }

    var sortedNotes: [(String, FSNote)] {
        notes.sorted { $0.value.timestamp > $1.value.timestamp }
    }

    var sortedHighlights: [FSHighlight] {
        highlights.map { FSHighlight.from(key: $0.key, color: $0.value) }
                  .sorted { $0.book < $1.book || ($0.book == $1.book && $0.chapter < $1.chapter) }
    }

    func load(userId: String) async {
        isLoading = true
        defer { isLoading = false }
        if let n = try? await MockDataService.shared.fetchNotes(userId: userId)      { notes      = n }
        if let h = try? await MockDataService.shared.fetchHighlights(userId: userId) { highlights = h }
    }

    func deleteNote(id: String) {
        notes.removeValue(forKey: id)
    }
}

// ── Root notes list ───────────────────────────────────────────────────────────
struct NotesListView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = NotesViewModel()
    @State private var showEditor    = false
    @State private var editingNote:  FSNote?    = nil
    @State private var editingId:    String?    = nil
    @State private var showFilter    = false
    @State private var detailNote:   FSNote?    = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Tab picker — Notes / Highlights (mirrors Tabs in NotesSidebar.jsx)
                    Picker("Tab", selection: $vm.activeTab) {
                        ForEach(NotesViewModel.NoteTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.navBg)

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
                    Button(action: { showFilter = true }) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Filter and sort notes")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { editingNote = nil; editingId = nil; showEditor = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Create new note")
                }
            }
        }
        .task {
            if let uid = appState.currentUser?.user_id {
                await vm.load(userId: uid)
            }
        }
        .sheet(isPresented: $showEditor) {
            NoteEditorView(note: editingNote, noteId: editingId, isReadOnly: false) { saved in
                if let id = editingId {
                    vm.notes[id] = saved
                } else {
                    let newId = UUID().uuidString
                    vm.notes[newId] = saved
                }
            }
        }
        .sheet(item: $detailNote) { note in
            NoteDetailView(note: note, onEdit: { n, id in
                editingNote = n; editingId = id; showEditor = true
            })
        }
        .sheet(isPresented: $showFilter) {
            FilterSheet()
        }
    }

    // ── Notes tab ─────────────────────────────────────────────────────────────
    private var notesTab: some View {
        Group {
            if vm.sortedNotes.isEmpty {
                notesEmptyState
            } else {
                List {
                    ForEach(vm.sortedNotes, id: \.0) { id, note in
                        NoteRow(note: note)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.borderGoldFaint)
                            .onTapGesture { detailNote = note }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    vm.deleteNote(id: id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") {
                                    editingNote = note; editingId = id; showEditor = true
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    vm.deleteNote(id: id)
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
            Text("Your study begins here")
                .font(.playfair(Theme.fontHeading))
                .foregroundColor(Theme.textSecondary)
            Text("Tap **New** to capture your first note.")
                .font(.lora(Theme.fontSM))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button(action: { showEditor = true }) {
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

            // Verse references (mirrors note-verse-tag)
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

                        // Rendered body (strips HTML tags for plain display)
                        let plain = note.text
                            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        Text(plain)
                            .font(.lora(Theme.fontBody))
                            .foregroundColor(Theme.textSecondary)
                            .lineSpacing(5)
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

// ── Filter sheet (mirrors FilterPanel in NotesSidebar.jsx) ───────────────────
struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sortVal    = ""
    @State private var filterType = ""
    @State private var filterVal  = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sort by date", selection: $sortVal) {
                        Text("— No sort —").tag("")
                        Text("Newest first").tag("desc")
                        Text("Oldest first").tag("asc")
                    }
                } header: {
                    Text("Sort")
                        .font(.lora(Theme.fontXXS)).tracking(4)
                        .foregroundColor(Theme.textGoldMuted)
                }

                Section {
                    Picker("Filter by", selection: $filterType) {
                        Text("— No filter —").tag("")
                        Text("Book").tag("book")
                        Text("Title").tag("title")
                        Text("Date").tag("date")
                    }
                    if !filterType.isEmpty {
                        TextField(filterType == "book" ? "e.g. Genesis" : "Search…", text: $filterVal)
                            .font(.lora(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                    }
                } header: {
                    Text("Filter")
                        .font(.lora(Theme.fontXXS)).tracking(4)
                        .foregroundColor(Theme.textGoldMuted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .navigationTitle("Filter & Sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") { sortVal = ""; filterType = ""; filterVal = "" }
                        .foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") { dismiss() }
                        .foregroundColor(Theme.gold)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}
