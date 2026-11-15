// NoteDraftStash.swift — task 20261115-ipad-askai-notegate (bounce 1).
// Pure draft-preservation value types. A rotation flips the workspace between
// drawer and docked layouts and re-mounts the right dock, destroying the Notes
// editor's @State, and SwiftUI cannot intercept that. So the in-progress draft
// is mirrored here (held on AppState) as the user types and restored when the
// inline editor re-mounts. Restores exactly what was typed, nothing invented.
// Cleared on save, confirmed Discard, or Cancel-confirmed discard.

import Foundation

struct NoteDraftVerse: Equatable {
    let book: String
    let chapter: Int
    let verse: Int
}

/// Exactly what the user has typed/selected in the editor.
struct NoteDraftContent: Equatable {
    var title: String
    var bodyHTML: String
    var verses: [NoteDraftVerse]
    var isPublic: Bool
}

/// Draft content plus the NotesListView context needed to reopen the editor.
struct NoteDraftStash {
    var userId: String
    var content: NoteDraftContent
    var editingNote: FSNote?
    var editingId: String?
    var editingGroupId: String
    var inlineDraft: VerseNoteDraft?
    var inlineIsReply: Bool

    /// The stash to restore for `userId`, or nil (never another account's draft).
    static func restorable(_ stash: NoteDraftStash?, userId: String?) -> NoteDraftStash? {
        guard let stash, let userId, !userId.isEmpty, stash.userId == userId else { return nil }
        return stash
    }

    /// What to store after the editor reports a change: the draft when dirty,
    /// nothing when the editor is clean (so an untouched editor leaves no stash).
    static func updated(userId: String?, content: NoteDraftContent?, editingNote: FSNote?, editingId: String?,
                        editingGroupId: String, inlineDraft: VerseNoteDraft?, inlineIsReply: Bool) -> NoteDraftStash? {
        guard let content, let userId, !userId.isEmpty else { return nil }
        return NoteDraftStash(userId: userId, content: content, editingNote: editingNote, editingId: editingId,
                              editingGroupId: editingGroupId, inlineDraft: inlineDraft, inlineIsReply: inlineIsReply)
    }
}
