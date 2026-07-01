// SOURCE: frontend/src/pages/Reader.jsx, hooks/useBible.js, hooks/useHighlights.js,
//         hooks/useBookmarks.js, components/BibleNavigator.jsx, components/HighlightPicker.jsx,
//         global.css (.bib-nav-*, .verse-span, .vnum, .chapter-card)
// KEY STATE: curBook, curChapter, verses, highlights, bookmarks, fontSize, selectedVerse
// INTERACTIONS: book/chapter picker sheet, font size cycle, bookmark popover,
//               long-press verse → context menu (highlight, copy, add to note, share)
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift

import SwiftUI

// ── ViewModel ─────────────────────────────────────────────────────────────────
@MainActor
final class BibleViewModel: ObservableObject {
    @Published var books:       [String]  = []
    @Published var curBook:     String    = "John"
    @Published var curChapter:  Int       = 1
    @Published var verses:      [(num: Int, text: String)] = []
    @Published var highlights:  [String: String]  = [:]  // "Book-ch-vs" → hex color
    @Published var bookmarks:   [String: String]  = [:]  // "Book-ch" → label
    @Published var isLoading    = true
    @Published var loadError    = false

    // Cached chapter counts per book
    var chapterCounts: [String: Int] = [:]

    // In-memory bible data: [book: [[verseText]]] where index 0 is a possible preamble
    private var bibleData: [String: [[String]]] = [:]

    init() {
        // Restore last position
        if let saved = UserDefaults.standard.data(forKey: "fs_bible_pos"),
           let pos = try? JSONDecoder().decode([String: String].self, from: saved) {
            curBook    = pos["book"]    ?? "John"
            curChapter = Int(pos["chapter"] ?? "1") ?? 1
        }
    }

    func load(userId: String) async {
        // Fetch from bundled bible.json in the app bundle
        guard let url = Bundle.main.url(forResource: "bible", withExtension: "json") else {
            // Fall back to mock verses
            loadMockContent()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: [[String]]].self, from: data)
            bibleData = decoded
            books = Array(decoded.keys).sorted()
            isLoading = false
            setChapter(curChapter)
        } catch {
            loadMockContent()
        }

        // Load highlights and bookmarks
        if let hl = try? await MockDataService.shared.fetchHighlights(userId: userId) {
            highlights = hl
        }
        if let bm = try? await MockDataService.shared.fetchBookmarks(userId: userId) {
            bookmarks = bm
        }
    }

    private func loadMockContent() {
        // Mock verse data for John 1 so UI is always populated
        books = BibleData.bookNames
        chapterCounts = BibleData.sampleChapterCounts
        verses = BibleData.johnChapterOne
        isLoading = false
    }

    func setBook(_ book: String) {
        curBook    = book
        curChapter = 1
        setChapter(1)
        savePosition()
    }

    func setChapter(_ ch: Int) {
        curChapter = ch
        if let chapters = bibleData[curBook], !chapters.isEmpty {
            let src   = chapters.count == 1 ? chapters[0] : chapters[ch]
            verses    = parseVerses(src)
        } else {
            // Use mock data
            verses = ch == 1 && curBook == "John" ? BibleData.johnChapterOne : BibleData.fallbackVerses
        }
        savePosition()
    }

    func chapters(for book: String) -> Int {
        if let c = chapterCounts[book] { return c }
        let count = bibleData[book]?.count.advanced(by: bibleData[book]?.count == 1 ? 0 : -1) ?? 1
        return max(1, count)
    }

    func isHighlighted(verse: Int) -> String? {
        return highlights["\(curBook)-\(curChapter)-\(verse)"]
    }

    func isBookmarked() -> Bool {
        return bookmarks["\(curBook)-\(curChapter)"] != nil
    }

    func toggleBookmark(label: String = "") {
        let key = "\(curBook)-\(curChapter)"
        if bookmarks[key] != nil {
            bookmarks.removeValue(forKey: key)
        } else {
            bookmarks[key] = label
        }
    }

    func setHighlight(verse: Int, color: String) {
        highlights["\(curBook)-\(curChapter)-\(verse)"] = color
    }

    func clearHighlight(verse: Int) {
        highlights.removeValue(forKey: "\(curBook)-\(curChapter)-\(verse)")
    }

    private func parseVerses(_ chapter: [String]) -> [(num: Int, text: String)] {
        var result: [(Int, String)] = []
        for line in chapter {
            // Format: "1 In the beginning…" or "[1] In the beginning…"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("HEAD::") { continue }
            let parts = trimmed.components(separatedBy: " ")
            if let num = Int(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
                let text = parts.dropFirst().joined(separator: " ")
                result.append((num, text))
            }
        }
        return result
    }

    private func savePosition() {
        if let data = try? JSONEncoder().encode(["book": curBook, "chapter": String(curChapter)]) {
            UserDefaults.standard.set(data, forKey: "fs_bible_pos")
        }
    }
}

