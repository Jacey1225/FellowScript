// OnboardingEngine.swift -- task 20261105-onboarding-redo.
// The single walkthrough engine. Screens call `OnboardingEngine.shared.report(_:)`
// after a real action succeeded; the engine is a no-op unless a walkthrough is
// running and the event matters to the current cue. Views stay thin: they read
// `currentCue`, `gate`, `anchorFrames` and call `skipPart()` / `finishRecap()`.
//
//   report(.devotionSaved)      // in AccountViewModel.createEvent, after the server accepted
//   report(.friendRequestSent)  // in ChatRootView, after sendFriendRequest returned
//
// First run: the survey calls `savePicks` (phase .pending). Once the user is
// signed in and the main screen is ready, ContentView calls `startIfPending()`.
// Replay: Account calls `startReplay(picks:)`; replay never touches the
// PostTourPromptsStore keys, so it cannot re-arm or lift the push deferral.

import SwiftUI
import Combine

@MainActor
final class OnboardingEngine: ObservableObject {
    static let shared = OnboardingEngine()

    /// Free-tier gate for parts that need a subscription. Fails closed.
    enum Gate: Equatable { case open, checking, needsSubscription }

    @Published private(set) var state: OnboardingFlowState?
    @Published private(set) var gate: Gate = .open
    /// Warm, user-facing failure for the current cue (cleared on the next event).
    @Published var errorMessage: String?
    /// Global frames of spotlight targets, reported by `.onboardingAnchor(_:)`.
    @Published private(set) var anchorFrames: [OnboardingAnchorID: CGRect] = [:]

    static let uiTestEnableArgument = "UI-TESTING-WALKTHROUGH"
    private var store: OnboardingProgressStore
    /// Chat tour progress slot (task 20261106-chat-tour); separate from `store`.
    private var chatStore: OnboardingProgressStore
    /// Offer lifecycle for the chat tour. The only prompt-ish store the chat tour writes.
    private let chatTourStore: ChatTourStore
    /// Records the first-run outcome for the "Take a quick tour" prompt (task
    /// 20261105-take-tour-prompt). Written only when a FIRST-RUN flow ends.
    private let tourPromptStore: TourPromptStore
    private let arguments: [String]
    private var subscriptionCheck: (() async -> Bool)?
    private var gatedPart: OnboardingPart?
    private var gateTask: Task<Void, Never>?

    init(store: OnboardingProgressStore = OnboardingProgressStore(),
         tourPromptStore: TourPromptStore = TourPromptStore(),
         chatTourStore: ChatTourStore = ChatTourStore(),
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.store = store
        self.tourPromptStore = tourPromptStore
        self.arguments = arguments
        self.chatTourStore = chatTourStore
        var chat = store
        chat.slot = OnboardingProgressStore.chatTourKey
        self.chatStore = chat
        // First-run data wins; a chat-tour slot is only read when nothing else is live.
        if let first = store.load() {
            self.state = first
        } else if let saved = chat.load() {
            var normalized = saved
            normalized.normalizeChatResume()
            self.state = normalized
            // Re-save only when the resume normalization actually changed something.
            if normalized != saved { chat.save(normalized) }
        } else {
            self.state = nil
        }
    }

    // MARK: Derived

    /// True while a walkthrough or recap owns the screen.
    var isActive: Bool { state?.phase == .walking || state?.phase == .recap }
    /// True from "survey done" until the flow ends. Post-tour prompts wait on this.
    var blocksPostTourPrompts: Bool { state != nil && state?.mode == .firstRun }
    var currentCue: OnboardingCue? { state?.currentCue }
    var currentPart: OnboardingPart? { state?.currentPart }
    var isRecap: Bool { state?.phase == .recap }
    var isReplay: Bool { state?.mode == .replay }
    var isChatTour: Bool { state?.mode == .chatTour }

    /// Prefilled prompt for the devotion form while that part is running.
    var starterPromptIfActive: String? {
        currentPart == .devotion && gate == .open
            ? "A short morning devotion on a passage I can read in five minutes, with one question to pray over."
            : nil
    }

    // MARK: Setup

    /// Provides the entitlement lookup (read-only; entitlement logic is unchanged).
    func configure(service: DataServiceProtocol, userId: String) {
        subscriptionCheck = {
            guard !userId.isEmpty else { return false }
            if (try? await service.fetchUsage(userId: userId))?.subscribed == true { return true }
            return !(await StoreKitManager.shared.activeEntitlementProductIDs()).isEmpty
        }
        refreshGate()
    }

    // MARK: Lifecycle

    /// Survey finished (pre-auth). Persist picks; the walkthrough starts after sign-in.
    func savePicks(_ picks: Set<OnboardingTopic>) {
        commit(OnboardingFlowState(mode: .firstRun, picks: picks))
    }

