// InviteLinkSection.swift — "Invite link" section of the group info sheet
// (task 20260929-group-invite-links, design-notes.md A). The plaintext link
// exists only in this view model's memory right after creation (never written
// to disk / UserDefaults / Keychain, dropped when the sheet goes away); the
// list is metadata from the server, cached last-known-good. If the backend
// feature flag is off the list endpoint answers a uniform 404 and the whole
// section is hidden (no error).

import SwiftUI
import Combine
import UIKit

@MainActor
final class InviteLinksViewModel: ObservableObject {
    /// Task 20260930-subscription-seat-invites: the same section serves a plan
    /// (`.subscription`, plan owner only). Opening such a link files a join
    /// *request* the owner must accept, so its copy says "request", never "join".
    enum Kind: String { case group, subscription }
    let kind: Kind
    /// The group id or subscription id.
    let targetId: String
    let userId: String
    private let service: DataServiceProtocol

    @Published var list: FSInviteList?
    @Published var unavailable = false
    @Published var loadError: String?
    @Published var refreshFailed = false
    @Published var expiryDays: Int?
    @Published var maxUses: Int?
    @Published var creating = false
    @Published var createError: String?
    /// Show-once reveal. State only; never persisted.
    @Published var revealedURL: String?
    @Published var rowErrors: [String: String] = [:]
    @Published var resetBusy = false
    @Published var resetError: String?
    @Published var resetStatus: String?
    @Published var removedFromGroup = false

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service
        self.kind = .group
        self.targetId = groupId
        self.userId = userId
    }

    init(service: DataServiceProtocol, subscriptionId: String, userId: String) {
        self.service = service
        self.kind = .subscription
        self.targetId = subscriptionId
        self.userId = userId
    }

    var isSubscription: Bool { kind == .subscription }
    private var noun: String { isSubscription ? "plan" : "group" }

    private var cacheKey: String {
        isSubscription ? "subscriptioninvites_\(userId)_\(targetId)" : "groupinvites_\(userId)_\(targetId)"
    }

    var effectiveExpiryDays: Int? { expiryDays ?? list?.options.default_expiry_days }
    var effectiveMaxUses: Int? { maxUses ?? list?.options.default_max_uses }

    func load() async {
        if list == nil, let cached = await DiskCache.shared.load(FSInviteList.self, forKey: cacheKey) { list = cached }
        do {
            let fresh = try isSubscription
                ? await service.listSubscriptionInvites(userId: userId, subscriptionId: targetId)
                : await service.listGroupInvites(userId: userId, groupId: targetId)
            list = fresh
            unavailable = false
            loadError = nil
            refreshFailed = false
            await DiskCache.shared.save(fresh, forKey: cacheKey)
        } catch let e as InviteAPIError {
            if e.status == 404 { unavailable = true; list = nil }
            else if e.status == 403 { removedFromGroup = true }
            else if list != nil { refreshFailed = true }
            else { loadError = "Couldn't load invite links." }
        } catch {
            if list != nil { refreshFailed = true } else { loadError = "Couldn't load invite links." }
        }
    }

    private func persist() async {
        if let list { await DiskCache.shared.save(list, forKey: cacheKey) }
    }

    func create() async {
        guard !creating, let days = effectiveExpiryDays, let uses = effectiveMaxUses else { return }
        creating = true
        createError = nil
        resetStatus = nil
        defer { creating = false }
        do {
            let created = try isSubscription
                ? await service.createSubscriptionInvite(userId: userId, subscriptionId: targetId, expiresInDays: days, maxUses: uses)
                : await service.createGroupInvite(userId: userId, groupId: targetId, expiresInDays: days, maxUses: uses)
            revealedURL = created.url
            let item = FSInviteItem(
                invite_id: created.invite_id, created_by_username: nil, is_mine: true,
                created_at: created.created_at, expires_at: created.expires_at,
                max_uses: created.max_uses, use_count: created.use_count,
                remaining_uses: created.max_uses - created.use_count
            )
            list?.invites.insert(item, at: 0)
            await persist()
        } catch let e as InviteAPIError {
            if e.status == 404 { unavailable = true; return }
            switch (e.status, e.code) {
            case (409, "link_limit"): createError = "You have the maximum number of active links for this \(noun). Revoke one to make another."
            case (409, "not_eligible"): createError = "Invite links need an active plan with more than one seat."
            case (429, _):            createError = "Too many tries. Wait a minute and try again."
            case (403, _):            createError = "You can't create an invite link for this \(noun)."
            default:                  createError = "Couldn't create the link. Please try again."
            }
        } catch {
            createError = "Couldn't create the link. Please try again."
        }
    }

    func revoke(_ item: FSInviteItem, reduceMotion: Bool) async {
        rowErrors[item.invite_id] = nil
        do {
            try await service.revokeInvite(userId: userId, inviteId: item.invite_id)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                list?.invites.removeAll { $0.invite_id == item.invite_id }
            }
            await persist()
        } catch let e as InviteAPIError {
            rowErrors[item.invite_id] = e.status == 403
                ? (isSubscription ? "Only the plan owner can revoke this link." : "Only the person who made this link, or the group creator, can revoke it.")
                : "Couldn't revoke. Please try again."
        } catch {
            rowErrors[item.invite_id] = "Couldn't revoke. Please try again."
        }
    }

    func resetAll() async -> Bool {
        guard !resetBusy else { return false }
        resetBusy = true
        resetError = nil
        defer { resetBusy = false }
        do {
            let n = try isSubscription
                ? await service.resetSubscriptionInvites(userId: userId, subscriptionId: targetId)
                : await service.resetGroupInvites(userId: userId, groupId: targetId)
            list?.invites = []
            revealedURL = nil
            resetStatus = "\(n) \(n == 1 ? "link" : "links") revoked"
            await persist()
            return true
        } catch let e as InviteAPIError {
            resetError = e.status == 429 ? "Too many tries. Wait a minute and try again." : "Couldn't reset the links. Please try again."
        } catch {
            resetError = "Couldn't reset the links. Please try again."
        }
        return false
    }
}

