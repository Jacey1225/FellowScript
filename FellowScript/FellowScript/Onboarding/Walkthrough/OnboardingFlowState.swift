// OnboardingFlowState.swift -- task 20261105-onboarding-redo.
// The persisted, pure progression model for the walkthrough: which parts run
// (from survey picks), where the user is, what is done or skipped, and how an
// OnboardingEvent moves things. `OnboardingProgressStore` saves it in
// UserDefaults so a kill mid-walkthrough resumes at the same cue.
//
// Replay (`mode == .replay`) uses the same model but is flagged so the host
// never touches the post-tour prompt keys (PostTourPromptsStore) for it.

import Foundation

struct OnboardingFlowState: Codable, Equatable {
    enum Phase: String, Codable { case pending, walking, recap }
    enum Mode: String, Codable { case firstRun, replay
        /// Standalone chat tour (task 20261106-chat-tour): parts are always [.chat],
        /// persisted under its own key, never touches first-run or post-tour keys.
        case chatTour }
    enum PartStatus: Equatable { case done, skipped, notReached }
    enum Outcome: Equatable { case ignored, cueAdvanced, partCompleted, reachedRecap }

    var mode: Mode
    var phase: Phase
    var picks: [OnboardingTopic]
    var partIndex: Int = 0
    var cueIndex: Int = 0
    var completed: [OnboardingPart] = []
    var skipped: [OnboardingPart] = []
    /// Chat tour only. Optional so first-run data (which lacks the key) still decodes
    /// and encodes byte-identically.
    var chatOptions: ChatTourOptions?
    /// Chat tour only: ids of the cues whose real action completed (drives the
    /// recap). Optional for the same byte-compatibility reason as `chatOptions`.
    var chatDoneCues: [String]?

    init(mode: Mode, picks: Set<OnboardingTopic>, phase: Phase = .pending) {
        self.mode = mode
        self.phase = phase
        self.picks = OnboardingTopic.allCases.filter { picks.contains($0) }
    }

    /// Chat tour state. Options are frozen at start so resume shows the same cues.
    init(chatTour options: ChatTourOptions, phase: Phase = .pending) {
        self.mode = .chatTour
        self.phase = phase
        self.picks = []
        self.chatOptions = options
    }

    // MARK: Plan

    /// Parts for a set of picks: picked topics in fixed order, then friends (always).
    static func plan(for picks: Set<OnboardingTopic>) -> [OnboardingPart] {
        OnboardingTopic.allCases.filter { picks.contains($0) }.map(\.part) + [.friend]
    }

    var parts: [OnboardingPart] { mode == .chatTour ? [.chat] : Self.plan(for: Set(picks)) }

    /// Cues for a part in THIS flow (chat cues depend on the frozen options).
    func cues(for part: OnboardingPart) -> [OnboardingCue] {
        part == .chat ? OnboardingCue.chatCues(options: chatOptions ?? .none) : part.cues
    }
    var totalParts: Int { parts.count }
    var partNumber: Int { min(partIndex, parts.count - 1) + 1 }

    var currentPart: OnboardingPart? {
        phase == .walking && parts.indices.contains(partIndex) ? parts[partIndex] : nil
    }
    var currentCue: OnboardingCue? {
        guard let part = currentPart else { return nil }
        let cues = cues(for: part)
        return cues.indices.contains(cueIndex) ? cues[cueIndex] : nil
    }

    func status(of part: OnboardingPart) -> PartStatus {
        if completed.contains(part) { return .done }
        if skipped.contains(part) { return .skipped }
        return .notReached
    }

    // MARK: Transitions

    /// Sign-in done (or replay started): start the first part.
    mutating func begin() {
        guard phase == .pending else { return }
        partIndex = 0
        cueIndex = 0
        phase = .walking
    }

    /// Moves forward ONLY if `event` completes this cue or a later cue of the
    /// current part (the user can legitimately get ahead of the card).
    @discardableResult
    mutating func apply(_ event: OnboardingEvent) -> Outcome {
        guard let part = currentPart else { return .ignored }
        let cues = cues(for: part)
        guard let hit = cues.indices.first(where: { $0 >= cueIndex && cues[$0].advancesOn == event }) else {
            return .ignored
        }
        if mode == .chatTour { chatDoneCues = (chatDoneCues ?? []) + [cues[hit].id] }
        if hit == cues.count - 1 {
            completed.append(part)
            return moveToNextPart()
        }
        cueIndex = hit + 1
        return .cueAdvanced
    }

    /// "Skip this step": the whole current part is left open. In the chat tour
    /// only the current STEP is left open and the tour moves to the next step.
    @discardableResult
    mutating func skipCurrentPart() -> Outcome {
        guard let part = currentPart else { return .ignored }
        if mode == .chatTour { return skipChatStep(part) }
        skipped.append(part)
        return moveToNextPart()
    }

