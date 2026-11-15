// NotesListView+DraftGuard.swift — task 20261115-ipad-askai-notegate (item 2).
// iPad inline editor: a verse draft handed over by the Bible reader must not
// silently replace a draft the user is writing. If the editor is dirty the
// handoff waits for Keep editing / Discard; Keep editing drops the handoff.

import SwiftUI

extension NotesListView {

    /// iPad: open the inline editor for a verse handed over by the Bible reader.
    func consumePendingNoteDraft() {
        guard embedded, fixedTab != .highlights, let draft = appState.pendingNoteDraft else { return }
        appState.pendingNoteDraft = nil
        if showEditor, NoteDraftGuard.decision(dirty: editorDirty) == .confirm {
            handoffDraft = draft
            return
        }
        applyHandoff(draft)
    }

    func applyHandoff(_ draft: VerseNoteDraft) {
        editingNote    = nil
        editingId      = nil
        editingGroupId = ""
        inlineIsReply  = false
        inlineDraft    = draft
        showEditor     = true
        editorDirty    = false
        restoredDraft  = nil
        appState.noteDraftStash = nil
    }

    /// After a rotation re-mounts the dock, reopen the inline editor with the draft
    /// the user had typed. Only the signed-in user's own stash is ever restored.
    func restoreStashedDraft() {
        guard embedded, fixedTab != .highlights, !showEditor, appState.noteDraftStash != nil else { return }
        guard let s = NoteDraftStash.restorable(appState.noteDraftStash, userId: appState.currentUser?.user_id) else {
            appState.noteDraftStash = nil
            return
        }
        editingNote    = s.editingNote
        editingId      = s.editingId
        editingGroupId = s.editingGroupId
        inlineDraft    = s.inlineDraft
        inlineIsReply  = s.inlineIsReply
        restoredDraft  = s.content
        showEditor     = true
        editorDirty    = true
    }
}
