// NotesListView+Share.swift — task 20261011-ios-share-notes-highlights.
// Share actions for note rows and highlight rows (long-press menu + VoiceOver
// custom actions). Payloads come only from SharePayloads (AppLinks.swift): a note
// shares title + creator + friend link, a highlight shares reference + verse text +
// verse link. Nothing from a note body is ever read here.

import SwiftUI

extension NotesListView {

    /// nil = no Share for this note (no resolvable creator: never fabricate one).
    func noteSharePayload(_ note: FSNote) -> SharePayload? {
        guard let creator = SharePayloads.noteCreator(
            noteUsername: note.username, noteUserId: note.user,
            currentUserId: appState.currentUser?.user_id,
            currentUsername: appState.currentUser?.username) else { return nil }
        return SharePayloads.note(title: note.title, creatorUsername: creator)
    }

    func noteShareName(_ note: FSNote) -> String {
        let t = SharePayloads.clean(note.title, max: 60)
        return t.isEmpty ? "Untitled" : t
    }

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