    /// Chat tour: jump to the first cue of the next step whose screen the user can
    /// actually reach from where they are: a root cue (always reachable), or a cue on
    /// the same surface as the current one (e.g. already inside the thread). Steps that
    /// need a sheet that is not open (a thread from the chat list, say) are skipped
    /// together, so a skip never lands on a card nothing can draw. Skipping the last
    /// step ends the tour: completed if anything was really done, otherwise skipped.
    private mutating func skipChatStep(_ part: OnboardingPart) -> Outcome {
        let cs = cues(for: part)
        guard cs.indices.contains(cueIndex) else { return .ignored }
        if let next = Self.chatSkipTarget(in: cs, from: cueIndex) {
            cueIndex = next
            return .cueAdvanced
        }
        if (chatDoneCues ?? []).isEmpty { skipped.append(part) } else { completed.append(part) }
        return moveToNextPart()
    }

    /// Index a chat-tour skip from `index` lands on, or nil when the tour should end.
    /// Only the FIRST cue of a later step qualifies, and only if its surface is
    /// `.root` or the current cue's own surface.
    static func chatSkipTarget(in cs: [OnboardingCue], from index: Int) -> Int? {
        guard cs.indices.contains(index) else { return nil }
        let current = cs[index]
        let currentStep = current.step ?? 0
        var seen = Set<Int>()
        for i in cs.indices where i > index {
            let step = cs[i].step ?? 0
            guard step > currentStep, seen.insert(step).inserted else { continue }
            if cs[i].surface == .root || cs[i].surface == current.surface { return i }
        }
        return nil
    }

    /// Chat tour resume after a relaunch: sheets are not restored, so a saved cue
    /// that lives on a sheet goes back to the root cue that opens it.
    mutating func normalizeChatResume() {
        guard mode == .chatTour, phase == .walking, let part = currentPart else { return }
        let cs = cues(for: part)
        guard cs.indices.contains(cueIndex), cs[cueIndex].surface != .root else { return }
        rewindToFirstCue()
    }

    /// Chat tour recap: did this cue's real action happen?
    func chatCueDone(_ cueID: String) -> Bool { (chatDoneCues ?? []).contains(cueID) }

    /// A sheet or pushed screen closed before its cue finished: go back to the
    /// part's opening cue so the card is never stranded without a screen.
    mutating func rewindToFirstCue() {
        guard phase == .walking else { return }
        guard mode == .chatTour, let part = currentPart else { cueIndex = 0; return }
        // Chat tour has many sheets in one part: go back only to the cue that
        // opens the sheet we were in, not to the very first cue.
        let cues = cues(for: part)
        guard cues.indices.contains(cueIndex) else { cueIndex = 0; return }
        let surface = cues[cueIndex].surface
        var j = cueIndex
        while j > 0, cues[j].surface == surface { j -= 1 }
        cueIndex = j
    }

    private mutating func moveToNextPart() -> Outcome {
        partIndex += 1
        cueIndex = 0
        if partIndex >= parts.count {
            phase = .recap
            return .reachedRecap
        }
        return .partCompleted
    }

    /// Defensive clamp after decoding stored data (tampering / older build).
    func validated() -> OnboardingFlowState? {
        if mode == .chatTour, !picks.isEmpty || chatOptions == nil { return nil }
        if mode != .chatTour, chatOptions != nil || chatDoneCues != nil { return nil }
        guard partIndex >= 0, cueIndex >= 0, partIndex <= parts.count else { return nil }
        if phase == .walking {
            guard partIndex < parts.count, cueIndex < cues(for: parts[partIndex]).count else { return nil }
        }
        return self
    }
}

/// UserDefaults persistence for the flow state. Injectable for tests.
struct OnboardingProgressStore {
    static let key = "onboarding.progress.v1"
    /// Chat tour progress lives apart so first-run data can never be corrupted.
    static let chatTourKey = "onboarding.chattour.progress.v1"
    var defaults: UserDefaults = .standard
    /// Which slot this store reads and writes. Defaults to the first-run slot.
    var slot: String = OnboardingProgressStore.key

    func load() -> OnboardingFlowState? {
        guard let data = defaults.data(forKey: slot),
              let state = try? JSONDecoder().decode(OnboardingFlowState.self, from: data) else { return nil }
        // A slot only ever holds its own kind of flow; anything else is tampered.
        guard (state.mode == .chatTour) == (slot == Self.chatTourKey) else { return nil }
        return state.validated()
    }

    func save(_ state: OnboardingFlowState?) {
        guard let state, let data = try? JSONEncoder().encode(state) else {
            defaults.removeObject(forKey: slot)
            return
        }
        defaults.set(data, forKey: slot)
    }
}
