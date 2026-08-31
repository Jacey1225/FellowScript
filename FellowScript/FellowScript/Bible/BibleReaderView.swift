// SOURCE: frontend/src/pages/Reader.jsx, hooks/useBible.js, hooks/useHighlights.js,
//         hooks/useBookmarks.js, components/BibleNavigator.jsx, components/HighlightPicker.jsx,
//         global.css (.bib-nav-*, .verse-span, .vnum, .chapter-card)
// KEY STATE: curBook, curChapter, verses, highlights, bookmarks, fontSize, selectedVerse
// INTERACTIONS: book/chapter picker sheet, font size cycle, bookmark popover,
//               long-press verse → context menu (highlight, copy, add to note, share)
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift

import SwiftUI
import Combine

// ── ViewModel ─────────────────────────────────────────────────────────────────
@MainActor
final class BibleViewModel: ObservableObject {

    var service: DataServiceProtocol = MockDataService.shared

    @Published var books:       [String]  = []
    @Published var curBook:     String    = "John"
    @Published var curChapter:  Int       = 1
    @Published var verses:      [(num: Int, text: String)] = []
    @Published var highlights:  [String: String]  = [:]  // "Book-ch-vs" → hex color
    @Published var bookmarks:   [String: String]  = [:]  // "Book-ch" → label
    @Published var isLoading    = true
    @Published var loadError    = false
    @Published var saveError:   String? = nil

    // Cached chapter counts per book
    var chapterCounts: [String: Int] = [:]

    // In-memory bible data: [book: [chapterStr]] where index 0 may be a preamble
    private var bibleData: [String: [String]] = [:]

    init() {
        // Restore last position
        if let saved = UserDefaults.standard.data(forKey: "fs_bible_pos"),
           let pos = try? JSONDecoder().decode([String: String].self, from: saved) {
            curBook    = pos["book"]    ?? "John"
            curChapter = Int(pos["chapter"] ?? "1") ?? 1
        }
    }

    // Guards against a duplicate fetch when this instance is shared between
    // StartupCoordinator (which calls load() once up front to gate the
    // startup loading screen) and this screen's own `.task` (which also
    // calls load() the first time BibleReaderView is lazily mounted).
    private var hasLoadedOnce = false