struct InviteLinkSection: View {
    @StateObject private var vm: InviteLinksViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onGroupGone: () -> Void
    private let isSubscription: Bool

    @State private var optionsOpen = false
    @State private var copied = false
    @State private var copyTask: Task<Void, Never>?
    @State private var revokeTarget: FSInviteItem?
    @State private var confirmReset = false
    @AccessibilityFocusState private var revealFocused: Bool

    init(service: DataServiceProtocol, groupId: String, userId: String, onGroupGone: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: InviteLinksViewModel(service: service, groupId: groupId, userId: userId))
        self.onGroupGone = onGroupGone
        self.isSubscription = false
    }

    /// Plan-owner variant for the account subscription card. `onGroupGone` fires
    /// if the server says the caller is no longer the owner (403).
    init(service: DataServiceProtocol, subscriptionId: String, userId: String, onGroupGone: @escaping () -> Void = {}) {
        _vm = StateObject(wrappedValue: InviteLinksViewModel(service: service, subscriptionId: subscriptionId, userId: userId))
        self.onGroupGone = onGroupGone
        self.isSubscription = true
    }

    var body: some View {
        Group {
            if !vm.unavailable {
                section
            }
        }
        .task { await vm.load() }
        .onChange(of: vm.removedFromGroup) { _, gone in if gone { onGroupGone() } }
        .onDisappear { vm.revealedURL = nil }
        .confirmationDialog("Revoke this link?", isPresented: Binding(
            get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }
        ), titleVisibility: .visible, presenting: revokeTarget) { item in
            Button("Revoke", role: .destructive) { Task { await vm.revoke(item, reduceMotion: reduceMotion) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(isSubscription ? "People with it will no longer be able to request to join." : "People with it will no longer be able to join.")
        }
        .confirmationDialog("Reset all links?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Revoke all", role: .destructive) { Task { _ = await vm.resetAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isSubscription ? "Revoke all links for this plan? Nobody will be able to request with them." : "Revoke all links you can manage? Nobody will be able to join with them.")
        }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Invite link")
                .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.gold.opacity(0.7))
                .accessibilityAddTraits(.isHeader)

            if vm.refreshFailed {
                HStack {
                    Text("Couldn't refresh just now. Showing what we have.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.85))
                    Spacer()
                    Button("Try again") { Task { await vm.load() } }
                        .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold).frame(minHeight: 44)
                }
                .padding(.horizontal, Theme.spacingSM)
                .background(Theme.gold.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }

            if let err = vm.loadError {
                HStack {
                    errorText(err)
                    Button("Try again") { Task { await vm.load() } }
                        .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold).frame(minHeight: 44)
                }
            } else if vm.list == nil {
                RoundedRectangle(cornerRadius: Theme.radius).fill(Color.white.opacity(0.08)).frame(height: 56)
                    .accessibilityLabel("Loading invite links")
            }

            if let list = vm.list {
                if list.invites.isEmpty && vm.revealedURL == nil {
                    Text(isSubscription
                         ? "Anyone with the link can ask to join your plan. You approve each request before they get access."
                         : "Anyone with the link can join this group until it expires.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }

                if let url = vm.revealedURL {
                    revealBlock(url)
                } else {
                    createBlock(list.options)
                }

                if !list.invites.isEmpty {
                    Text("Links can't be shown again after they're created.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    VStack(spacing: 0) {
                        ForEach(list.invites) { item in
                            row(item)
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                    }
                }

                if list.invites.count >= 2 {
                    Button { confirmReset = true } label: {
                        Text(vm.resetBusy ? "Resetting…" : "Reset all links")
                            .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.error)
                            .frame(minHeight: 44)
                    }
                    .disabled(vm.resetBusy)
                }
                if let err = vm.resetError { errorText(err) }
                if let status = vm.resetStatus {
                    Text(status).font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                        .accessibilityLabel(status)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Create ──────────────────────────────────────────────────────────────
    private func createBlock(_ options: FSInviteOptions) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            Button { Task { await vm.create() } } label: {
                Group {
                    if vm.creating { ProgressView().tint(Theme.ink) }
                    else { Text("Create invite link").font(.system(size: 15, weight: .bold)) }
                }
                .foregroundColor(Theme.ink)
                .padding(.horizontal, 18)
                .frame(minWidth: 44, minHeight: 44)
                .background(Theme.goldGradient)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(vm.creating)
            .accessibilityLabel(vm.creating ? "Creating invite link" : "Create invite link")

            let days = vm.effectiveExpiryDays ?? options.default_expiry_days
            let uses = vm.effectiveMaxUses ?? options.default_max_uses
            Button { optionsOpen.toggle() } label: {
                Text("Expires in \(days) \(days == 1 ? "day" : "days") · Up to \(uses) \(isSubscription ? (uses == 1 ? "request" : "requests") : (uses == 1 ? "person" : "people"))")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.gold)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .accessibilityHint(optionsOpen ? "Hide options" : "Change expiry and number of people")

            if optionsOpen {
                chipRow(label: "Link expires in", values: options.allowed_expiry_days,
                        selected: days, title: { "\($0) \($0 == 1 ? "day" : "days")" }) { vm.expiryDays = $0 }
                chipRow(label: isSubscription ? "Number of requests the link allows" : "Number of people who can join", values: options.allowed_max_uses,
                        selected: uses, title: { "\($0)" }) { vm.maxUses = $0 }
            }
            if let err = vm.createError { errorText(err) }
        }
    }

    private func chipRow(label: String, values: [Int], selected: Int, title: @escaping (Int) -> String,
                         pick: @escaping (Int) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingSM) {
                ForEach(values, id: \.self) { v in
                    Button { pick(v) } label: {
                        Text(title(v))
                            .font(.inter(Theme.fontXS, weight: .semibold))
                            .foregroundColor(selected == v ? Theme.gold : Theme.parchment.opacity(0.8))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(selected == v ? Theme.gold.opacity(0.15) : Color.clear)
                            .overlay(Capsule().stroke(selected == v ? Theme.borderGold : Theme.borderGoldDim, lineWidth: 1))
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel("\(label): \(title(v))")
                    .accessibilityAddTraits(selected == v ? .isSelected : [])
                }
            }
        }
    }

    // ── Show-once reveal ────────────────────────────────────────────────────
    private func revealBlock(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text(url)
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel("Invite link \(url)")
                .accessibilityFocused($revealFocused)
            HStack(spacing: Theme.spacingSM) {
                Button {
                    UIPasteboard.general.string = url
                    copied = true
                    copyTask?.cancel()
                    copyTask = Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if !Task.isCancelled { copied = false }
                    }
                    UIAccessibility.post(notification: .announcement, argument: "Link copied")
                } label: {
                    Text(copied ? "Copied" : "Copy").font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 18).frame(minWidth: 88, minHeight: 44)
                        .background(Theme.goldGradient).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                if let shareURL = URL(string: url) {
                    ShareLink(item: shareURL) {
                        Text("Share").font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                            .padding(.horizontal, 18).frame(minWidth: 88, minHeight: 44)
                            .overlay(Capsule().stroke(Theme.borderGoldDim, lineWidth: 1))
                    }
                }
            }
            Text("This link is shown once. If you close this, make a new link to share again.")
                .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
            Button("Done") { vm.revealedURL = nil; copied = false }
                .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold).frame(minHeight: 44)
        }
        .padding(Theme.spacingSM)
        .background(Theme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .onAppear {
            revealFocused = true
            UIAccessibility.post(notification: .announcement, argument: "Invite link created")
        }
    }

    // ── Active links ────────────────────────────────────────────────────────
    private func row(_ item: FSInviteItem) -> some View {
        let label = Self.expiryLabel(item.expires_at)
        let who = item.is_mine ? "you" : (item.created_by_username ?? (isSubscription ? "the plan owner" : "a member"))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.spacingSM) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                    Text("\(item.remaining_uses) of \(item.max_uses) \(isSubscription ? "requests" : "spots") left · Created by \(who)")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Button { revokeTarget = item } label: {
                    Text("Revoke").font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.error)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Revoke link \(label.lowercased()), created by \(who)")
            }
            if let err = vm.rowErrors[item.invite_id] { errorText(err) }
        }
        .frame(minHeight: 56)
    }

    private func errorText(_ text: String) -> some View {
        Text(text).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
            .accessibilityLabel(text)
    }

    /// "Expires Oct 7", or "Expires in 5 hours" when under 24h remain.
    static func expiryLabel(_ iso: String, now: Date = Date()) -> String {
        guard let date = parseFlexibleISO8601(iso) else { return "" }
        let secs = date.timeIntervalSince(now)
        if secs < 24 * 3600 {
            let hours = max(1, Int((secs / 3600).rounded(.up)))
            return "Expires in \(hours) \(hours == 1 ? "hour" : "hours")"
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return "Expires \(f.string(from: date))"
    }
}