// ── Main Reader View ──────────────────────────────────────────────────────────
struct BibleReaderView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = BibleViewModel()

    @AppStorage("bibleReaderFontSizeIndex") private var fontSizeIndex: Int = 1
    @State private var showNavSheet   = false
    @State private var showBookmarks  = false
    @State private var selectedVerse: Int? = nil
    @State private var showHighlightFor: Int? = nil
    @State private var showAddToNote: (Int, String)? = nil

    private var fontSize: CGFloat { Theme.bibleFontSizes[min(fontSizeIndex, Theme.bibleFontSizes.count - 1)] }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bibleBg.ignoresSafeArea()

                if vm.isLoading {
                    ProgressView()
                        .tint(Theme.gold)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Book label + chapter heading (mirrors card-book-label / card-title)
                            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                                Text(vm.curBook.uppercased())
                                    .font(.lora(Theme.fontXXS))
                                    .tracking(5)
                                    .foregroundColor(Theme.goldDim)
                                Text("Chapter \(vm.curChapter)")
                                    .font(.playfair(Theme.fontDisplayXL))
                                    .foregroundColor(Theme.bibleText)
                            }
                            .padding(.horizontal, Theme.spacingLG)
                            .padding(.top, Theme.spacingMD)
                            .padding(.bottom, Theme.spacingLG)

                            // Verse list
                            ForEach(vm.verses, id: \.num) { v in
                                VerseRow(
                                    num:           v.num,
                                    text:          v.text,
                                    fontSize:      fontSize,
                                    highlightHex:  vm.isHighlighted(verse: v.num),
                                    isSelected:    selectedVerse == v.num
                                )
                                .onTapGesture { selectedVerse = (selectedVerse == v.num) ? nil : v.num }
                                .contextMenu {
                                    verseContextMenu(verse: v.num, text: v.text)
                                }
                                .accessibilityLabel("Verse \(v.num): \(v.text)")
                            }
                        }
                        .padding(.bottom, 60)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // Book/chapter pill button (mirrors nav-pill-btn in global.css)
                    Button(action: { showNavSheet = true }) {
                        HStack(spacing: 4) {
                            Text("\(vm.curBook) \(vm.curChapter)")
                                .font(.lora(Theme.fontSM))
                                .foregroundColor(Theme.parchment)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundColor(Theme.gold)
                        }
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.vertical, 6)
                        .background(Theme.gold.opacity(0.10))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
                    }
                    .accessibilityLabel("Navigate to book and chapter")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Font size cycle (Small → Medium → Large → X-Large → loop)
                    Button(action: cycleFontSize) {
                        Image(systemName: "textformat.size")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Change font size: current \(Theme.bibleFontLabels[fontSizeIndex])")

                    // Bookmark menu
                    Menu {
                        Button(action: { vm.toggleBookmark() }) {
                            Label(vm.isBookmarked() ? "Remove Bookmark" : "Add Bookmark",
                                  systemImage: vm.isBookmarked() ? "bookmark.slash" : "bookmark")
                        }
                        Menu("View Bookmarks") {
                            if vm.bookmarks.isEmpty {
                                Text("No bookmarks yet")
                            } else {
                                ForEach(Array(vm.bookmarks.keys), id: \.self) { key in
                                    let bm = FSBookmark.from(key: key, label: vm.bookmarks[key] ?? "")
                                    Button("\(bm.book) \(bm.chapter)") {
                                        vm.setBook(bm.book)
                                        vm.setChapter(bm.chapter)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: vm.isBookmarked() ? "bookmark.fill" : "bookmark")
                            .foregroundColor(vm.isBookmarked() ? Theme.gold : Theme.parchment)
                    }
                    .accessibilityLabel("Bookmark options")
                }
            }
        }
        .sheet(isPresented: $showNavSheet) {
            BibleNavSheet(
                books:      vm.books.isEmpty ? BibleData.bookNames : vm.books,
                curBook:    vm.curBook,
                curChapter: vm.curChapter,
                chapters:   { vm.chapters(for: $0) },
                onSelect:   { book, ch in
                    vm.setBook(book)
                    vm.setChapter(ch)
                    showNavSheet = false
                }
            )
        }
        .task {
            if let uid = appState.currentUser?.user_id {
                await vm.load(userId: uid)
            }
        }
    }

    @ViewBuilder
    private func verseContextMenu(verse: Int, text: String) -> some View {
        // Highlight sub-menu — 5 color swatches (matches HighlightPicker)
        Menu("Highlight") {
            ForEach(Array(zip(Theme.highlightColors, Theme.highlightHex)), id: \.1) { color, hex in
                Button(action: { vm.setHighlight(verse: verse, color: hex) }) {
                    Label(colorName(hex), systemImage: "circle.fill")
                }
            }
            if vm.isHighlighted(verse: verse) != nil {
                Divider()
                Button("Clear Highlight", role: .destructive) {
                    vm.clearHighlight(verse: verse)
                }
            }
        }

        Button(action: { UIPasteboard.general.string = text }) {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .accessibilityLabel("Copy verse \(verse)")

        Button(action: { showAddToNote = (verse, text) }) {
            Label("Add to Note", systemImage: "note.text.badge.plus")
        }
        .accessibilityLabel("Add verse \(verse) to note")

        Button(action: {
            let ref = "\(vm.curBook) \(vm.curChapter):\(verse) — \(text)"
            let av  = UIActivityViewController(activityItems: [ref], applicationActivities: nil)
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?
                .rootViewController?.present(av, animated: true)
        }) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Share verse \(verse)")
    }

    private func cycleFontSize() {
        fontSizeIndex = (fontSizeIndex + 1) % Theme.bibleFontSizes.count
    }

    private func colorName(_ hex: String) -> String {
        switch hex {
        case "#F5E642": return "Yellow"
        case "#E07070": return "Red"
        case "#6DBF7E": return "Green"
        case "#7EB8E0": return "Blue"
        case "#B07EE0": return "Purple"
        default:        return "Color"
        }
    }
}

