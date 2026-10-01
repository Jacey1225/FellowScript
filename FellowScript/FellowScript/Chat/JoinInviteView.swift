// JoinInviteView.swift — join-by-link confirmation (task
// 20260929-group-invite-links, design-notes.md B). Presented full-screen by
// ContentView while AppState.pendingInviteToken is set. Preview is public, so
// the group and inviter show signed out; joining needs a session.
//
// The pending invite is only cleared on a terminal outcome (success,
// 404/410/409/403, Cancel). It survives 429/5xx/network so "Try again" works,
// and a signed-out user's token rides through sign-in/sign-up in the Keychain.

import SwiftUI
import Combine

/// Why a preview/redeem failed, with the exact copy from design-notes.md.
enum InviteFailure: Equatable {
    case invalid, expired, revoked, full, groupFull, blocked, rateLimited, network
    /// Subscription links only: the caller is already on a different paid plan.
    case otherPlan

    init(_ error: InviteAPIError) {
        switch error.status {
        case 0, 500...599: self = .network
        case 429:          self = .rateLimited
        case 404:          self = .invalid
        case 410:          self = error.code == "revoked" ? .revoked : .expired
        case 409:
            switch error.code {
            case "other_plan": self = .otherPlan
            case "group_full": self = .groupFull
            default:           self = .full
            }
        case 403:          self = .blocked
        default:           self = .network
        }
    }

    var title: String {
        switch self {
        case .invalid:     return "This invite link isn't valid anymore"
        case .expired:     return "This invite link has expired."
        case .revoked:     return "This invite link was revoked."
        case .full:        return "This invite link has reached its limit."
        case .groupFull:   return "This group is full."
        case .blocked:     return "You can't join this group."
        case .rateLimited: return "Too many tries."
        case .network:     return "Couldn't reach FellowScript."
        case .otherPlan:   return "You're already on a paid plan."
        }
    }

    /// Title for a subscription link: only the blocked copy differs.
    func title(subscription: Bool) -> String {
        subscription && self == .blocked ? "You can't request to join this plan." : title
    }

    /// nil for `.blocked`: no reason, no names, no ask-for-a-new-link hint.
    var body: String? {
        switch self {
        case .invalid:     return "It may have expired, been revoked, or reached its limit. Ask the person who invited you for a new link."
        case .expired, .revoked, .full: return "Ask the person who invited you for a new link."
        case .blocked:     return nil
        case .rateLimited: return "Wait a minute and try again."
        case .network:     return "Check your connection and try again."
        case .groupFull:   return "Ask the group owner to make room, then open the link again."
        case .otherPlan:   return "Leave your current plan first, then open this link again to request a seat."
        }
    }

    var isRetryable: Bool { self == .rateLimited || self == .network }
}

@MainActor
final class JoinInviteViewModel: ObservableObject {
    enum Phase: Equatable { case resolving, ready, joining, joined, failed(InviteFailure) }

    @Published var phase: Phase = .resolving
    @Published var preview: FSInvitePreview?
    /// Subscription links: what the redeem did (a request was filed, or the
    /// caller is already on the plan). Never membership.
    @Published var requestOutcome: RequestOutcome?
    enum RequestOutcome: Equatable { case requested, alreadyMember }

    private let service: DataServiceProtocol
    let token: String
    private var lastAction: Action = .preview
    private enum Action { case preview, redeem }

    init(service: DataServiceProtocol, token: String) {
        self.service = service
        self.token = token
    }

    /// Terminal failures drop the pending invite (via `onTerminal`); retryable
    /// ones keep it.
    var onTerminal: (() -> Void)?

    func loadPreview() async {
        lastAction = .preview
        phase = .resolving
        do {
            preview = try await service.previewInvite(token: token)
            phase = .ready
        } catch let e as InviteAPIError {
            fail(InviteFailure(e))
        } catch {
            fail(.network)
        }
    }