    func load(service: DataServiceProtocol, userId: String) async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        self.service = service
        // Fetch from bundled bible.json in the app bundle
        guard let url = Bundle.main.url(forResource: "bible", withExtension: "json") else {
            loadMockContent()
            await loadUserData(userId: userId)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: [String]].self, from: data)
            bibleData = decoded
            books = Array(decoded.keys).sorted()
            isLoading = false
            setChapter(curChapter)
        } catch {
            loadMockContent()
        }
        await loadUserData(userId: userId)
    }

    private func loadUserData(userId: String) async {
        if let hl = try? await service.fetchHighlights(userId: userId) { highlights = hl }
        if let bm = try? await service.fetchBookmarks(userId: userId)   { bookmarks  = bm }
    }

    func persistHighlight(verse: Int, color: String, userId: String) {
        let book = curBook, chapter = curChapter
        let key = "\(book)-\(chapter)-\(verse)"
        let previous = highlights[key]
        setHighlight(verse: verse, color: color)   // optimistic
        Task {
            do {
                // saveHighlight now uses checkedRequestRaw (throws on 4xx/5xx)
                // instead of the unchecked requestRaw, so a rejected write
                // (expired session, free-tier limit, etc.) is observable here
                // rather than silently looking like it succeeded.
                try await service.saveHighlight(userId: userId, book: book, chapter: chapter, verse: verse, color: color)
            } catch {
                if let previous { highlights[key] = previous } else { highlights.removeValue(forKey: key) }
                saveError = error.localizedDescription
            }
        }
    }

    func persistClearHighlight(verse: Int, userId: String) {
        let book = curBook, chapter = curChapter
        let key = "\(book)-\(chapter)-\(verse)"
        let previous = highlights[key]
        clearHighlight(verse: verse)   // optimistic
        Task {
            do {
                try await service.clearHighlight(userId: userId, key: key)
            } catch {
                if let previous { highlights[key] = previous }
                saveError = error.localizedDescription
            }
        }
    }

    func persistToggleBookmark(userId: String) {
        let key = "\(curBook)-\(curChapter)"
        let book = curBook, chapter = curChapter
        if isBookmarked() {
            let previousLabel = bookmarks[key]
            bookmarks.removeValue(forKey: key)   // optimistic
            Task {
                do {
                    try await service.removeBookmark(userId: userId, key: key)
                } catch {
                    if let previousLabel { bookmarks[key] = previousLabel }
                    saveError = error.localizedDescription
                }
            }
        } else {
            bookmarks[key] = ""   // optimistic
            Task {
                do {
                    // saveBookmark now uses checkedRequestRaw — same rationale
                    // as persistHighlight above.
                    try await service.saveBookmark(userId: userId, book: book, chapter: chapter, label: "")
                } catch {
                    bookmarks.removeValue(forKey: key)
                    saveError = error.localizedDescription
                }
            }
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
        if let raw = bibleData[curBook], !raw.isEmpty {
            // Index 0 is a preamble when there are multiple entries; chapters are 1-based
            let chList = raw.count == 1 ? raw : Array(raw.dropFirst())
            let idx    = ch - 1
            verses = (idx >= 0 && idx < chList.count) ? parseVerses(chList[idx]) : BibleData.fallbackVerses
        } else {
            verses = ch == 1 && curBook == "John" ? BibleData.johnChapterOne : BibleData.fallbackVerses
        }
        savePosition()
    }

    func chapters(for book: String) -> Int {
        if let c = chapterCounts[book] { return c }
        guard let raw = bibleData[book], !raw.isEmpty else { return 1 }
        return raw.count == 1 ? 1 : raw.count - 1
    }

    func nextChapter() {
        let total = chapters(for: curBook)
        if curChapter < total {
            setChapter(curChapter + 1)
        } else {
            let bookList = BibleData.bookNames
            if let idx = bookList.firstIndex(of: curBook), idx + 1 < bookList.count {
                setBook(bookList[idx + 1])
            }
        }
    }

    func prevChapter() {
        if curChapter > 1 {
            setChapter(curChapter - 1)
        } else {
            let bookList = BibleData.bookNames
            if let idx = bookList.firstIndex(of: curBook), idx > 0 {
                let prev = bookList[idx - 1]
                curBook  = prev
                setChapter(chapters(for: prev))
            }
        }
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

    // Chapter string format from bible.json: "1:1 verse text2next verse HEAD:: Section3more..."
    // First verse: "chN:vN text", subsequent: "N[A-Za-z]", section headers: "HEAD:: ..."
    private func parseVerses(_ chStr: String) -> [(num: Int, text: String)] {
        // Strip footnote markers [N] and section headers HEAD::...
        var text = chStr
            .replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"HEAD::[^0-9]*"#, with: " ", options: .regularExpression)

        let ns  = text as NSString
        let len = ns.length
        // (verseNum, numStart, textStart): numStart = where digits begin, textStart = after digits
        var entries: [(num: Int, numStart: Int, textStart: Int)] = []

        // First verse: "chapter:verse " at the start of the string
        if let rx = try? NSRegularExpression(pattern: #"^\s*\d+:(\d+)\s*"#),
           let m  = rx.firstMatch(in: text, range: NSRange(location: 0, length: len)) {
            let vNum = Int(ns.substring(with: m.range(at: 1))) ?? 1
            entries.append((vNum, m.range.location, NSMaxRange(m.range)))
        }

        // Subsequent verses: a digit sequence not preceded by a digit, immediately before a letter
        let searchFrom = entries.first?.textStart ?? 0
        if let rx = try? NSRegularExpression(pattern: #"(?<!\d)(\d+)(?=[A-Za-z])"#) {
            let range = NSRange(location: searchFrom, length: len - searchFrom)
            for m in rx.matches(in: text, range: range) {
                let vNum = Int(ns.substring(with: m.range(at: 1))) ?? 0
                if vNum > 0 { entries.append((vNum, m.range.location, NSMaxRange(m.range))) }
            }
        }

        guard !entries.isEmpty else { return BibleData.fallbackVerses }

        return entries.enumerated().map { i, entry in
            let end   = i + 1 < entries.count ? entries[i + 1].numStart : len
            let vText = ns.substring(with: NSRange(location: entry.textStart, length: max(0, end - entry.textStart)))
                .trimmingCharacters(in: .whitespaces)
            return (entry.num, vText)
        }
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
    @StateObject private var vm: BibleViewModel

    // Required (no default): a bare `BibleViewModel()` default expression is
    // evaluated as MainActor-isolated under this project's default actor
    // isolation, but this init itself must stay usable from a nonisolated
    // context, so it can't carry that default safely. ContentView.mainTabView
    // is the only call site and always passes StartupCoordinator's shared
    // instance so this screen's `.task` sees already-loaded (or in-flight)
    // data instead of firing a second fetch (see BibleViewModel.hasLoadedOnce).
    init(vm: BibleViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    @AppStorage("bibleReaderFontSizeIndex") private var fontSizeIndex: Int = 1
    @State private var showNavSheet      = false
    @State private var showBookmarks     = false
    @State private var selectedVerse:    Int? = nil
    @State private var showHighlightFor: Int? = nil
    @State private var showAddToNote:    (Int, String)? = nil
    @State private var pendingScrollVerse: Int? = nil
    @State private var contentOpacity:   Double = 1

    private var fontSize: CGFloat { Theme.bibleFontSizes[min(fontSizeIndex, Theme.bibleFontSizes.count - 1)] }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.bgPage.ignoresSafeArea()

                // Warm bloom ground (shared visual language with
                // Notes/Chat/Account — task 20260830-bible-reader-live-fix).
                // Identical literal values to NotesListView.swift/
                // ChatThreadView.swift/ChatRootView.swift/AccountView.swift;
                // this was the one primary screen still shipping a flat
                // `Theme.bgPage` fill with no bloom layer, confirmed live
                // against the on-device screenshot the user attached.
                RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                               center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                    .ignoresSafeArea()
                RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                               center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                    .ignoresSafeArea()

                if vm.isLoading {
                    ProgressView()
                        .tint(Theme.gold)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                // Book label + chapter heading (mirrors card-book-label / card-title)
                                VStack(alignment: .leading, spacing: Theme.spacingXS) {
                                    Text(vm.curBook.uppercased())
                                        .font(.inter(Theme.fontXXS))
                                        .tracking(5)
                                        .foregroundColor(Theme.goldDim)
                                    Text("Chapter \(vm.curChapter)")
                                        .font(.playfair(Theme.fontDisplayXL))
                                        .foregroundColor(Theme.bibleText)
                                }
                                .id("chapterTop")
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
                                    .id(v.num)
                                    .onTapGesture { selectedVerse = (selectedVerse == v.num) ? nil : v.num }
                                    .contextMenu {
                                        verseContextMenu(verse: v.num, text: v.text)
                                    }
                                    .accessibilityLabel("Verse \(v.num): \(v.text)")
                                }
                            }
                            .padding(.bottom, 60)
                        }
                        .onChange(of: vm.curChapter) { _, _ in
                            proxy.scrollTo("chapterTop", anchor: .top)
                        }
                        .onChange(of: vm.curBook) { _, _ in
                            proxy.scrollTo("chapterTop", anchor: .top)
                        }
                        .onChange(of: pendingScrollVerse) { _, verse in
                            guard let v = verse else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation { proxy.scrollTo(v, anchor: .center) }
                                selectedVerse      = v
                                pendingScrollVerse = nil
                            }
                        }
                    }
                    .opacity(contentOpacity)
                    .gesture(
                        DragGesture(minimumDistance: 30, coordinateSpace: .local)
                            .onEnded { value in
                                guard !showNavSheet else { return }
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard abs(dx) > abs(dy), abs(dx) > 50 else { return }
                                changeChapter(forward: dx < 0)
                            }
                    )
                }

                // Drop-down nav overlay — slides in from top. Closing is now
                // driven solely by re-tapping the nav-bar pill button (see the
                // toolbar's Button below) or by selecting a chapter below —
                // the panel itself no longer owns a close control.
                if showNavSheet {
                    BibleNavDropdown(
                        books:      vm.books.isEmpty ? BibleData.bookNames : vm.books,
                        curBook:    vm.curBook,
                        curChapter: vm.curChapter,
                        chapters:   { vm.chapters(for: $0) },
                        onSelect:   { book, ch in
                            vm.setBook(book)
                            vm.setChapter(ch)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                showNavSheet = false
                            }
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: showNavSheet)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // .sharedBackgroundVisibility(.hidden) (task
                // 20260830-bible-reader-live-fix): confirmed live (Simulator
                // screenshot, pixel-sampled) that iOS 26 wraps each toolbar
                // item's content in its own automatic Liquid Glass capsule
                // chrome regardless of what the item draws — same mechanism
                // already diagnosed and fixed for NoteDetailView's
                // Close/Edit pills (task 20260829-note-detail-toolbar-visual-fix,
                // see NotesListView.swift:1091-1105). On the leading pill this
                // produced a genuine nested double-capsule (system chrome
                // outside, this view's own `.background(Theme.gold.opacity(0.10))`
                // capsule inside); on the trailing group it was the sole
                // visible outline, since the font-size/bookmark buttons draw
                // no background of their own. Applying the modifier to the
                // `ToolbarItemGroup` as a whole (rather than splitting it
                // into two separate `ToolbarItem`s) was confirmed live to
                // remove the chrome from both children without disturbing
                // the bookmark `Menu`'s tap/presentation behavior — no
                // precedent existed either way since this is the only
                // `ToolbarItemGroup` in the codebase, so this was resolved by
                // testing rather than assumption.
                ToolbarItem(placement: .navigationBarLeading) {
                    // Book/chapter pill button (mirrors nav-pill-btn in global.css).
                    // Doubles as the panel's open/close toggle — same button opens
                    // and closes BibleNavDropdown; there is no separate in-panel
                    // close control (see BibleNavDropdown.header).
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            showNavSheet.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text("\(vm.curBook) \(vm.curChapter)")
                                .font(.inter(Theme.fontSM))
                                .foregroundColor(Theme.parchment)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundColor(Theme.gold)
                        }
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.vertical, 6)
                        .background(Theme.gold.opacity(0.10))
                        .clipShape(Capsule())
                    }
                    .accessibilityLabel("Navigate to book and chapter")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Font size cycle (Small → Medium → Large → X-Large → loop)
                    Button(action: cycleFontSize) {
                        Image(systemName: "textformat.size")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Change font size: current \(Theme.bibleFontLabels[fontSizeIndex])")

                    // Bookmark menu
                    Menu {
                        Button(action: {
                            vm.persistToggleBookmark(userId: appState.currentUser?.user_id ?? "")
                        }) {
                            Label(vm.isBookmarked() ? "Remove Bookmark" : "Add Bookmark",
                                  systemImage: vm.isBookmarked() ? "bookmark.slash" : "bookmark")
                        }
                        Menu("View Bookmarks") {
                            if vm.bookmarks.isEmpty {
                                Text("No bookmarks yet")
                            } else {
                                let sorted = vm.bookmarks.keys.sorted()
                                    .map { FSBookmark.from(key: $0, label: vm.bookmarks[$0] ?? "") }
                                ForEach(sorted, id: \.id) { bm in
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
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .task {
            if let uid = appState.currentUser?.user_id {
                await vm.load(service: appState.service, userId: uid)
            }
        }
        .onChange(of: appState.pendingBibleNav) { _, target in
            guard let t = target else { return }
            vm.setBook(t.book)
            vm.setChapter(t.chapter)
            pendingScrollVerse   = t.verse
            appState.pendingBibleNav = nil
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

    @ViewBuilder
    private func verseContextMenu(verse: Int, text: String) -> some View {
        // Highlight sub-menu — 5 color swatches (matches HighlightPicker)
        Menu("Highlight") {
            ForEach(Theme.highlightHex, id: \.self) { hex in
                Button(action: {
                    vm.persistHighlight(verse: verse, color: hex, userId: appState.currentUser?.user_id ?? "")
                }) {
                    Label(colorName(hex), systemImage: "circle.fill")
                }
            }
            if vm.isHighlighted(verse: verse) != nil {
                Divider()
                Button("Clear Highlight", role: .destructive) {
                    vm.persistClearHighlight(verse: verse, userId: appState.currentUser?.user_id ?? "")
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

    private func changeChapter(forward: Bool) {
        withAnimation(.easeInOut(duration: 0.12)) { contentOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if forward { vm.nextChapter() } else { vm.prevChapter() }
            withAnimation(.easeInOut(duration: 0.18)) { contentOpacity = 1 }
        }
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
                .font(.inter(fontSize * 0.60, weight: .semibold))
                .foregroundColor(Theme.gold)
                .baselineOffset(6)
                .frame(minWidth: 24, alignment: .trailing)
                .accessibilityHidden(true)

            // Verse text
            Text(text)
                .font(.inter(fontSize))
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

// ── Drop-down nav overlay (replaces sheet — slides in from top) ───────────────
// Concept B — single-column drill-down: Step 1 is a full-width OT/NT-grouped
// book list with a testament pill jump; tapping a book advances (local
// @State, never a NavigationStack push, so back/close stay predictable and
// never fight the hardware/system back gesture) to Step 2, a full-width
// chapter grid for that book. Only a chapter tap calls `onSelect` and closes
// the panel — matching the prior two-pane behavior where a book tap alone
// never selected a passage. See design-notes.md §3.
struct BibleNavDropdown: View {
    let books:      [String]
    let curBook:    String
    let curChapter: Int
    let chapters:   (String) -> Int
    let onSelect:   (String, Int) -> Void

    private enum Step {
        case bookList
        case chapterGrid(String)
    }

    private enum Testament: Equatable {
        case old, new
    }

    @State private var step: Step = .bookList
    @State private var activeTestament: Testament

    init(books: [String], curBook: String, curChapter: Int,
         chapters: @escaping (String) -> Int,
         onSelect: @escaping (String, Int) -> Void) {
        self.books      = books
        self.curBook    = curBook
        self.curChapter = curChapter
        self.chapters   = chapters
        self.onSelect   = onSelect
        _activeTestament = State(initialValue: BibleData.oldTestament.contains(curBook) ? .old : .new)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Theme.borderGoldFaint)

            switch step {
            case .bookList:
                bookListStep
            case .chapterGrid(let book):
                chapterGridStep(for: book)
            }
        }
        // Translucent, strongly-blurred panel (task 20260830-bible-nav-dropdown-
        // blur, replacing the prior opaque Theme.widgetBg fill): `.ultraThinMaterial`
        // gives a real backdrop blur of the verse content scrolled behind the
        // open panel -- confirmed live as the material with the most visible,
        // clearly-blurred-not-opaque signal of the options tried here (an
        // earlier `.regularMaterial` pass, and this same `.ultraThinMaterial`
        // layered under too strong a tint, both measured as reading fully
        // opaque live via pixel-correlation against real scrolled verse
        // content -- see this task's testing-gate bounce history). `Theme.
        // panelGlassTint` sits in front of it, at a low 0.14 opacity (down
        // from an initial 0.35 that, live-measured, compounded with
        // `.ultraThinMaterial`'s own dark-mode opacity into a near-fully-
        // opaque composite -- correlation with the true backdrop was
        // measured at -0.20, i.e. none), so the result still lands in the
        // app's warm dark tone (not the material's default cool grey) and
        // gives a small opacity floor for the panel's own text, without
        // swallowing the material's blur signal. This is the *only* blur
        // layer in the panel — the two inner-step backgrounds below are
        // dropped to `.clear` rather than stacking a second blur, per this
        // codebase's documented "second stacked blur reads muddy" precedent
        // (20260826-glass-verse-selector-messages).
        .background(Theme.panelGlassTint)
        .background(.ultraThinMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 10)
        .padding(.horizontal, 0)
        .frame(maxHeight: 430)
    }

    // ── Header bar — "Select Passage" on Step 1, "‹ Back  <Book>" on Step 2.
    // No in-panel close control: the nav-bar pill button that opened the
    // panel is also what closes it (BibleReaderView's toolbar Button), so
    // this header only needs to carry Step 1/Step 2 navigation chrome.
    @ViewBuilder
    private var header: some View {
        Group {
            switch step {
            case .bookList:
                HStack {
                    Text("Select Passage")
                        .font(.inter(Theme.fontSM))
                        // Theme.goldDim -> Theme.goldLight (task 20260830-
                        // bible-nav-dropdown-blur): goldDim's contrast against
                        // this panel's now-translucent/blurred background dips
                        // below the AA floor whenever bright verse content
                        // (e.g. a highlighted verse) happens to sit right
                        // behind the header -- confirmed via a worst-case
                        // contrast check against the live-measured blurred
                        // backdrop. goldLight (already an existing Theme
                        // token) keeps this in the same warm-gold family
                        // while clearing AA at that worst case.
                        .foregroundColor(Theme.goldLight)
                    Spacer()
                }

            case .chapterGrid(let book):
                // Book name is truly centered via ZStack overlay (rather than
                // a leading Back + trailing Spacer, which would skew it left
                // by roughly half the Back button's width) now that there's
                // no trailing "x" to balance against on the other side.
                ZStack {
                    Text(book)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.goldLight)

                    HStack {
                        Button(action: {
                            withAnimation(.easeOut(duration: 0.18)) { step = .bookList }
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left")
                                    .font(.subheadline.weight(.semibold))
                                Text("Back")
                                    .font(.inter(Theme.fontSM))
                            }
                            .foregroundColor(Theme.goldLight)
                            .frame(minHeight: 44)
                        }
                        .accessibilityLabel("Back to book list")
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
        // Header gets its own near-opaque chrome strip (Theme.widgetBg,
        // task 20260830-bible-nav-dropdown-blur second pass) rather than
        // inheriting the outer panel's translucent .ultraThinMaterial +
        // low-opacity Theme.panelGlassTint. Once the outer panel's tint was
        // lowered (0.35 -> 0.14) to actually fix the "reads fully opaque"
        // defect, a worst-case check (real backdrop content -- e.g. a
        // bright highlighted verse -- scrolled directly behind the header)
        // showed goldLight header/back/book-name text could drop as low as
        // ~3.5-3.8:1, back under the AA floor, since that text has no solid
        // backing of its own. Rather than raising the whole panel's tint
        // again (which is what caused the original opacity bug), this gives
        // just the header row a small solid strip -- the same "chrome bar
        // stays solid, scrollable content stays glass" split iOS itself
        // uses for translucent nav bars -- so header legibility no longer
        // depends on whatever's scrolled behind the panel, while the book
        // list / chapter grid below keeps the genuine, live-verified
        // translucent blur.
        .background(Theme.widgetBg)
    }

    // ── Step 1 — full-width, scrollable, OT/NT-grouped book list ─────────────
    private var bookListStep: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                testamentToggle { testament in
                    let target = testament == .old ? BibleData.oldTestament.first : BibleData.newTestament.first
                    if let target {
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                    }
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.top, Theme.spacingSM)
                .padding(.bottom, Theme.spacingXS)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        sectionLabel("Old Testament")
                        ForEach(BibleData.oldTestament, id: \.self) { bookRow($0) }
                        sectionLabel("New Testament")
                        ForEach(BibleData.newTestament, id: \.self) { bookRow($0) }
                    }
                }
                // Always re-centers on curBook (not whatever was last drilled
                // into) — fires on first appear and again whenever Step 1
                // re-shows after backing out of Step 2, per design-notes.md §3.
                .onAppear { proxy.scrollTo(curBook, anchor: .center) }
            }
        }
        // Dropped from Theme.islandBg to .clear: this step is layered on top
        // of the outer panel's new translucent/blurred background (see
        // body's .background(Theme.panelGlassTint)/.ultraThinMaterial above);
        // keeping an opaque fill here would re-obscure the blurred backdrop
        // for this step's entire visible area.
        .background(Color.clear)
    }

    // ── OT/NT pill segmented control — scroll-jump only, not a filter, modeled
    // on ChatRootView.scopeToggle / NotesListView.toggleSegment (design-notes.md §1).
    private func testamentToggle(onJump: @escaping (Testament) -> Void) -> some View {
        HStack(spacing: 4) {
            testamentSegment(.old, "Old Testament", onJump: onJump)
            testamentSegment(.new, "New Testament", onJump: onJump)
        }
        .padding(5)
        .background(
            Capsule().fill(Theme.parchment.opacity(0.07))
                .overlay(Capsule().stroke(Theme.parchment.opacity(0.13), lineWidth: 1))
        )
    }

    private func testamentSegment(_ testament: Testament, _ label: String, onJump: @escaping (Testament) -> Void) -> some View {
        let isActive = activeTestament == testament
        return Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { activeTestament = testament }
            onJump(testament)
        }) {
            Text(label)
                .font(.system(size: 14.5, weight: .heavy))
                .foregroundColor(isActive ? Color(hex: "#24170A") : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    isActive
                        ? LinearGradient(colors: [Color(hex: "#D4922A"), Color(hex: "#EDAB3C")], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.inter(Theme.fontXXS)).tracking(3)
            .textCase(.uppercase)
            .foregroundColor(Theme.gold.opacity(0.45))
            .padding(.horizontal, Theme.spacingMD)
            .padding(.top, Theme.spacingMD)
            .padding(.bottom, Theme.spacingXS)
    }

    // Full-width row — trailing chevron signals drill-down; tapping advances
    // to Step 2 for this book and does NOT call onSelect (matching current
    // behavior where a book tap alone never selects a passage).
    @ViewBuilder
    private func bookRow(_ book: String) -> some View {
        let isCurrent = curBook == book
        Button(action: {
            withAnimation(.easeOut(duration: 0.18)) { step = .chapterGrid(book) }
        }) {
            HStack(spacing: Theme.spacingSM) {
                // isCurrent text/star: dark ink-on-solid-gold (task 20260830-
                // bible-nav-dropdown-blur) rather than the prior gold-text-on-
                // faint-gold-tint -- that combo's contrast depended on sitting
                // over a near-opaque near-black panel; against this panel's
                // new translucent/blurred background, gold-on-gold(0.16) can
                // dip well below AA whenever bright content is behind it.
                // Reuses this same file's existing dark-ink-on-gold-gradient
                // pattern (testamentSegment's isActive segment, above) so
                // legibility here no longer depends on the backdrop at all.
                Text(book)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(isCurrent ? Color(hex: "#24170A") : Theme.parchment.opacity(0.85))
                Spacer()
                if isCurrent {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundColor(Color(hex: "#24170A"))
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Theme.parchment.opacity(0.35))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, 7)
            .background(isCurrent ? Theme.gold.opacity(0.85) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(book)
        .accessibilityLabel(isCurrent ? "\(book), current book" : book)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // ── Step 2 — full-width chapter grid for the drilled-into book ───────────
    @ViewBuilder
    private func chapterGridStep(for book: String) -> some View {
        let count = max(1, chapters(book))
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                Text("\(book.uppercased()) — \(count) CHAPTER\(count == 1 ? "" : "S")")
                    .font(.inter(Theme.fontXXS)).tracking(4)
                    .foregroundColor(Theme.gold.opacity(0.55))
                    .padding(.bottom, Theme.spacingXS)

                // Full-width step grows column count from the old fixed
                // 2-pane 4-column grid to 5, per design-notes.md §3.
                LazyVGrid(
                    columns: Array(repeating: .init(.flexible(), spacing: 10), count: 5),
                    spacing: 10
                ) {
                    ForEach(1...count, id: \.self) { ch in
                        let isActive = book == curBook && ch == curChapter
                        Button(action: { onSelect(book, ch) }) {
                            // Same dark-ink-on-solid-gold swap as bookRow's
                            // isCurrent treatment above, for the same reason:
                            // gold-on-gold(0.20) loses too much contrast once
                            // this panel is a translucent/blurred surface
                            // instead of a near-opaque one.
                            Text("\(ch)")
                                .font(.inter(Theme.fontHeading))
                                .foregroundColor(isActive ? Color(hex: "#24170A") : Theme.parchment.opacity(0.85))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(isActive ? Theme.gold.opacity(0.85) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
                        }
                        .accessibilityLabel(isActive ? "Chapter \(ch), current chapter" : "Chapter \(ch)")
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
            }
            .padding(Theme.spacingMD)
        }
        // Dropped from Theme.widgetBg to .clear — same reasoning as
        // bookListStep above: avoid re-opaquing over the outer panel's
        // translucent/blurred background.
        .background(Color.clear)
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
        (9,  "The true light, /Users/jaceysimpson/Vscode/FellowScript/frontend/node_modules/@aws-sdk/core/dist-types/ts3.4/submodules/protocols/query/QuerySerializerSettings.d.tswhich gives light to everyone, was coming into the world."),
        (10, "He was in the world, and the world was made through him, yet the world did not know him."),
        (11, "He came to his own, and his own people did not receive him."),
        (12, "But to all who did receive him, who believed in his name, he gave the right to become children of God,"),
        (13, "who were born, not of blood nor of the will of the flesh nor of the will of man, but of God."),
        (14, "And the Word became flesh and dwelt among us, and we have seen his glory, glory as of the only Son from the Father, full of grace and truth."),
        (15, "John bore witness about him, and cried out, \"This was he of whom I said, 'He who comes after me ranks before me, because he was before me.'\""),
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
