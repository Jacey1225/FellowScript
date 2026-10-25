// GroupJoinRequestsSection.swift -- owner-only "Join requests" section of the
// group info sheet (task 20261011-join-requests-ios-email step 2; registry
// order 20). Mirrors the desktop GroupJoinRequestsSection / JoinRequestsList /
// AcceptRequestsSwitch.
//
// Visible only when capabilities.features.join_requests is true AND the caller
// owns the group (the server route is owner-only and 404s for everyone else).
// Off / missing / failed capabilities = nothing rendered and no network call.
//
// Throw-not-fabricate: an empty list is shown only after a successful fetch.
// Preserve-cache-on-failed-refresh: a failed reload keeps the rows already on
// screen and shows an inline error. Applicant names and notes are untrusted and
// rendered as plain Text only. Nothing is persisted to disk (no applicant PII
// cache).

import SwiftUI
import Combine

@MainActor
final class GroupJoinRequestsViewModel: ObservableObject {
    struct UndoItem: Equatable { let request: FSJoinRequest; let block: Bool }

    @Published private(set) var requests: [FSJoinRequest] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var accepting = true
    /// true once a fetch has succeeded (an empty list is real only then).
    @Published private(set) var loaded = false
    @Published private(set) var isLoading = false
    /// Message for the last failed list load; cleared on the next success.
    @Published private(set) var listError: String?
    /// 404 on the list: group not published / not the owner. Shows guidance.
    @Published private(set) var unavailable = false
    @Published private(set) var busyId: String?
    @Published private(set) var rowErrors: [String: String] = [:]
    @Published private(set) var switchBusy = false
    @Published private(set) var switchError: String?
    @Published private(set) var undo: UndoItem?
    @Published private(set) var announcement = ""

    private let service: DataServiceProtocol
    private let groupId: String
    private let userId: String
    private var undoTask: Task<Void, Never>?
    private var loadSeq = 0

    /// Pure visibility rule for the registry (tested).
    nonisolated static func isVisible(_ caps: FSCapabilities, isOwner: Bool) -> Bool {
        caps.isEnabled("join_requests") && isOwner
    }

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service
        self.groupId = groupId
        self.userId = userId
    }

    deinit { undoTask?.cancel() }

    func load() async {
        loadSeq += 1
        let my = loadSeq
        isLoading = true
        defer { if my == loadSeq { isLoading = false } }
        do {
            let list = try await service.fetchJoinRequests(userId: userId, groupId: groupId)
            guard my == loadSeq else { return }
            requests = list.requests
            pendingCount = list.pendingCount
            accepting = list.acceptingRequests
            loaded = true
            unavailable = false
            listError = nil
        } catch {
            guard my == loadSeq else { return }
            if let e = error as? FSJoinRequestsError, e == .notFound {
                unavailable = true
                requests = []; pendingCount = 0; loaded = false
                listError = nil
                return
            }
            // Keep whatever is already shown; only flag the failure.
            listError = Self.message(error, fallback: "Couldn't load join requests.")
        }
    }

    func approve(_ req: FSJoinRequest) async {
        guard busyId == nil else { return }
        busyId = req.id; rowErrors[req.id] = nil
        defer { busyId = nil }
        do {
            try await service.approveJoinRequest(userId: userId, groupId: groupId, requestId: req.id)
            remove(req.id)
            announcement = "\(req.displayName) was added to the group."
        } catch let e as FSJoinRequestsError where e == .notPending || e == .notFound {
            // Decided elsewhere: it is not pending any more. Not "approved".
            remove(req.id)
            announcement = "No longer available."
        } catch {
            // group_full and everything else: the row stays pending.
            rowErrors[req.id] = Self.message(error, fallback: "Couldn't approve this request.")
        }
    }

    func deny(_ req: FSJoinRequest, block: Bool) async {
        guard busyId == nil else { return }
        busyId = req.id; rowErrors[req.id] = nil
        defer { busyId = nil }
        do {
            let secs = try await service.denyJoinRequest(userId: userId, groupId: groupId,
                                                          requestId: req.id, blockReapply: block)
            remove(req.id)
            announcement = "Request denied. Undo available."
            startUndo(UndoItem(request: req, block: block), seconds: secs)
        } catch let e as FSJoinRequestsError where e == .notPending {
            remove(req.id)
        } catch {
            rowErrors[req.id] = Self.message(error, fallback: "Couldn't deny this request.")
        }
    }

    func undoDeny() async {
        guard let item = undo else { return }
        clearUndo()
        var undoFailed = false
        do {
            try await service.undoDenyJoinRequest(userId: userId, groupId: groupId, requestId: item.request.id)
            announcement = "Denial undone."
        } catch {
            undoFailed = true
        }
        await load()
        // Set after the reload so a successful refresh does not wipe the message.
        if undoFailed { listError = "That denial can no longer be undone." }
    }

    func dismissUndo() { clearUndo() }

    func setAccepting(_ next: Bool) async {
        guard !switchBusy else { return }
        let prev = accepting
        accepting = next; switchError = nil; switchBusy = true
        defer { switchBusy = false }
        do {
            try await service.setAcceptingJoinRequests(userId: userId, groupId: groupId, accepting: next)
        } catch {
            accepting = prev   // never leave the switch showing a state the server did not accept
            switchError = Self.message(error, fallback: "Couldn't update. Try again.")
        }
    }

    // MARK: helpers

    private func remove(_ id: String) {
        requests.removeAll { $0.id == id }
        pendingCount = max(0, pendingCount - 1)
    }

    private func startUndo(_ item: UndoItem, seconds: Int) {
        undoTask?.cancel()
        undo = item
        let secs = seconds > 0 ? seconds : NetworkService.joinRequestUndoFallbackSeconds
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.undo = nil }
        }
    }

    private func clearUndo() {
        undoTask?.cancel(); undoTask = nil; undo = nil
    }

    static func message(_ error: Error, fallback: String) -> String {
        if let e = error as? FSJoinRequestsError, let d = e.errorDescription { return d }
        return fallback
    }
}

