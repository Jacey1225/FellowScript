// Notes/NotesListView+HighlightSearch.swift — Highlights-tab search UI
// (task 20260909-highlight-search). Search-only: with an empty query the
// normal highlightsTab is shown untouched.

import SwiftUI

extension NotesListView {
    var highlightSearchField: some View {
        NotesSearchField(text: $hsm.searchText, isSearching: hsm.isSearching)
    }

    @ViewBuilder
    var highlightsTabContent: some View {
        if hsm.isActive {
            highlightSearchResults
        } else {
            highlightsTab
        }
    }

    @ViewBuilder
    var highlightSearchResults: some View {
        if let msg = hsm.errorMessage {
            VStack(spacing: Theme.spacingMD) {
                Spacer()
                Text(msg)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingXL)
                Button("Try again") { hsm.retry() }
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.gold)
                Spacer()
            }
        } else if hsm.results.isEmpty {
            VStack(spacing: Theme.spacingMD) {
                Spacer()
                if hsm.isSearching {
                    ProgressView().tint(Theme.gold)
                } else {
                    Text("No highlights found for \u{201C}\(hsm.trimmedQuery)\u{201D}")
                        .font(.playfair(Theme.fontBody))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.spacingXL)
                    Text("Try a book, a chapter like John 3, a verse like John 3:16, or a friend\u{2019}s username.")
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.spacingXL)
                }
                Spacer()
            }
        } else {
            List(hsm.results) { r in
                HighlightSearchRow(result: r)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard r.chapter > 0, r.verse > 0 else { return }
                        appState.pendingBibleNav = BibleNavTarget(book: r.book, chapter: r.chapter, verse: r.verse)
                    }
                    .onAppear { hsm.loadMoreIfNeeded(current: r) }
                    .accessibilityLabel("Highlight in \(r.book) chapter \(r.chapter) verse \(r.verse)\(r.is_self ? "" : " by \(r.owner_username ?? "a friend")"). Tap to open in the Bible.")
                    .accessibilityAddTraits(.isButton)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, Theme.spacingSM, for: .scrollContent)
            .contentMargins(.bottom, 100, for: .scrollContent)
            .scrollTopEdgeFeather()
            .padding(.top, Theme.spacingLG)
        }
    }
}

struct HighlightSearchRow: View {
    let result: FSHighlightSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.spacingMD) {
                Circle()
                    .fill(Color(hex: result.color))
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.30), radius: 2)
                    .accessibilityHidden(true)
                Text("\(result.book) \(result.chapter):\(result.verse)")
                    .font(.verseRef(Theme.fontBody))
                    .foregroundColor(Theme.gold)
                Spacer()
                if !result.is_self, let name = result.owner_username {
                    Text(name)
                        .font(.inter(Theme.fontXXS))
                        .foregroundColor(Theme.gold.opacity(0.65))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.gold.opacity(0.10))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.gold.opacity(0.40))
                    .accessibilityHidden(true)
            }
            if let text = result.verse_text, !text.isEmpty {
                Text(text)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, Theme.spacingXS)
    }
}
