// PushPromptCoordinator.swift -- task 20261105-push-prompt-sheet.
//
// Derives the push prompt sheet state from UNUserNotificationCenter on every
// evaluation (call on each scenePhase .active). The authorization status is
// read fresh each time and never stored. Cadence lives in PushPromptStore.

import SwiftUI
import Combine
import UserNotifications

@MainActor
final class PushPromptCoordinator: ObservableObject {
    @Published private(set) var state: PushPromptState = .hidden

    var store: PushPromptStore
    var postTourStore: PostTourPromptsStore
    /// Reads the live authorization status. Injectable for tests.
    private let statusProvider: () async -> UNAuthorizationStatus
    /// Supplies current suppression inputs. Set by the UI layer
    /// (call / reading / loading / other sheets); defaults to none.
    var suppression: () -> PushPromptSuppression

    init(store: PushPromptStore = PushPromptStore(),
         postTourStore: PostTourPromptsStore = PostTourPromptsStore(),
         suppression: @escaping () -> PushPromptSuppression = { PushPromptSuppression() },
         statusProvider: @escaping () async -> UNAuthorizationStatus = {
             await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
         }) {
        self.store = store
        self.postTourStore = postTourStore
        self.suppression = suppression
        self.statusProvider = statusProvider
    }

    /// Re-derive the state. Safe to call repeatedly.
    func evaluate() async {
        let status = await statusProvider()
        let kind = PushPromptMapping.kind(for: status, pushDeferred: postTourStore.defersSystemPushDialog)

        if PushPromptMapping.isGranted(status) {
            store.clearCounters()
        }
        guard kind != .hidden else { state = .hidden; return }

        // Already showing the right kind: keep it. Presentation consumed the
        // ask, so eligibility would otherwise flip and yank the sheet away.
        if state == kind { return }

        var inputs = suppression()
        inputs.postTourPromptOwed = inputs.postTourPromptOwed || postTourStore.nextPrompt() != nil
        let next = PushPromptMapping.resolve(status: status,
                                             pushDeferred: postTourStore.defersSystemPushDialog,
                                             suppression: inputs,
                                             store: store)
        if next != .hidden { store.recordAsk(for: next) }
        state = next
    }

    /// "Not now" / "Dismiss" / swipe / primary action: the ask was already
    /// counted at presentation, so this only hides the sheet.
    func dismiss() { state = .hidden }
}
