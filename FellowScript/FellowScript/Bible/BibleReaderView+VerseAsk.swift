// BibleReaderView+VerseAsk.swift -- task 20261112-verse-ask-ai (step 5).
// Glue between the reader and the per-verse Ask AI overlay, kept out of the
// BibleReaderView monolith. The verse .contextMenu stays the sole long-press
// path: the new menu item only sets state that drives the overlay layer.

import SwiftUI

/// One open Ask AI overlay: its view model plus the verse row's window frame,
/// captured the moment the user chose "Ask AI".
struct VerseAskSession: Identifiable {
    let id = UUID()
    let vm: VerseAskViewModel
    let verseFrame: CGRect
}

extension BibleReaderView {

    /// Entry is hidden (not disabled) unless the server flag is on and a user is
    /// signed in. Fail closed: capabilities default to all-off.
    var verseAskAvailable: Bool {
        appState.capabilities.askAiEnabled && appState.currentUser != nil
    }

    @ViewBuilder
    func verseAskMenuButton(verse: Int, text: String) -> some View {
        if verseAskAvailable {
            Button(action: { beginVerseAsk(verse: verse, text: text) }) {
                Label("Ask AI", systemImage: "sparkles")
            }
            .accessibilityLabel("Ask AI about verse \(verse)")
        }
    }

    func beginVerseAsk(verse: Int, text: String) {
        guard verseAskAvailable, let userId = appState.currentUser?.user_id,
              let frame = verseFrames.frame(verse: verse) else { return }
        verseAsk?.vm.cancel()
        let ctx = VerseAskContext(reference: "\(verseRefPrefix):\(verse)",
                                  translation: "WEB", text: text)
        let vm = VerseAskViewModel(userId: userId, verseNumber: verse, context: ctx, transport: NetworkService.shared)
        withAnimation(verseAskFade) { verseAsk = VerseAskSession(vm: vm, verseFrame: frame) }
    }

    func closeVerseAsk() {
        verseAsk?.vm.cancel()
        withAnimation(verseAskFade) { verseAsk = nil }
    }

    private var verseAskFade: Animation? { UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.16) }

    @ViewBuilder
    var verseAskLayer: some View {
        if let session = verseAsk, verseAskAvailable {
            VerseAskOverlay(vm: session.vm, verseFrame: session.verseFrame, onClose: closeVerseAsk)
                .id(session.id)
        }
    }
}