// ── Verse row ─────────────────────────────────────────────────────────────────
struct VerseRow: View {
    let num:          Int
    let text:         String
    let fontSize:     CGFloat
    let highlightHex: String?
    let isSelected:   Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // Verse number (mirrors .vnum in CSS)
            Text("\(num)")
                .font(.lora(fontSize * 0.60, weight: .semibold))
                .foregroundColor(Theme.gold)
                .baselineOffset(6)
                .frame(minWidth: 24, alignment: .trailing)
                .accessibilityHidden(true)

            // Verse text
            Text(text)
                .font(.lora(fontSize))
                .foregroundColor(Theme.bibleText)
                .lineSpacing(fontSize * 0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.spacingLG)
        .padding(.vertical, 6)
        .background(
            Group {
                if let hex = highlightHex {
                    Color(hex: hex).opacity(0.28)
                } else if isSelected {
                    Theme.gold.opacity(0.10)
                } else {
                    Color.clear
                }
            }
        )
    }
}

// ── Book / Chapter nav sheet (mirrors bib-nav-widget) ────────────────────────
struct BibleNavSheet: View {
    let books:      [String]
    let curBook:    String
    let curChapter: Int
    let chapters:   (String) -> Int
    let onSelect:   (String, Int) -> Void

    @State private var selectedBook: String
    @Environment(\.dismiss) private var dismiss

    init(books: [String], curBook: String, curChapter: Int, chapters: @escaping (String) -> Int, onSelect: @escaping (String, Int) -> Void) {
        self.books      = books
        self.curBook    = curBook
        self.curChapter = curChapter
        self.chapters   = chapters
        self.onSelect   = onSelect
        _selectedBook   = State(initialValue: curBook)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // Left column — books list (mirrors bib-nav-books)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // OT / NT section dividers
                            Text("Old Testament")
                                .font(.lora(Theme.fontXXS)).tracking(4)
                                .textCase(.uppercase)
                                .foregroundColor(Theme.gold.opacity(0.50))
                                .padding(.horizontal, Theme.spacingSM)
                                .padding(.top, Theme.spacingMD)
                                .padding(.bottom, Theme.spacingXS)

                            ForEach(BibleData.oldTestament, id: \.self) { book in
                                bookButton(book)
                            }

                            Text("New Testament")
                                .font(.lora(Theme.fontXXS)).tracking(4)
                                .textCase(.uppercase)
                                .foregroundColor(Theme.gold.opacity(0.50))
                                .padding(.horizontal, Theme.spacingSM)
                                .padding(.top, Theme.spacingMD)
                                .padding(.bottom, Theme.spacingXS)

                            ForEach(BibleData.newTestament, id: \.self) { book in
                                bookButton(book)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(selectedBook, anchor: .center) }
                }
                .frame(maxWidth: .infinity)
                .background(Theme.islandBg)

                Divider().background(Theme.borderGoldFaint)

                // Right column — chapter grid (mirrors bib-nav-chapters)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text(selectedBook.uppercased())
                            .font(.lora(Theme.fontXXS)).tracking(4)
                            .foregroundColor(Theme.gold.opacity(0.55))
                            .padding(.bottom, Theme.spacingXS)