    /// Sign-in finished: start the saved first-run flow. Safe to call repeatedly.
    func startIfPending() {
        guard var s = state, s.phase == .pending, s.mode == .firstRun else { return }
        // Existing UI tests sign in through onboarding and must not meet a coach
        // card or recap; "UI-TESTING-WALKTHROUGH" opts a test back in.
        if arguments.contains("UI-TESTING"), !arguments.contains(Self.uiTestEnableArgument) {
            commit(nil)
            return
        }
        s.begin()
        commit(s)
    }

    /// Replay from Account (user already signed in).
    func startReplay(picks: Set<OnboardingTopic>) {
        guard state == nil else { return }  // never clobber a running first-run flow
        var s = OnboardingFlowState(mode: .replay, picks: picks)
        s.begin()
        commit(s)
    }

    /// Chat tour from the Chat tab offer or Account. `options` describes this
    /// user's real friends and capabilities (build it fail-closed). Never touches
    /// TourPromptStore or PostTourPromptsStore. No-ops while any flow exists.
    func startChatTour(options: ChatTourOptions) {
        guard state == nil else { return }
        var s = OnboardingFlowState(chatTour: options)
        s.begin()
        commit(s)
        chatTourStore.recordStarted()
    }

    /// Recap "Continue": ends the flow. First run: ContentView then runs the
    /// existing push and subscribe prompts (the engine never arms or clears them).
    func finishRecap() {
        guard let s = state, s.phase == .recap else { return }
        // First run only: remember whether anything was finished so a skipper can
        // be offered the tour later. Replay never writes the marker.
        if s.mode == .firstRun { tourPromptStore.recordFirstRunOutcome(completedParts: s.completed.count) }
        if s.mode == .chatTour, s.completed.contains(.chat) { chatTourStore.recordCompleted() }
        commit(nil)
    }

    // MARK: Events

    func report(_ event: OnboardingEvent) {
        guard var s = state, s.phase == .walking, gate == .open else { return }
        errorMessage = nil
        guard s.apply(event) != .ignored else { return }
        commit(s)
    }

    /// A step's real action failed: keep the step open and show why.
    func reportFailure(_ event: OnboardingEvent, message: String) {
        guard let s = state, s.phase == .walking, let part = s.currentPart,
              s.cues(for: part).contains(where: { $0.advancesOn == event }) else { return }
        errorMessage = message
    }

    /// A surface (sheet or pushed screen) went away. If the current cue lived
    /// there, rewind to the part's first cue. A late success event still lands
    /// because `apply` accepts any cue at or after the current one.
    func surfaceDismissed(cueIDs: Set<String>) {
        guard var s = state, let cue = s.currentCue, cueIDs.contains(cue.id), s.cueIndex > 0 else { return }
        s.rewindToFirstCue()
        commit(s)
    }

    func surfaceDismissed(_ surface: OnboardingSurface) {
        guard let cue = state?.currentCue, cue.surface == surface else { return }
        surfaceDismissed(cueIDs: [cue.id])
    }

    /// Escape hatch for a chat tour the user cannot continue: ends it without a
    /// recap and keeps the offer state as-is. Never touches a first-run flow.
    func endChatTour() {
        guard state?.mode == .chatTour else { return }
        commit(nil)
    }

    func skipPart() {
        guard var s = state, s.phase == .walking else { return }
        errorMessage = nil
        s.skipCurrentPart()
        commit(s)
    }

    // MARK: Anchors

    func updateAnchor(_ id: OnboardingAnchorID, frame: CGRect?) {
        guard isActive else { return }
        if let frame, frame.width > 1, frame.height > 1 {
            if anchorFrames[id] != frame { anchorFrames[id] = frame }
        } else if anchorFrames[id] != nil {
            anchorFrames[id] = nil
        }
    }

    // MARK: Internals

    private func commit(_ new: OnboardingFlowState?) {
        let previousMode = state?.mode
        state = new
        if let new {
            if new.mode == .chatTour { chatStore.save(new) } else { store.save(new) }
        } else if previousMode == .chatTour {
            chatStore.save(nil)   // ending a chat tour never touches the first-run slot
        } else {
            store.save(nil)
        }
        if new == nil { anchorFrames = [:]; errorMessage = nil }
        refreshGate()
    }

    /// Re-evaluates the subscription gate when the current part changes.
    /// Unknown, offline or erroring lookups stay closed (needsSubscription).
    private func refreshGate() {
        guard let part = currentPart, part.requiresSubscription else {
            gateTask?.cancel(); gatedPart = nil; gate = .open
            return
        }
        guard gatedPart != part else { return }
        gatedPart = part
        gateTask?.cancel()
        guard let check = subscriptionCheck else {
            gate = .needsSubscription  // fail closed until configured
            gatedPart = nil
            return
        }
        gate = .checking
        gateTask = Task { [weak self] in
            let subscribed = await check()
            guard !Task.isCancelled, let self, self.gatedPart == part else { return }
            self.gate = subscribed ? .open : .needsSubscription
        }
    }
}
