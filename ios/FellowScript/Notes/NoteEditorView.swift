// SOURCE: components/NotesSidebar.jsx (NoteEditor component), global.css (.note-editor-*)
// KEY STATE: titleVal, bodyText, isPublic, verseList, showColors, showVersePicker
// INTERACTIONS: title → body focus transfer, Bold/Italic/Underline/Highlight/Color toolbar,
//               add/remove verse tags, public toggle, save on dismiss
// DEPENDENCY: Theme.swift, Models.swift

import SwiftUI

struct NoteEditorView: View {
    let note:       FSNote?
    let noteId:     String?
    let isReadOnly: Bool
    var onSave:     ((FSNote) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var titleVal    = ""
    @State private var bodyText    = ""
    @State private var isPublic    = false
    @State private var verseList:  [VerseRef] = []
    @State private var showVersePicker = false
    @State private var showColorPicker = false
    @State private var isSaving    = false

    @FocusState private var titleFocused: Bool
    @FocusState private var bodyFocused:  Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.islandBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Header bar (mirrors note-editor-header) ───────────────
                    HStack {
                        Button("Cancel") { dismiss() }
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.textSecondary)
                            .accessibilityLabel("Cancel and discard changes")

                        Spacer()

                        // Public toggle (mirrors <Switch checked={isPublic} />)
                        if !isReadOnly {
                            Toggle("", isOn: $isPublic)
                                .labelsHidden()
                                .tint(Theme.gold)
                                .scaleEffect(0.8)
                                .accessibilityLabel("Make note public")
                            Text("Public")
                                .font(.lora(Theme.fontXS))
                                .foregroundColor(Theme.textGoldMuted)
                        }

                        Spacer()

                        if !isReadOnly {
                            Button(action: handleSave) {
                                if isSaving {
                                    ProgressView().tint(Theme.gold).scaleEffect(0.8)
                                } else {
                                    Text("Save")
                                        .font(.lora(Theme.fontSM, weight: .semibold))
                                        .foregroundColor(Theme.gold)
                                }
                            }
                            .disabled(isSaving)
                            .accessibilityLabel("Save note")
                        } else {
                            Button("Done") { dismiss() }
                                .font(.lora(Theme.fontSM))
                                .foregroundColor(Theme.gold)
                        }
                    }
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.navBg)
                    .overlay(alignment: .bottom) {
                        Divider().background(Theme.borderGoldFaint)
                    }

                    // ── Verse bar (mirrors note-editor-verse-bar) ─────────────
                    if !verseList.isEmpty || !isReadOnly {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.spacingXS) {
                                ForEach(Array(verseList.enumerated()), id: \.offset) { i, v in
                                    VerseTag(label: v.label) {
                                        if !isReadOnly { verseList.remove(at: i) }
                                    }
                                    .accessibilityLabel("Verse reference: \(v.label). Tap to remove.")
                                }
                                if !isReadOnly {
                                    Button(action: { showVersePicker = true }) {
                                        Text("+ Verse")
                                            .font(.lora(Theme.fontXS))
                                            .foregroundColor(Theme.gold.opacity(0.70))
                                            .padding(.horizontal, Theme.spacingMD)
                                            .padding(.vertical, 4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 100)
                                                    .stroke(Theme.gold.opacity(0.30), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                            )
                                    }
                                    .accessibilityLabel("Attach a Bible verse")
                                }
                            }
                            .padding(.horizontal, Theme.spacingMD)
                            .padding(.vertical, 6)
                        }
                        .background(Theme.navBg.opacity(0.85))
                        .overlay(alignment: .bottom) { Divider().background(Theme.borderGoldFaint) }
                    }

                    // ── Format toolbar (mirrors FmtBtn row in NoteEditor) ─────
                    if !isReadOnly {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.spacingXS) {
                                FormatButton(label: "B", bold: true)   { applyFormat("**", to: &bodyText) }
                                FormatButton(label: "I", italic: true)  { applyFormat("_",  to: &bodyText) }
                                FormatButton(label: "U", underline: true) { applyFormat("__", to: &bodyText) }
                                FormatButton(label: "H", highlightStyle: true) { applyHighlight(to: &bodyText) }
                                // Color picker toggle
                                FormatButton(label: "A", colorBar: true) { showColorPicker.toggle() }
                                    .accessibilityLabel("Text color picker")

                                if showColorPicker {
                                    ForEach(Array(zip(Theme.highlightColors, Theme.highlightHex)), id: \.1) { color, hex in
                                        Button(action: {
                                            showColorPicker = false
                                        }) {
                                            Circle()
                                                .fill(color)
                                                .frame(width: 20, height: 20)
                                                .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 1.5))
                                        }
                                        .scaleEffect(showColorPicker ? 1 : 0)
                                        .animation(.spring(response: 0.25).delay(0.04 * Double(Theme.highlightHex.firstIndex(of: hex) ?? 0)), value: showColorPicker)
                                        .accessibilityLabel("Apply \(hex) color")
                                    }
                                }
                            }
                            .padding(.horizontal, Theme.spacingMD)
                            .padding(.vertical, 6)
                        }
                        .background(Theme.navBg.opacity(0.75))
                        .overlay(alignment: .bottom) { Divider().background(Theme.borderGoldFaint) }
                    }

                    // ── Writing area ──────────────────────────────────────────
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Theme.spacingSM) {
                            // Title field (mirrors .note-title-input)
                            TextField("Title", text: $titleVal, axis: .vertical)
                                .font(.playfair(Theme.fontDisplayMD))
                                .foregroundColor(Theme.parchment)
                                .focused($titleFocused)
                                .submitLabel(.next)
                                .onSubmit { bodyFocused = true }
                                .disabled(isReadOnly)
                                .accessibilityLabel("Note title")

                            // Body field (mirrors note-body-textarea)
                            if isReadOnly {
                                Text(bodyText.isEmpty ? "No content" : bodyText)
                                    .font(.lora(Theme.fontBody))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineSpacing(5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ZStack(alignment: .topLeading) {
                                    if bodyText.isEmpty {
                                        Text("Start writing…")
                                            .font(.lora(Theme.fontBody))
                                            .foregroundColor(Theme.textMuted)
                                            .padding(.top, 4)
                                            .allowsHitTesting(false)
                                    }
                                    TextEditor(text: $bodyText)
                                        .font(.lora(Theme.fontBody))
                                        .foregroundColor(Theme.textSecondary)
                                        .scrollContentBackground(.hidden)
                                        .focused($bodyFocused)
                                        .frame(minHeight: 200)
                                        .accessibilityLabel("Note body text")
                                }
                            }
                        }
                        .padding(Theme.spacingMD)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { populate() }
        .sheet(isPresented: $showVersePicker) {
            VersePicker { book, ch, vs in
                let ref = VerseRef(book: book, chapter: ch, verse: vs)
                if !verseList.contains(where: { $0.book == book && $0.chapter == ch && $0.verse == vs }) {
                    verseList.append(ref)
                }
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    private func populate() {
        if let n = note {
            titleVal  = n.title
            bodyText  = n.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            isPublic  = n.public
            verseList = n.verses.compactMap { components -> VerseRef? in
                guard components.count >= 3 else { return nil }
                let book = components[0].asString
                let ch   = components[1].asInt ?? 0
                let vs   = components[2].asInt ?? 0
                return VerseRef(book: book, chapter: ch, verse: vs)
            }
        } else {
            titleFocused = true
        }
    }

    private func handleSave() {
        isSaving = true
        let saved = FSNote(
            id:        noteId ?? UUID().uuidString,
            user:      appState.currentUser?.user_id ?? "",
            title:     titleVal.isEmpty ? "Untitled" : titleVal,
            text:      bodyText,
            public:    isPublic,
            group_id:  "",
            is_reply:  false,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            verses:    verseList.map { [.string($0.book), .int($0.chapter), .int($0.verse)] },
            replies:   []
        )
        onSave?(saved)
        isSaving = false
        dismiss()
    }

    // Simple markdown-style wrappers — real rich-text requires UITextView bridge
    private func applyFormat(_ marker: String, to text: inout String) {
        text += marker
    }

    private func applyHighlight(to text: inout String) {
        text += "=="
    }
}

// ── Verse tag (mirrors .note-verse-tag) ───────────────────────────────────────
struct VerseTag: View {
    let label:    String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.verseRef(Theme.fontXS))
                .foregroundColor(Theme.gold)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.gold.opacity(0.55))
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, 4)
        .background(Theme.gold.opacity(0.10))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
    }
}

