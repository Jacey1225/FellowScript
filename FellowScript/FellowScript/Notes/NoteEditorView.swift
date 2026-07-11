// SOURCE: components/NotesSidebar.jsx (NoteEditor component), global.css (.note-editor-*)
// KEY STATE: titleVal, bodyText, isPublic, verseList, showColors, showVersePicker
// INTERACTIONS: title → body focus transfer, Bold/Italic/Underline/Highlight/Color toolbar,
//               add/remove verse tags, public toggle, save on dismiss
// DEPENDENCY: Theme.swift, Models.swift

import SwiftUI

struct NoteEditorView: View {
    let note:       FSNote?
    let noteId:     String?
    var groupId:    String = ""
    let isReadOnly: Bool
    var onSave:     ((FSNote) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var titleVal    = ""
    @State private var isPublic    = false
    @State private var verseList:  [VerseRef] = []
    @State private var showVersePicker = false
    @State private var showColorPicker = false
    @State private var isSaving    = false

    @StateObject private var rtc = RichTextEditorController()

    @FocusState private var titleFocused: Bool

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

                    // ── Format toolbar ────────────────────────────────────────
                    if !isReadOnly {
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
                        .background(Theme.navBg.opacity(0.75))
                        .overlay(alignment: .bottom) { Divider().background(Theme.borderGoldFaint) }
                    }

                    // ── Writing area ──────────────────────────────────────────
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Theme.spacingSM) {
                            // Title
                            TextField("Title", text: $titleVal, axis: .vertical)
                                .font(.playfair(Theme.fontDisplayMD))
                                .foregroundColor(Theme.parchment)
                                .focused($titleFocused)
                                .submitLabel(.next)
                                .onSubmit { rtc.textView?.becomeFirstResponder() }
                                .disabled(isReadOnly)
                                .accessibilityLabel("Note title")

                            // Body — rich text editor / HTML renderer
                            if isReadOnly {
                                NoteHTMLView(html: note?.text ?? "")
                                    .accessibilityLabel("Note body")
                            } else {
                                ZStack(alignment: .topLeading) {
                                    // Keep Text always in the ZStack so the structure
                                    // never changes — a structural conditional (if/else)
                                    // shifts RichTextEditorView's ZStack position and
                                    // can cause SwiftUI to recreate the UIViewRepresentable,
                                    // calling makeUIView a second time and resetting htmlOutput.
                                    Text("Start writing…")
                                        .font(.lora(Theme.fontBody))
                                        .foregroundColor(Theme.textMuted)
                                        .padding(.top, 2)
                                        .allowsHitTesting(false)
                                        .opacity(rtc.htmlOutput.isEmpty ? 1 : 0)
                                    RichTextEditorView(
                                        controller:  rtc,
                                        initialHTML: note?.text ?? "",
                                        placeholder: "Start writing…"
                                    )
                                    .frame(maxWidth: .infinity, minHeight: 220)
                                    .accessibilityLabel("Note body text")
                                }
                            }
                        }
                        .padding(Theme.spacingMD)
                        // Extra bottom space so the last line can always be scrolled
                        // to the top of the visible area — cursor is never stuck behind
                        // the keyboard or at the very bottom of the screen.
                        .padding(.bottom, UIScreen.main.bounds.height * 0.55)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Let the keyboard properly inset the scroll view (shrinks frame
                    // above keyboard) so content can scroll up into view while typing.
                    .scrollDismissesKeyboard(.interactively)
                }
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
            isPublic  = n.public
            verseList = n.verses.compactMap { components -> VerseRef? in
                guard components.count >= 3 else { return nil }
                let book = components[0].asString
                let ch   = components[1].asInt ?? 0
                let vs   = components[2].asInt ?? 0
                return VerseRef(book: book, chapter: ch, verse: vs)
            }
            // Body text is loaded by RichTextEditorView(initialHTML:) in makeUIView —
            // no async dispatch needed.
        } else {
            titleFocused = true
        }
    }

    private func handleSave() {
        isSaving = true
        // Prefer live UITextView content; fall back to tracked @Published value,
        // then original note text — defense against transient empty-string conditions.
        let liveHTML    = rtc.currentHTML()
        let trackedHTML = rtc.htmlOutput
        let tvText      = rtc.textView?.text ?? ""
        let html: String
        if !liveHTML.isEmpty {
            html = liveHTML
        } else if !trackedHTML.isEmpty {
            html = trackedHTML
        } else if !tvText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Plain-text fallback when HTML conversion fails entirely
            html = tvText
                .replacingOccurrences(of: "\u{2029}", with: "<br>")
                .replacingOccurrences(of: "\u{2028}", with: "<br>")
                .replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\r", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
        } else {
            html = note?.text ?? ""
        }
        print("[Save] liveHTML.count=\(liveHTML.count) trackedHTML.count=\(trackedHTML.count) tvText.count=\(tvText.count) → html.count=\(html.count) html.prefix=\(html.prefix(80))")
        // Preserve the original note's immutable metadata so a server-side ownership
        // or type check on is_reply / user / replies doesn't silently discard the edit.
        let originalUser = note?.user ?? ""
        let saved = FSNote(
            id:        noteId ?? UUID().uuidString,
            user:      originalUser.isEmpty ? (appState.currentUser?.user_id ?? "") : originalUser,
            title:     titleVal.isEmpty ? "Untitled" : titleVal,
            text:      html,
            public:    isPublic,
            group_id:  note?.group_id ?? groupId,
            is_reply:  note?.is_reply ?? false,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            verses:    verseList.map { [.string($0.book), .int($0.chapter), .int($0.verse)] },
            replies:   note?.replies ?? []
        )
        onSave?(saved)
        isSaving = false
        dismiss()
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
    let label:          String
    var bold:           Bool = false
    var italic:         Bool = false
    var underline:      Bool = false
    var highlightStyle: Bool = false
    var colorBar:       Bool = false
    var isActive:       Bool = false
    let action:         () -> Void

    private var symbol: String {
        if bold           { return "bold" }
        if italic         { return "italic" }
        if underline      { return "underline" }
        if highlightStyle { return "highlighter" }
        if colorBar       { return "paintpalette" }
        return "textformat"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: isActive ? .semibold : .medium))
                .frame(width: 46, height: 42)
                .foregroundColor(isActive ? Theme.gold : Theme.parchment.opacity(0.82))
                .background(isActive ? Theme.gold.opacity(0.22) : Theme.gold.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isActive ? Theme.gold.opacity(0.65) : Theme.borderGoldDim,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
