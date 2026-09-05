// ReplyComposerSheet.swift — the rich-text reply composer sheet used by
// NoteDetailView's group-note replies section. Already an independent view
// struct inside the former NotesListView.swift monolith -- split out into
// its own file (readability #6, 20260904-frontend-arch-sweep) -- same type,
// same behavior, no interface change. See NotesListView.swift's header
// comment for the full split rationale and the list of sibling files.
//
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

import SwiftUI

// ── Reply composer sheet ──────────────────────────────────────────────────────
struct ReplyComposerSheet: View {
    /// Returns nil on success (dismisses), or an error message shown inline.
    let onPost: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .motionAwareAnimation(.spring(response: 0.25), value: showColorPicker, reduceMotion: reduceMotion)
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
                    .padding(Theme.spacingMD)
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