    /// Returns the redeem result on success (already-member is a success).
    func join(userId: String) async -> (result: FSInviteRedeemResult, sessionExpired: Bool)? {
        guard phase != .joining else { return nil }
        lastAction = .redeem
        phase = .joining
        do {
            let result = try await service.redeemInvite(userId: userId, token: token)
            if result.kind == "subscription" {
                requestOutcome = result.already_member ? .alreadyMember : .requested
            }
            phase = .joined
            return (result, false)
        } catch let e as InviteAPIError {
            if e.status == 401 { phase = .ready; return (FSInviteRedeemResult(kind: "", target_id: "", joined: false, already_member: false), true) }
            fail(InviteFailure(e))
        } catch {
            fail(.network)
        }
        return nil
    }

    func retryAction() -> Bool { lastAction == .redeem }

    private func fail(_ failure: InviteFailure) {
        if !failure.isRetryable { onTerminal?() }
        phase = .failed(failure)
    }
}

/// Parameterless so ContentView can present it; the per-token state lives in
/// `JoinInviteContent`, keyed by token so a newer link resets the screen.
struct JoinInviteView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let token = appState.pendingInviteToken {
                JoinInviteContent(token: token, service: appState.service)
                    .id(token)
            } else {
                Color.clear
            }
        }
        .warmBloomBackground()
        .preferredColorScheme(.dark)
    }
}

