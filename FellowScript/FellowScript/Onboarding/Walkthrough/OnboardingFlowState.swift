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
    enum Mode: String, Codable { case firstRun, replay }
    enum PartStatus: Equatable { case done, skipped, notReached }
    enum Outcome: Equatable { case ignored, cueAdvanced, partCompleted, reachedRecap }

    var mode: Mode
    var phase: Phase
    var picks: [OnboardingTopic]
    var partIndex: Int = 0
    var cueIndex: Int = 0
    var completed: [OnboardingPart] = []
    var skipped: [OnboardingPart] = []

    init(mode: Mode, picks: Set<OnboardingTopic>, phase: Phase = .pending) {
        self.mode = mode
        self.phase = phase
        self.picks = OnboardingTopic.allCases.filter { picks.contains($0) }
    }

    // MARK: Plan

    /// Parts for a set of picks: picked topics in fixed order, then friends (always).
    static func plan(for picks: Set<OnboardingTopic>) -> [OnboardingPart] {
        OnboardingTopic.allCases.filter { picks.contains($0) }.map(\.part) + [.friend]
    }

    var parts: [OnboardingPart] { Self.plan(for: Set(picks)) }
    var totalParts: Int { parts.count }
    var partNumber: Int { min(partIndex, parts.count - 1) + 1 }

    var currentPart: OnboardingPart? {
        phase == .walking && parts.indices.contains(partIndex) ? parts[partIndex] : nil
    }
    var currentCue: OnboardingCue? {
        guard let part = currentPart else { return nil }
        let cues = part.cues
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
        let cues = part.cues
        guard let hit = cues.indices.first(where: { $0 >= cueIndex && cues[$0].advancesOn == event }) else {
            return .ignored
        }
        if hit == cues.count - 1 {
            completed.append(part)
            return moveToNextPart()
        }
        cueIndex = hit + 1
        return .cueAdvanced
    }

    /// "Skip this step": the whole current part is left open.
    @discardableResult
    mutating func skipCurrentPart() -> Outcome {
        guard let part = currentPart else { return .ignored }
        skipped.append(part)
        return moveToNextPart()
    }

    /// A sheet or pushed screen closed before its cue finished: go back to the
    /// part's opening cue so the card is never stranded without a screen.
    mutating func rewindToFirstCue() {
        guard phase == .walking else { return }
        cueIndex = 0
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
        guard partIndex >= 0, cueIndex >= 0, partIndex <= parts.count else { return nil }
        if phase == .walking {
            guard partIndex < parts.count, cueIndex < parts[partIndex].cues.count else { return nil }
        }
        return self
    }
}

/// UserDefaults persistence for the flow state. Injectable for tests.
struct OnboardingProgressStore {
    static let key = "onboarding.progress.v1"
    var defaults: UserDefaults = .standard

    func load() -> OnboardingFlowState? {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(OnboardingFlowState.self, from: data) else { return nil }
        return state.validated()
    }

    func save(_ state: OnboardingFlowState?) {
        guard let state, let data = try? JSONEncoder().encode(state) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
