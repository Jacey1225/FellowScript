// NotesRowViews.swift — small row-level views NotesListView.swift used to
// also define: the search field, a note row, and a highlight row. Split out
// (readability #6, 20260904-frontend-arch-sweep) -- same types, same
// behavior, no interface change. See NotesListView.swift's header comment
// for the full split rationale and the list of sibling files.

import SwiftUI

// ── Notes search field (task 20260903-notes-keyword-search) ──────────────────
// Custom-styled to this app's glass/gold visual language (UI/UX pref Q12:
// build custom to fit the synthesized visual system, not a bare/system
// `.searchable()`/SearchBar skin) -- mirrors ChatRootView.ChatSearchField's
// same capsule/glass treatment, plus a plain-spinner loading affordance
// (UI/UX pref Q17) swapped in for the magnifying-glass icon while a
// debounced query is in flight, and a subtle functional fade on the clear
// button's appearance (UI/UX pref Q18: functional, not purely decorative).
struct NotesSearchField: View {
    @Binding var text: String
    var isSearching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            if isSearching {
                ProgressView()
                    .tint(Theme.parchment.opacity(0.5))
                    .scaleEffect(0.75)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.parchment.opacity(0.4))
            }
            TextField("", text: $text, prompt: Text("Search notes")
                .foregroundColor(Theme.parchment.opacity(0.4)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.parchment)
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Search notes")
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.parchment.opacity(0.35))
                }
                .transition(.opacity)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Capsule().fill(Theme.parchment.opacity(0.06)))
        .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
        .motionAwareAnimation(.easeOut(duration: 0.18), value: text.isEmpty, reduceMotion: reduceMotion)
    }
}

// ── Note row (mirrors NoteCard in NotesSidebar.jsx) ───────────────────────────
struct NoteRow: View {
    let note: FSNote

    // Author chip shows only for group-segment notes with a successfully
    // captured author username — never for Personal notes (always the
    // viewer, so an identity chip is just noise) and never a placeholder
    // for a group note whose username failed to decode/capture (an honest
    // "no chip" is a harmless diagnostic signal, not a bug to paper over).
    private var showsAuthorChip: Bool { !note.group_id.isEmpty && !note.username.isEmpty }

    // Edit-permission indicator (task 20260903-notes-public-repurpose,
    // step 5): `note.public` no longer means "visible" -- it means "other
    // group members may edit this note" -- so, like the web NoteCard badge,
    // it's only meaningful (and only shown) on a group note. A Personal note
    // has no other group member who could edit it regardless of this flag,
    // so no indicator renders there at all (unlike the old globe/lock
    // visibility cue, which intentionally applied to both segments).
    private var showsEditableIndicator: Bool { !note.group_id.isEmpty && note.public }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 16.5, weight: .heavy))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                Spacer()
                if showsAuthorChip {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.gold.opacity(0.14))
                            .overlay(Circle().stroke(Theme.gold.opacity(0.32), lineWidth: 1))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Text(String(note.username.prefix(1)).uppercased())
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(Theme.goldLight)
                            )
                        Text(note.username)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(Theme.parchment.opacity(0.75))
                            .lineLimit(1)
                    }
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

            HStack(spacing: 5) {
                Text(note.formattedTimestamp)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                if showsEditableIndicator {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.goldLight.opacity(0.8))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(showsEditableIndicator
                ? "\(note.formattedTimestamp), editable by group"
                : note.formattedTimestamp)
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
                    .font(.inter(Theme.fontXXS))
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
