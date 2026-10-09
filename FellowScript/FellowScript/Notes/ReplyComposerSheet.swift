// ReplyComposerSheet.swift — the rich-text reply composer used by
// NoteDetailView's group-note replies section. Task 20260909-reply-inline-editor:
// the former `ReplyComposerSheet` (presented via .sheet) is now
// `ReplyComposerInline`, rendered inline in NoteDetailView's scroll content
// right below the note body. File name kept to avoid project-file churn.
// Cancel discards the draft (the view is removed from the hierarchy).
// Historical notes follow. Already an independent view
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

// ── Inline reply composer ─────────────────────────────────────────────────
struct ReplyComposerInline: View {
    /// Returns nil on success (closes the composer), or an error message shown inline.
    let onPost: (String) async -> String?
    /// Collapses the composer (Cancel, or after a successful post).
    let onClose: () -> Void

    @AccessibilityFocusState private var editorA11yFocused: Bool
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
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            // Format toolbar (verbatim from NoteEditorView's toolbar; no
            // isReadOnly gate, no verse/title affordances).
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
                        Button {
                            showColorPicker = false
                            rtc.resetColor()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Theme.parchment.opacity(0.50))
                                .font(.system(size: 24))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Reset text color")
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
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
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
                    .font(.interScaled(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
                    .accessibilityHidden(true)

                // Body — rich text editor. Same ZStack structure as
                // NoteEditorView: the placeholder Text stays in the
                // ZStack unconditionally so SwiftUI never recreates
                // the UIViewRepresentable and resets htmlOutput.
                ZStack(alignment: .topLeading) {
                    Text("Write a reply…")
                        .font(.interScaled(Theme.fontBody))
                        .foregroundColor(Theme.textMuted)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .opacity(rtc.htmlOutput.isEmpty ? 1 : 0)
                    RichTextEditorView(
                        controller:  rtc,
                        initialHTML: "",
                        placeholder: "Write a reply…"
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .accessibilityLabel("Reply text")
                    .accessibilityFocused($editorA11yFocused)
                }
            }
            .padding(Theme.spacingMD)
            .glassCard(cornerRadius: 20)

            if let errorMessage {
                Text(errorMessage)
                    .font(.interScaled(Theme.fontSM))
                    .foregroundColor(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Cancel (ghost chip) leading, gold Post pill trailing. ViewThatFits
            // stacks them vertically when Dynamic Type makes the row too wide.
            ViewThatFits(in: .horizontal) {
                HStack {
                    cancelButton
                    Spacer(minLength: Theme.spacingMD)
                    postButton
                }
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    postButton
                    cancelButton
                }
            }
        }
        .onAppear {
            // Move VoiceOver focus and the keyboard to the editor once the
            // UITextView exists (it is created during this same layout pass).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                editorA11yFocused = true
                rtc.textView?.becomeFirstResponder()
            }
        }
    }

    private var cancelButton: some View {
        Button(action: { onClose() }) { cancelGhostChip }
            .buttonStyle(.plain)
            .disabled(isPosting)
            .accessibilityLabel("Cancel reply")
    }

    private var postButton: some View {
        PillButton(title: isPosting ? "Posting…" : "Post") {
            Task {
                isPosting = true
                errorMessage = await onPost(extractedHTML())
                isPosting = false
                if errorMessage == nil { onClose() }
            }
        }
        .frame(minHeight: 44)
        .disabled(!canPost)
        .accessibilityLabel(isPosting ? "Posting reply" : "Post reply")
    }

    // Ghost-chip Cancel label (see ChatRootView.swift's sheetGhostCancelLabel
    // for the shared recipe/rationale comment -- bespoke per-sheet copy here
    // rather than a new cross-file shared component, matching
    // EventSetupSheet's cancelGhostChip precedent).
    private var cancelGhostChip: some View {
        Text("Cancel")
            .font(.interScaled(Theme.fontSM))
            .foregroundColor(Theme.textSecondary)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Capsule().fill(Theme.parchment.opacity(0.06)))
            .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
    }
}
