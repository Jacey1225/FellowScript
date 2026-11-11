// TourPromptCoordinator.swift -- task 20261105-take-tour-prompt.
//
// Drives the "Take a quick tour" sheet. ContentView hosts the sheet and feeds
// fresh suppression inputs on each evaluation. Cadence lives in TourPromptStore.

import SwiftUI
import Combine

@MainActor
final class TourPromptCoordinator: ObservableObject {
    @Published private(set) var isPresented = false

    var store: TourPromptStore

    init(store: TourPromptStore = TourPromptStore()) {
        self.store = store
    }

    /// Re-derive whether to show. Safe to call repeatedly: once presented, the
    /// ask is already counted, so it keeps the sheet rather than re-checking.
    func evaluate(suppression: TourPromptSuppression) {
        guard !isPresented else { return }
        guard store.shouldPresent(suppression: suppression) else { return }
        store.recordAsk()
        isPresented = true
    }

    /// Tap-out, swipe, "Not now": the ask was counted at presentation.
    func dismiss() { isPresented = false }

    /// Primary button: resolved for good, then the caller starts the tour.
    func accept() {
        store.markResolved()
        isPresented = false
    }
}