// ── Format button (mirrors FmtBtn) ────────────────────────────────────────────
struct FormatButton: View {
    let label:         String
    var bold:          Bool = false
    var italic:        Bool = false
    var underline:     Bool = false
    var highlightStyle: Bool = false
    var colorBar:      Bool = false
    let action:        () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if bold {
                    Text(label).bold()
                } else if italic {
                    Text(label).italic()
                } else if underline {
                    Text(label).underline()
                } else if highlightStyle {
                    Text(label)
                        .background(Theme.gold.opacity(0.40))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                } else if colorBar {
                    VStack(spacing: 1) {
                        Text(label)
                        Rectangle()
                            .fill(Theme.gold)
                            .frame(height: 2)
                    }
                } else {
                    Text(label)
                }
            }
            .font(.lora(Theme.fontXS))
            .foregroundColor(Theme.parchment.opacity(0.70))
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, 4)
            .background(Theme.gold.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.borderGoldDim, lineWidth: 1))
        }
    }
}

// ── Simple verse picker (inline book/chapter/verse selection) ─────────────────
struct VersePicker: View {
    let onSelect: (String, Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedBook    = "John"
    @State private var selectedChapter = 1
    @State private var selectedVerse   = 1

    var body: some View {
        NavigationStack {
            Form {
                Picker("Book", selection: $selectedBook) {
                    ForEach(BibleData.bookNames, id: \.self) { Text($0).tag($0) }
                }
                Picker("Chapter", selection: $selectedChapter) {
                    ForEach(1...max(1, BibleData.sampleChapterCounts[selectedBook] ?? 1), id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
                Picker("Verse", selection: $selectedVerse) {
                    ForEach(1...50, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .navigationTitle("Attach Verse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        onSelect(selectedBook, selectedChapter, selectedVerse)
                        dismiss()
                    }.foregroundColor(Theme.gold)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}
