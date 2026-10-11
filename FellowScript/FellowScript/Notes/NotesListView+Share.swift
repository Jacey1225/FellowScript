// NotesListView+Share.swift — task 20261011-ios-share-notes-highlights.
// Share action for highlight rows (long-press menu + VoiceOver custom actions).
// The payload comes only from SharePayloads (AppLinks.swift): reference + verse text +
// verse link. Notes are deliberately not shareable.

import SwiftUI

extension NotesListView {

    /// Resolves the verse text (the row's own, else the bundled Bible) and opens the share sheet.
    func shareHighlight(book: String, chapter: Int, verse: Int, knownText: String?) {
        Task {
            var text = (knownText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, let bibleVM {
                text = await bibleVM.verseTextLoadingIfNeeded(book: book, chapter: chapter, verse: verse) ?? ""
            }
            if let p = SharePayloads.verse(book: book, chapter: chapter, verse: verse, text: text) {
                sharePayload = p
            } else {
                shareNotice = "That verse couldn't be loaded. Try again in a moment."
            }
        }
    }
}
