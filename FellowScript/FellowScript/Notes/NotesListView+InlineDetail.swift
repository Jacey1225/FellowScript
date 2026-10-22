// NotesListView+InlineDetail.swift — task 20261015-ipad-inline-note-view-and-reply.
// iPad workspace: tapping a note shows NoteDetailView (with its inline reply
// composer) inside the Notes panel, like the web notes panel, instead of a
// centered sheet. The list stays mounted underneath so scroll and the loaded
// cache are untouched. iPhone / compact width (incl. Slide Over) keep the sheet.

import SwiftUI

extension NotesListView {

    /// Embedded (iPad workspace) and not compact width.
    var inlineDetail: Bool { embedded && horizontalSizeClass != .compact }

    var inlineDetailShowing: Bool { inlineDetail && detailNote != nil }

    /// The list stays mounted under the open note, so blur it heavily (80pt) to
    /// keep the note's panel background calm and the text readable. Skipped
    /// under Low Power / Reduce Transparency, where NoteDetailView paints the
    /// solid dock fill instead.
    var inlineBackdropBlur: CGFloat {
        guard inlineDetailShowing, !reduceTransparency,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return 0 }
        return 80
    }

    /// Overlay layer; empty unless an inline detail is open.
    @ViewBuilder var inlineDetailLayer: some View {
        if inlineDetail, let note = detailNote {
            detailView(for: note, inline: true)
                .id(note.id)
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    /// Builds NoteDetailView for either presentation. `saved.id` (not the outer
    /// note id) is used on save: the same closure backs the parent note edit and
    /// a reply edit, and NoteEditorView stamps `saved.id` with the row edited.
    func detailView(for note: FSNote, inline: Bool) -> NoteDetailView {
        NoteDetailView(
            note:     note,
            userId:   appState.currentUser?.user_id ?? "",
            username: appState.currentUser?.username ?? "",
            service:  vm.service,
            onSendInChat: canSendInChat(note) ? { sendInChatFromDetail(note) } : nil,
            onEditInline: embedded ? {
                editingNote    = note
                editingId      = note.id
                editingGroupId = note.group_id
                inlineDraft    = nil
                inlineIsReply  = false
                showEditor     = true
                detailNote     = nil
            } : nil,
            onEditReplyInline: embedded ? { reply in
                editingNote    = reply
                editingId      = reply.id
                editingGroupId = note.group_id
                inlineDraft    = nil
                inlineIsReply  = true
                showEditor     = true
                detailNote     = nil
            } : nil,
            inline: inline,
            onBack: { detailNote = nil }
        ) { saved in
            let uid = appState.currentUser?.user_id ?? ""
            let ok = await vm.saveNote(saved, editingId: saved.id, userId: uid, authorUsername: appState.currentUser?.username ?? "")
            if ok { return nil }
            return vm.failedSaveMessage()
        }
    }
}
