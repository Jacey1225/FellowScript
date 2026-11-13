// VerseAskViewModel.swift -- task 20261112-verse-ask-ai (step 5).
// State for one open per-verse Ask AI overlay. One question at a time; the
// answer is ephemeral (never saved). Errors are shown, never swallowed, and
// the typed question is kept so Try again resends it. Dismissing cancels any
// in-flight request, and a late reply is ignored.

import SwiftUI
import UIKit
import Combine

enum VerseAskCopy {
    static let generic = "Couldn't reach Ask AI just now. Try again in a moment."
    static let offline = "You're offline. Reconnect and try again."
    static let limit = "You've asked a lot today. Try again later."

    /// Warm, non-technical copy. Server text is already user-safe, except rate limiting.
    static func message(for error: Error) -> String {
        guard let e = error as? VerseAskError else { return generic }
        switch e {
        case .offline: return offline
        case .server(let m):
            if m.range(of: "too many|slow down|rate", options: [.regularExpression, .caseInsensitive]) != nil { return limit }
            return m.isEmpty ? generic : m
        case .timeout, .network: return generic
        }
    }
}

@MainActor
final class VerseAskViewModel: ObservableObject {
    static let maxQuestionChars = 500
    static let counterFrom = 450

    enum Phase: Equatable {
        case idle
        case loading(question: String)
        case answer(question: String, text: String)
        case failed(question: String, message: String)
    }

    let reference: String
    let verseNumber: Int
    let context: VerseAskContext
    @Published var draft = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var copied = false

    private let userId: String
    private let transport: VerseAskTransport
    private let copyToPasteboard: (String) -> Void
    private var task: Task<Void, Never>?
    private var copiedReset: Task<Void, Never>?
    private var generation = 0

    init(userId: String, verseNumber: Int, context: VerseAskContext,
         transport: VerseAskTransport,
         copyToPasteboard: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) {
        self.userId = userId
        self.verseNumber = verseNumber
        self.reference = context.reference
        self.context = context
        self.transport = transport
        self.copyToPasteboard = copyToPasteboard
    }

    var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isLoading: Bool { if case .loading = phase { return true }; return false }
    var canSend: Bool { !trimmedDraft.isEmpty && trimmedDraft.count <= Self.maxQuestionChars && !isLoading }
    var showsCounter: Bool { draft.count >= Self.counterFrom }
    var atLimit: Bool { draft.count >= Self.maxQuestionChars }
    var hasPanel: Bool { phase != .idle }
    var answerText: String? { if case .answer(_, let t) = phase { return t }; return nil }

    func send() {
        guard canSend else { return }
        run(question: trimmedDraft)
    }

    func retry() {
        guard case .failed(let q, _) = phase else { return }
        run(question: q)
    }

    private func run(question: String) {
        task?.cancel()
        generation += 1
        let gen = generation
        phase = .loading(question: question)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.transport.askVerse(userId: self.userId, question: question, context: self.context)
                guard gen == self.generation, !Task.isCancelled else { return }
                self.phase = .answer(question: question, text: reply)
            } catch is CancellationError {
                return
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                self.phase = .failed(question: question, message: VerseAskCopy.message(for: error))
            }
        }
    }

    func copyAnswer() {
        guard let text = answerText else { return }
        copyToPasteboard(text)
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    /// Cancels any in-flight request; a late reply is ignored.
    func cancel() {
        generation += 1
        task?.cancel(); task = nil
        copiedReset?.cancel()
    }
}
