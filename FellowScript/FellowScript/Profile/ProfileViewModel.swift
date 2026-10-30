// ProfileViewModel.swift (task 20261030-user-profiles)
// State and actions for ProfileView.
//
// Rules honored here:
//  * throw-not-fabricate: a failed load never invents a profile; with nothing
//    cached the screen shows an error, not placeholder text.
//  * preserve-cache-on-failed-refresh: a network/5xx failure keeps the cached
//    profile on screen with a quiet notice. Only a 404 (unknown, blocked or
//    suspended, deliberately indistinguishable) evicts it.
//  * No user-facing message ever says "blocked", "not found" or "already
//    requested" for friend actions (security D5); copy is uniform.

import Foundation
import Combine
import SwiftUI

@MainActor
final class ProfileViewModel: ObservableObject {
    enum Phase: Equatable { case loading, loaded, unavailable, failed }

    static let bioMaxLength = 160           // mirrors api/config/profile.json bio_max_length
    static let undoWindow: UInt64 = 6_000_000_000

    let viewerId: String
    let targetId: String
    private let service: DataServiceProtocol
    private let cache: ProfileCache

    @Published private(set) var profile: FSProfile?
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isRefreshing = false
    /// Quiet polite status under the actions (refresh failure, report result, ...).
    @Published var statusMessage: String?
    @Published var actionError: String?
    @Published private(set) var busy = false
    /// True during the 6s client-side undo window after "Unfriend".
    @Published private(set) var unfriendPending = false

    // Bio editing
    @Published var isEditingBio = false
    @Published var draft = ""
    @Published var bioError: String?
    @Published private(set) var isSavingBio = false
    @Published private(set) var bioJustSaved = false

    private var unfriendTask: Task<Void, Never>?

    init(viewerId: String, targetId: String, service: DataServiceProtocol, cache: ProfileCache? = nil) {
        self.viewerId = viewerId
        self.targetId = targetId
        self.service = service
        self.cache = cache ?? .shared
    }

    var isSelf: Bool { targetId == viewerId }

    // MARK: Load

    func load() async {
        if profile == nil, let cached = cache.profile(viewer: viewerId, target: targetId) {
            profile = cached
            phase = .loaded
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await service.fetchProfile(targetId: targetId)
            guard !Task.isCancelled else { return }
            apply(fresh)
            statusMessage = nil
        } catch AppError.notFound {
            // 404 is the privacy signal (block/suspend/unfriend race): drop it all.
            cache.evict(viewer: viewerId, target: targetId)
            profile = nil
            phase = .unavailable
            statusMessage = nil
        } catch {
            if Self.isCancellation(error) { return }
            if profile != nil {
                statusMessage = "Couldn't refresh. Showing what we had."
            } else {
                phase = .failed
            }
        }
    }

    private func apply(_ fresh: FSProfile) {
        profile = fresh
        phase = .loaded
        if !unfriendPending { cache.store(fresh, viewer: viewerId) }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: Friend actions

    func addFriend() async {
        await runFriendAction(failure: "Couldn't send that right now. Please try again.") {
            try await self.service.sendProfileFriendRequest(targetId: self.targetId)
        }
    }

    func acceptRequest() async {
        await runFriendAction(failure: "Couldn't accept that right now. Please try again.") {
            try await self.service.acceptProfileFriendRequest(targetId: self.targetId)
        }
    }

    private func runFriendAction(failure: String, _ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            try await work()
            // The send route is uniform (204 even when nothing was recorded), so
            // never assume the new state: refetch and show what the server says.
            await load()
        } catch {
            actionError = Self.friendActionMessage(error, fallback: failure)
            await load()
        }
    }

    static func friendActionMessage(_ error: Error, fallback: String) -> String {
        if case AppError.rateLimited = error { return "Slow down a little and try again in a moment." }
        return fallback
    }

    // MARK: Unfriend (deferred commit, client-side undo)

    func beginUnfriend() {
        guard profile?.relationship == .friends, !unfriendPending else { return }
        unfriendPending = true
        // The bio is hidden the moment the user taps Unfriend.
        cache.evict(viewer: viewerId, target: targetId)
        unfriendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await self?.commitUnfriend()
        }
    }

    func undoUnfriend() {
        unfriendTask?.cancel()
        unfriendTask = nil
        unfriendPending = false
    }

    /// Commits right away (leaving the screen inside the undo window).
    func commitUnfriendNow() async {
        unfriendTask?.cancel()
        unfriendTask = nil
        if unfriendPending { await commitUnfriend() }
    }

    private func commitUnfriend() async {
        guard unfriendPending else { return }
        unfriendTask = nil
        do {
            try await service.removeFriend(userId: viewerId, friendId: targetId)
            unfriendPending = false
            await load()
        } catch {
            unfriendPending = false
            actionError = "Couldn't remove that friend. Please try again."
            await load()
        }
    }

    // MARK: Block / report

    /// Returns true when the block succeeded (caller dismisses the screen).
    func block() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await service.blockUser(userId: viewerId, blockedId: targetId)
            cache.evict(viewer: viewerId, target: targetId)
            return true
        } catch {
            actionError = "Couldn't block right now. Please try again."
            return false
        }
    }

    func report(reason: String, detail: String) async {
        do {
            try await service.reportUser(reportedUserId: targetId, reason: reason, detail: detail)
            statusMessage = "Report submitted. We review every report within 24 hours."
        } catch {
            actionError = "Couldn't send the report. Please try again."
        }
    }

    // MARK: Bio editing

    /// Server rule: NFC, whitespace runs (incl. newlines) collapse to one space, trimmed.
    static func normalizedBio(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
    var normalizedDraft: String { Self.normalizedBio(draft) }
    var draftLength: Int { normalizedDraft.unicodeScalars.count }
    var draftRemaining: Int { Self.bioMaxLength - draftLength }
    var canSaveBio: Bool { !isSavingBio && draftRemaining >= 0 }

    func beginEditingBio() {
        guard profile?.editable == true else { return }
        draft = profile?.bio ?? ""
        bioError = nil
        bioJustSaved = false
        isEditingBio = true
    }

    func cancelEditingBio() {
        isEditingBio = false
        bioError = nil
    }

    func saveBio() async {
        guard canSaveBio, var current = profile else { return }
        isSavingBio = true
        bioError = nil
        defer { isSavingBio = false }
        let text = normalizedDraft
        do {
            let stored = try await service.updateBio(userId: viewerId, bio: text.isEmpty ? nil : text)
            current.bio = stored
            current.bioVisible = true
            apply(current)
            isEditingBio = false
            bioJustSaved = true
            UIAccessibility.post(notification: .announcement, argument: "Bio saved")
        } catch {
            // The draft is never cleared on failure.
            bioError = Self.bioErrorMessage(error)
        }
    }

    static func bioErrorMessage(_ error: Error) -> String {
        let generic = "Couldn't save your bio. Your text is still here."
        switch error {
        case AppError.rateLimited:
            return "You've edited a lot just now. Try again in a few minutes."
        case AppError.networkError(let message):
            // 422/403 carry a user-facing sentence; a bare "Server error NNN" does not.
            return message.hasPrefix("Server error") ? generic : message
        default:
            return generic
        }
    }
}