                        let count = chapters(selectedBook)
                        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 6), count: 5), spacing: 6) {
                            ForEach(1...max(1, count), id: \.self) { ch in
                                Button(action: { onSelect(selectedBook, ch) }) {
                                    Text("\(ch)")
                                        .font(.lora(Theme.fontXS))
                                        .foregroundColor(selectedBook == curBook && ch == curChapter ? Theme.gold : Theme.parchment.opacity(0.55))
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(1, contentMode: .fit)
                                        .background(
                                            selectedBook == curBook && ch == curChapter
                                            ? Theme.gold.opacity(0.22)
                                            : Color.clear
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Theme.radiusSM)
                                                .stroke(Theme.borderGoldDim, lineWidth: 1)
                                        )
                                }
                                .accessibilityLabel("Chapter \(ch)")
                            }
                        }
                    }
                    .padding(Theme.spacingMD)
                }
                .frame(maxWidth: .infinity)
                .background(Theme.widgetBg)
            }
            .navigationTitle("Select Passage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Theme.gold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func bookButton(_ book: String) -> some View {
        Button(action: { selectedBook = book }) {
            Text(book)
                .font(.lora(Theme.fontSM))
                .foregroundColor(selectedBook == book ? Theme.gold : Theme.parchment.opacity(0.60))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, 6)
                .background(selectedBook == book ? Theme.gold.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
        }
        .id(book)
        .accessibilityLabel(book)
        .accessibilityAddTraits(selectedBook == book ? .isSelected : [])
    }
}

// ── Static Bible content for mock ────────────────────────────────────────────
enum BibleData {
    static let johnChapterOne: [(num: Int, text: String)] = [
        (1,  "In the beginning was the Word, and the Word was with God, and the Word was God."),
        (2,  "He was in the beginning with God."),
        (3,  "All things were made through him, and without him was not any thing made that was made."),
        (4,  "In him was life, and the life was the light of men."),
        (5,  "The light shines in the darkness, and the darkness has not overcome it."),
        (6,  "There was a man sent from God, whose name was John."),
        (7,  "He came as a witness, to bear witness about the light, that all might believe through him."),
        (8,  "He was not the light, but came to bear witness about the light."),
        (9,  "The true light, which gives light to everyone, was coming into the world."),
        (10, "He was in the world, and the world was made through him, yet the world did not know him."),
        (11, "He came to his own, and his own people did not receive him."),
        (12, "But to all who did receive him, who believed in his name, he gave the right to become children of God,"),
        (13, "who were born, not of blood nor of the will of the flesh nor of the will of man, but of God."),
        (14, "And the Word became flesh and dwelt among us, and we have seen his glory, glory as of the only Son from the Father, full of grace and truth."),
        (15, "John bore witness about him, and cried out, "This was he of whom I said, 'He who comes after me ranks before me, because he was before me.'""),
        (16, "For from his fullness we have all received, grace upon grace."),
        (17, "For the law was given through Moses; grace and truth came through Jesus Christ."),
        (18, "No one has ever seen God; the only God, who is at the Father's side, he has made him known."),
    ]

    static let fallbackVerses: [(num: Int, text: String)] = [
        (1, "Select a chapter to begin reading."),
    ]

    static let sampleChapterCounts: [String: Int] = [
        "Genesis": 50, "Exodus": 40, "Leviticus": 27, "Numbers": 36, "Deuteronomy": 34,
        "Joshua": 24, "Judges": 21, "Ruth": 4, "1 Samuel": 31, "2 Samuel": 24,
        "1 Kings": 22, "2 Kings": 25, "Psalms": 150, "Proverbs": 31,
        "Isaiah": 66, "Jeremiah": 52, "Matthew": 28, "Mark": 16,
        "Luke": 24, "John": 21, "Acts": 28, "Romans": 16,
        "1 Corinthians": 16, "2 Corinthians": 13, "Galatians": 6, "Ephesians": 6,
        "Philippians": 4, "Colossians": 4, "Revelation": 22,
    ]

    static let oldTestament = [
        "Genesis","Exodus","Leviticus","Numbers","Deuteronomy",
        "Joshua","Judges","Ruth","1 Samuel","2 Samuel",
        "1 Kings","2 Kings","1 Chronicles","2 Chronicles",
        "Ezra","Nehemiah","Esther","Job","Psalms","Proverbs",
        "Ecclesiastes","Song of Solomon","Isaiah","Jeremiah","Lamentations",
        "Ezekiel","Daniel","Hosea","Joel","Amos","Obadiah","Jonah",
        "Micah","Nahum","Habakkuk","Zephaniah","Haggai","Zechariah","Malachi",
    ]

    static let newTestament = [
        "Matthew","Mark","Luke","John","Acts","Romans",
        "1 Corinthians","2 Corinthians","Galatians","Ephesians","Philippians","Colossians",
        "1 Thessalonians","2 Thessalonians","1 Timothy","2 Timothy","Titus","Philemon",
        "Hebrews","James","1 Peter","2 Peter","1 John","2 John","3 John","Jude","Revelation",
    ]

    static let bookNames = oldTestament + newTestament
}