struct GroupJoinRequestsSection: View {
    let context: GroupInfoSectionContext
    @StateObject private var vm: GroupJoinRequestsViewModel
    @State private var approving: FSJoinRequest?
    @State private var denyingAndBlocking: FSJoinRequest?

    init(context: GroupInfoSectionContext) {
        self.context = context
        _vm = StateObject(wrappedValue: GroupJoinRequestsViewModel(
            service: context.service, groupId: context.groupId, userId: context.userId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            header

            if vm.unavailable {
                Text("Publish this group to the Explorer to accept requests.")
                    .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let err = vm.listError {
                    HStack {
                        Text(vm.loaded && err == "Couldn't load join requests." ? "Couldn't refresh just now. Showing what we have." : err)
                            .font(.system(size: Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Retry") { Task { await vm.load() } }
                            .font(.system(size: Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityHint("Reloads join requests")
                    }
                    .padding(.horizontal, Theme.spacingSM)
                    .background(Theme.gold.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .accessibilityIdentifier("join-requests-error")
                }

                if !vm.loaded && vm.listError == nil {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.radius).fill(Color.white.opacity(0.08)).frame(height: 56)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading join requests")
                }

                if vm.loaded {
                    acceptingSwitch
                    if !vm.accepting {
                        Text("New requests are paused. Pending requests below stay open.")
                            .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if vm.requests.isEmpty {
                        Text("No requests yet.")
                            .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    } else {
                        ForEach(vm.requests) { req in row(req) }
                    }
                }

                if let item = vm.undo { undoBar(item) }
            }
        }
        .task { await vm.load() }
        .modifier(JoinRequestBadgeSync(groupId: context.groupId, loaded: vm.loaded, pendingCount: vm.pendingCount,
                                       newestRequestAt: vm.requests.compactMap(\.createdAt).max()))
        .alert("Add to group?", isPresented: Binding(get: { approving != nil }, set: { if !$0 { approving = nil } })) {
            Button("Add") { if let r = approving { Task { await vm.approve(r) } }; approving = nil }
            Button("Cancel", role: .cancel) { approving = nil }
        } message: {
            Text("Add \(approving?.displayName ?? "this person") to the group?")
        }
        .alert("Deny and block?", isPresented: Binding(get: { denyingAndBlocking != nil }, set: { if !$0 { denyingAndBlocking = nil } })) {
            Button("Deny and block", role: .destructive) {
                if let r = denyingAndBlocking { Task { await vm.deny(r, block: true) } }
                denyingAndBlocking = nil
            }
            Button("Cancel", role: .cancel) { denyingAndBlocking = nil }
        } message: {
            Text("\(denyingAndBlocking?.displayName ?? "This person") won't be able to request to join this group again.")
        }
        .accessibilityIdentifier("group-join-requests-section")
    }

    private var header: some View {
        HStack(spacing: Theme.spacingSM) {
            Text("Join requests")
                .font(.system(size: Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.gold.opacity(0.7))
                .accessibilityAddTraits(.isHeader)
            if vm.pendingCount > 0 {
                Text("\(vm.pendingCount)")
                    .font(.system(size: Theme.fontXXS, weight: .semibold)).foregroundColor(Theme.ink)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.gold).clipShape(Capsule())
                    .accessibilityLabel("\(vm.pendingCount) pending \(vm.pendingCount == 1 ? "request" : "requests")")
                    .accessibilityIdentifier("join-requests-badge")
            }
        }
    }

    private var acceptingSwitch: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { vm.accepting }, set: { v in Task { await vm.setAccepting(v) } })) {
                Text("Accepting requests").font(.system(size: Theme.fontSM)).foregroundColor(Theme.parchment)
            }
            .tint(Theme.gold)
            .disabled(vm.switchBusy)
            .frame(minHeight: 44)
            .accessibilityIdentifier("join-requests-accepting-switch")
            if let err = vm.switchError {
                Text(err).font(.system(size: Theme.fontXS)).foregroundColor(Theme.error)
                    .accessibilityIdentifier("join-requests-switch-error")
            }
        }
    }

    @ViewBuilder
    private func row(_ req: FSJoinRequest) -> some View {
        let busy = vm.busyId == req.id
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            HStack(alignment: .top, spacing: Theme.spacingSM) {
                avatar(req)
                VStack(alignment: .leading, spacing: 2) {
                    // Untrusted text: plain Text, never markdown/links.
                    Text(verbatim: req.displayName).font(.system(size: Theme.fontSM, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                    if let when = Self.dateLabel(req.createdAt) {
                        Text("Requested \(when)").font(.system(size: Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    }
                    if let note = req.note, !note.isEmpty {
                        Text(verbatim: note).font(.system(size: Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if let err = vm.rowErrors[req.id] {
                Text(err).font(.system(size: Theme.fontXS)).foregroundColor(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("join-request-row-error")
            }
            HStack(spacing: Theme.spacingSM) {
                Button("Add") { approving = req }
                    .font(.system(size: Theme.fontXS, weight: .semibold)).foregroundColor(Theme.ink)
                    .padding(.horizontal, Theme.spacingSM).frame(minHeight: 44)
                    .background(Theme.gold).clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
                    .accessibilityLabel("Approve \(req.displayName)")
                Button("Deny") { Task { await vm.deny(req, block: false) } }
                    .font(.system(size: Theme.fontXS, weight: .semibold)).foregroundColor(Theme.parchment)
                    .padding(.horizontal, Theme.spacingSM).frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSM).stroke(Theme.borderGold))
                    .accessibilityLabel("Deny \(req.displayName)")
                Menu {
                    Button("Deny and block from requesting again", role: .destructive) { denyingAndBlocking = req }
                } label: {
                    Image(systemName: "ellipsis").foregroundColor(Theme.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("More actions for \(req.displayName)")
                Spacer(minLength: 0)
            }
            .disabled(busy)
        }
        .padding(Theme.spacingSM)
        .background(Theme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityIdentifier("join-request-row")
    }

    @ViewBuilder
    private func avatar(_ req: FSJoinRequest) -> some View {
        if let s = req.profilePhotoUrl, let url = URL(string: s), url.scheme == "https" {
            AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                .frame(width: 40, height: 40).clipShape(Circle()).accessibilityHidden(true)
        } else {
            Circle().fill(Color.white.opacity(0.08)).frame(width: 40, height: 40).accessibilityHidden(true)
        }
    }

    private func undoBar(_ item: GroupJoinRequestsViewModel.UndoItem) -> some View {
        HStack {
            Text("Request denied.").font(.system(size: Theme.fontXS)).foregroundColor(Theme.parchment)
            Spacer()
            Button("Undo") { Task { await vm.undoDeny() } }
                .font(.system(size: Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("join-requests-undo")
        }
        .padding(.horizontal, Theme.spacingSM)
        .background(Theme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityElement(children: .combine)
    }

    static func dateLabel(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter()
        guard let d = f.date(from: iso) ?? g.date(from: iso) else { return nil }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    static let registration = GroupInfoExtraSection(
        id: "join_requests",
        order: 20,
        isVisible: { caps, ctx in GroupJoinRequestsViewModel.isVisible(caps, isOwner: ctx.isOwner) },
        makeView: { _, ctx in AnyView(GroupJoinRequestsSection(context: ctx)) },
        placement: .hostTools
    )
}