private struct JoinInviteContent: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var vm: JoinInviteViewModel
    @AccessibilityFocusState private var headingFocused: Bool

    init(token: String, service: DataServiceProtocol) {
        _vm = StateObject(wrappedValue: JoinInviteViewModel(service: service, token: token))
    }

    var body: some View {
        VStack(spacing: Theme.spacingMD) {
            Spacer(minLength: 0)
            content
                .frame(maxWidth: 420)
                .transition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacingMD)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motionAwareAnimation(.easeOut(duration: 0.2), value: vm.phase, reduceMotion: reduceMotion)
        .task {
            vm.onTerminal = { appState.clearPendingInvite() }
            await vm.loadPreview()
        }
        .onChange(of: vm.phase) { _, phase in
            switch phase {
            case .ready, .failed, .joined:
                headingFocused = true
            default: break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .resolving:
            VStack(spacing: Theme.spacingSM) {
                ProgressView().tint(Theme.gold)
                Text("Checking this invite...").font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .ready, .joining:
            readyBody
        case .joined:
            if vm.requestOutcome != nil {
                requestSentBody
            } else {
                VStack(spacing: Theme.spacingSM) {
                    Text("You're in")
                        .font(.playfair(Theme.fontDisplayMD)).foregroundColor(Theme.parchment)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headingFocused)
                }
            }
        case .failed(let failure):
            errorBody(failure)
        }
    }

    /// Subscription link: a request was filed; the plan owner still has to accept.
    private var requestSentBody: some View {
        let owner = vm.preview?.inviter_username ?? ""
        let already = vm.requestOutcome == .alreadyMember
        return VStack(spacing: Theme.spacingMD) {
            Text(already ? "You're already on this plan" : "Request sent")
                .font(.playfair(Theme.fontDisplayMD)).foregroundColor(Theme.parchment)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(already
                 ? "You already have access through this plan."
                 : "\(owner.isEmpty ? "The plan owner" : owner) has to approve your request. You get access to the plan once they accept it.")
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            wideButton("Done", busy: false) { appState.clearPendingInvite() }
        }
        .accessibilityElement(children: .contain)
    }

    /// Request-to-join confirmation for a subscription link.
    private var subscriptionReadyBody: some View {
        let owner = vm.preview?.inviter_username ?? ""
        return VStack(spacing: Theme.spacingMD) {
            Text("Request to join \(owner)'s plan")
                .font(.playfair(Theme.fontDisplayMD)).foregroundColor(Theme.parchment)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text("\(owner) invited you to their FellowScript plan. They approve each request before you get access.")
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if appState.isAuthenticated {
                wideButton(vm.phase == .joining ? nil : "Request to join", busy: vm.phase == .joining) { Task { await join() } }
                textButton("Cancel") { appState.clearPendingInvite() }
                    .disabled(vm.phase == .joining)
            } else {
                wideButton("Sign in to request", busy: false) { appState.inviteDeferredForAuth = true }
                textButton("Create an account") { appState.inviteDeferredForAuth = true }
                textButton("Cancel") { appState.clearPendingInvite() }
            }
        }
    }

    private var readyBody: some View {
        if vm.preview?.isSubscription == true { return AnyView(subscriptionReadyBody) }
        return AnyView(groupReadyBody)
    }

    private var groupReadyBody: some View {
        VStack(spacing: Theme.spacingMD) {
            AvatarView(
                initial: String((vm.preview?.group_name ?? "?").prefix(1)).uppercased(),
                photoURL: vm.preview?.photo_url,
                diameter: 96,
                fillColor: Theme.gold.opacity(0.12),
                textColor: Theme.gold
            )
            .accessibilityHidden(true)
            Text(vm.preview?.group_name ?? "")
                .font(.playfair(Theme.fontDisplayMD)).foregroundColor(Theme.parchment)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            VStack(spacing: 2) {
                Text("Invited by \(vm.preview?.inviter_username ?? "")")
                let n = vm.preview?.member_count ?? 0
                Text("\(n) \(n == 1 ? "member" : "members")")
            }
            .font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
            .accessibilityElement(children: .combine)

            if appState.isAuthenticated {
                wideButton(vm.phase == .joining ? nil : "Join group", busy: vm.phase == .joining) { Task { await join() } }
                textButton("Cancel") { appState.clearPendingInvite() }
                    .disabled(vm.phase == .joining)
            } else {
                wideButton("Sign in to join", busy: false) { appState.inviteDeferredForAuth = true }
                textButton("Create an account") { appState.inviteDeferredForAuth = true }
                textButton("Cancel") { appState.clearPendingInvite() }
            }
        }
    }

    private func errorBody(_ failure: InviteFailure) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Text(failure.title(subscription: vm.preview?.isSubscription == true))
                .font(.playfair(Theme.fontDisplayMD)).foregroundColor(Theme.parchment)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            if let body = failure.body {
                Text(body).font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if failure.isRetryable {
                wideButton("Try again", busy: false) { Task { await retry() } }
                textButton("Back to FellowScript") { appState.clearPendingInvite() }
            } else {
                wideButton("Back to FellowScript", busy: false) { appState.clearPendingInvite() }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func join() async {
        guard let uid = appState.currentUser?.user_id else { return }
        guard let outcome = await vm.join(userId: uid) else { return }
        if outcome.sessionExpired {
            // Session is gone: keep the pending invite and go sign in again.
            let token = vm.token
            appState.signOut()
            appState.setPendingInvite(token)
            appState.inviteDeferredForAuth = true
            return
        }
        if vm.requestOutcome != nil {
            // A request, not membership: keep the confirmation on screen (its
            // Done button clears the pending invite) and drop the stored token
            // so a relaunch doesn't re-present it.
            PendingInviteStore.clear()
            return
        }
        let groupId = outcome.result.target_id
        let name = vm.preview?.group_name ?? ""
        // "joined" flashes "You're in" briefly; an already-member goes straight in.
        if outcome.result.joined && !reduceMotion {
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        appState.clearPendingInvite()
        appState.openJoinedGroup(groupId: groupId, name: name)
    }

    private func retry() async {
        if vm.retryAction() { await join() } else { await vm.loadPreview() }
    }

    // ── Controls (>= 44pt) ──────────────────────────────────────────────────
    private func wideButton(_ title: String?, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(Theme.ink) }
                else { Text(title ?? "").font(.system(size: 16, weight: .bold)) }
            }
            .foregroundColor(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.goldGradient)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(busy ? "Joining" : (title ?? ""))
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                .frame(minWidth: 88, minHeight: 44)
        }
    }
}
