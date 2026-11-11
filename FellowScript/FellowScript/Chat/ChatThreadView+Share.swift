// ChatThreadView+Share.swift — delivers a "Send in chat" verse/note into a
// chosen thread (task 20261030-thread-share-notes-verses).
//
// ChatThreadView.consumePendingChatShare hands every pending share here. A main
// chat share sends at once (unchanged). A thread share opens the thread, waits
// for its first page, then sends once through the ordinary thread send path
// (`ChatThreadViewModel.sendMessage` with an active thread), so local echo, ack,
// failed bubble and retry are the existing ones. The server rebuilds the
// stored payload and fallback text; this only sends the small request.
//
// Throw-not-fabricate: if the thread cannot be opened or its first page fails
// to load, nothing is sent and nothing is shown as sent; the thread view's own
// retry control stays on screen and the earlier cached messages are untouched.

import Foundation

enum ChatShareDelivery {
    /// Whether the share can be delivered right now by the chat view showing `vm`.
    static func canDeliver(_ pending: PendingChatShare, vm: ChatThreadViewModel) -> Bool {
        pending.thread != nil || !vm.isThreadOpen
    }

    /// Fire-and-forget delivery; the caller has already cleared the pending share.
    @MainActor
    static func deliver(_ pending: PendingChatShare, vm: ChatThreadViewModel, appState: AppState, contact: FSContact) {
        let uid = appState.currentUser?.user_id ?? ""
        guard let thread = pending.thread else {
            vm.sendMessage(text: pending.payload.fallbackText, attachment: nil, contact: contact,
                           userId: uid, shared: pending.payload)
            return
        }
        // Both flags must be on for a thread share; otherwise do nothing.
        guard appState.capabilities.isEnabled("threads"), appState.capabilities.sharedObjectsEnabled else { return }
        Task { @MainActor in
            if vm.activeThread?.id != thread.id {
                await vm.openThread(thread, service: appState.service, contact: contact, userId: uid)
            }
            guard vm.activeThread?.id == thread.id, !vm.threadLoadFailed, !vm.isLoadingThread else { return }
            vm.sendMessage(text: pending.payload.fallbackText, attachment: nil, contact: contact,
                           userId: uid, shared: pending.payload)
        }
    }
}
