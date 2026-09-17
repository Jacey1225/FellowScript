// RingMembersSheet.swift
// Task 20260916-call-ring-members: the in-call member-picker sheet + multi-
// select ring action, per design-notes.md (task dir
// .claude/pipeline/20260916-call-ring-members/design-notes.md). Presented
// from ChimeCallView's new "Ring" control-bar button.
//
// Reuses the app's existing sheet chrome (NavigationStack + warmBloomBackground
// + widgetCard sections + ghost-chip Cancel/PillButton toolbar +
// [.medium, .large] detents -- the same recipe as ChatRootView's
// AddFriendSheet/AddGroupSheet) and ContactRow's AvatarView for rows, rather
// than a new generic contact-picker component (UI/UX Q12.1/Q12.3).
//
// DEPENDENCY: Theme.swift, DashboardComponents.swift (AvatarView),
// PillButton.swift, Models.swift (RingResult), MockDataService.swift
// (DataServiceProtocol), ChimeCallView.swift (CallController)

import SwiftUI

// ── A resolved, ringable roster member ──────────────────────────────────────
struct RingCandidate: Identifiable, Equatable {
    let id:   String
    let name: String
}

// ── Per-row state machine (design-notes.md §3) ──────────────────────────────
// default -> selected -> sending -> {sent | rateLimited | error}, independent
// per row, driven by that target's own entry in the ring response's
// `results` map. `rateLimited`/`error` rows are tap-to-retry (back to
// `selected`); `sending`/`sent` rows are not interactive.
enum RingRowState: Equatable {
    case `default`
    case selected
    case sending
    case sent
    case rateLimited
    case error(String)   // plain-language caption -- never the raw reason string

    var isInteractive: Bool {
        switch self {
        case .sending, .sent: return false
        default:              return true
        }
    }
}

struct RingMembersSheet: View {
    let session: FSSession
    let service: DataServiceProtocol
    let userId:  String

    @ObservedObject private var call = CallController.shared
    @Environment(\.dismiss) private var dismiss

    @State private var candidates:      [RingCandidate] = []
    @State private var isLoadingRoster  = true
    @State private var rowStates:       [String: RingRowState] = [:]
    @State private var hasAttemptedRing = false

    // Test-only hook, ViewInspector's "Approach #2" (Utils/Inspection.swift)
    // -- added for the testing gate's coverage of this sheet's per-row
    // success/error/rate-limited state machine. Proving `apply(results:to:)`
    // maps a `ringMembers` response onto the right rendered row state
    // requires observing @State after a real async gap (the `.task`-driven
    // `loadRoster()` on mount, then `sendRing()`'s own awaited network call),
    // which a plain post-host `.inspect()` can't reliably do -- mirrors
    // NoteDetailView/BlockedUsersView's identical `inspection` seam and their
    // own doc comments for why. Inert in production: `.onReceive` below is a
    // no-op unless a test registers a callback via `inspection.inspect(...)`.
    // Gated to Debug, matching Inspection.swift's own `#if DEBUG` convention.
    #if DEBUG
    internal let inspection = Inspection<Self>()
    #endif

    private var notYetJoined: [RingCandidate] {
        candidates.filter { !session.participants.contains($0.id) }
    }
    private var alreadyInCall: [RingCandidate] {
        candidates.filter { session.participants.contains($0.id) }
    }
    private var selectedIds: [String] {
        candidates.filter { rowStates[$0.id] == .selected }.map(\.id)
    }
    private var ringButtonTitle: String {
        selectedIds.isEmpty ? "Ring" : "Ring (\(selectedIds.count))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingLG) {
                    if candidates.isEmpty {
                        if !isLoadingRoster {
                            Text("No other members to ring.")
                                .font(.inter(Theme.fontSM))
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, Theme.spacingLG)
                        }
                    } else {
                        if !notYetJoined.isEmpty {
                            memberSection(title: "NOT YET JOINED", members: notYetJoined, muted: false)
                        }
                        if !alreadyInCall.isEmpty {
                            memberSection(title: "ALREADY IN CALL", members: alreadyInCall, muted: true)
                        }
                    }
                }
                .padding(Theme.spacingLG)
            }
            .warmBloomBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) { ringSheetCancelLabel }
                        .buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .principal) {
                    Text("Ring Members")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Deliberately never calls dismiss() -- ringing is an
                    // ambiguous async action with real failure/rate-limit
                    // modes (UI/UX Q10.1), so the sheet stays open to show
                    // per-member outcomes. The user closes it manually.
                    PillButton(title: ringButtonTitle, action: sendRing)
                        .disabled(selectedIds.isEmpty)
                }
                .suppressAutomaticGlassChrome()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .task { await loadRoster() }
        #if DEBUG
        .onReceive(inspection.notice) { self.inspection.visit(self, $0) }
        #endif
    }

    // ── Sections ─────────────────────────────────────────────────────────────

    @ViewBuilder
    private func memberSection(title: String, members: [RingCandidate], muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text(title)
                .font(.inter(Theme.fontXXS)).tracking(4)
                .foregroundColor(Theme.textGoldMuted)
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    RingMemberRow(
                        candidate: member,
                        state: rowStates[member.id] ?? .default,
                        muted: muted,
                        onTap: { toggle(member.id) }
                    )
                    if index < members.count - 1 {
                        Divider().opacity(0.15)
                    }
                }
            }
        }
        .widgetCard()
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func toggle(_ id: String) {
        let current = rowStates[id] ?? .default
        guard current.isInteractive else { return }
        switch current {
        case .default, .rateLimited, .error:
            rowStates[id] = .selected
        case .selected:
            rowStates[id] = .default
        case .sending, .sent:
            break
        }
    }

    // Not `private` (unlike the toolbar Cancel/Done label above), for the
    // same reason NoteDetailView's `editAction()`/`closeAction()` and
    // BlockedUsersView's `inspection` seam aren't: this sheet's "Ring"
    // control lives inside a `ToolbarItem` carrying
    // `.suppressAutomaticGlassChrome()`, and ViewInspector 0.10.3 cannot
    // traverse a `ToolbarItem` wrapped in that modifier down to its `Button`
    // by any route. Exposing this exact closure -- the same one
    // `PillButton(title: ringButtonTitle, action: sendRing)` above calls --
    // lets tests drive the real send flow (selection -> network call ->
    // per-row state) without simulating a tap through that now-unreachable
    // wrapper. No runtime behavior difference from being `private`.
    func sendRing() {
        let targets = selectedIds
        guard !targets.isEmpty else { return }
        hasAttemptedRing = true
        for id in targets { rowStates[id] = .sending }

        Task {
            do {
                let results = try await service.ringMembers(
                    userId: userId, sessionId: session.id, targetIds: targets
                )
                await MainActor.run { apply(results: results, to: targets) }
            } catch {
                await MainActor.run {
                    for id in targets { rowStates[id] = .error("Couldn't send") }
                }
            }
        }
    }

    @MainActor
    private func apply(results: [String: RingResult], to targets: [String]) {
        for id in targets {
            // A target missing from the response shouldn't happen per
            // contract, but fail safe rather than hanging in `sending`
            // forever (design-notes.md §4).
            guard let result = results[id] else {
                rowStates[id] = .error("Couldn't send")
                continue
            }
            if result.sent {
                rowStates[id] = .sent
                call.sentRingTargets.insert(id)
                continue
            }
            switch result.reason {
            case "rate_limited":
                rowStates[id] = .rateLimited
            case "unreachable":
                rowStates[id] = .error("Not reachable")
            // Task 20260916-callkit-voip-ring: distinct from "unreachable"
            // (no plain push token) -- this member has no registered VoIP
            // token, only reachable when RING_VOIP_ENABLED is on (see
            // routes/devotion.py::ring_members). Fail-loud per Security
            // Posture Q14: a real, distinguishable caption, not folded into
            // the generic "Unavailable" default below.
            case "no_voip_token":
                rowStates[id] = .error("Can't ring this device")
            case "send_failed":
                rowStates[id] = .error("Couldn't send")
            default: // "invalid_target" / "not_a_member" / nil
                rowStates[id] = .error("Unavailable")
            }
        }
    }

    // ── Roster resolution ────────────────────────────────────────────────────
    // design-notes.md §2: "reuse whatever member-list source the client
    // already has for this group ... a frontend-gate implementation detail."
    // CallController carries no cached roster of its own, so this resolves
    // ids -> display names the same way NetworkService+Contacts.fetchContacts
    // already does for friend contacts (a per-id GET /user/{id} lookup) --
    // no positional pairing of a group's raw member-id list against a
    // separately-ordered member-name list is assumed, since those two lists
    // aren't guaranteed to align once the caller is excluded from one but not
    // the other.
    @MainActor
    private func loadRoster() async {
        defer { isLoadingRoster = false }
        guard !userId.isEmpty, !session.group_id.isEmpty else { return }

        var resolved: [RingCandidate] = []
        if session.group_id.contains("|") {
            // DM room key: exactly one other member.
            let ids = session.group_id.split(separator: "|").map(String.init)
            if let otherId = ids.first(where: { $0 != userId }),
               let user = try? await service.fetchUser(userId: otherId) {
                resolved = [RingCandidate(id: otherId, name: user.username)]
            }
        } else if let (_, groupMap) = try? await service.fetchContacts(userId: userId),
                  let group = groupMap[session.group_id] {
            let memberIds = group.users.filter { $0 != userId }
            resolved = await withTaskGroup(of: RingCandidate?.self) { group in
                for id in memberIds {
                    group.addTask {
                        guard let user = try? await service.fetchUser(userId: id) else { return nil }
                        return RingCandidate(id: id, name: user.username)
                    }
                }
                var out: [RingCandidate] = []
                for await c in group { if let c { out.append(c) } }
                return out
            }
        }

        candidates = resolved
        for c in resolved where rowStates[c.id] == nil {
            // A member already rung earlier in this same call stays `sent`
            // across sheet reopenings (design-notes.md §5).
            rowStates[c.id] = call.sentRingTargets.contains(c.id) ? .sent : .default
        }
    }

    // ── Shared ghost-chip Cancel/Done label ─────────────────────────────────
    // Same visual recipe as ChatRootView's fileprivate sheetGhostCancelLabel
    // (that one isn't visible outside its own file) -- reading flips from
    // "Cancel" to "Done" once a ring attempt has been made in this sheet
    // session, since at that point there's real per-row state on screen that
    // "Cancel" would mischaracterize as discardable (design-notes.md §2).
    // Both dismiss identically; only the label changes.
    private var ringSheetCancelLabel: some View {
        Text(hasAttemptedRing ? "Done" : "Cancel")
            .font(.inter(Theme.fontSM))
            .foregroundColor(Theme.textSecondary)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Theme.parchment.opacity(0.06)))
            .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
    }
}

// ── Row ──────────────────────────────────────────────────────────────────────
struct RingMemberRow: View {
    let candidate: RingCandidate
    let state:     RingRowState
    let muted:     Bool
    let onTap:     () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nameOpacity:   Double { muted ? 0.45 : 0.70 }
    private var avatarOpacity: Double { muted ? 0.55 : 1.0 }

    var body: some View {
        HStack(spacing: 13) {
            AvatarView(
                initial:   String(candidate.name.prefix(1)).uppercased(),
                diameter:  48,
                fillColor: .clear,
                textColor: Theme.goldLight
            )
            .background(
                Circle().fill(LinearGradient(colors: [Color(hex: "#EDAB3C").opacity(0.32), Color(hex: "#B8761D").opacity(0.2)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 1))
            .opacity(avatarOpacity)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment.opacity(nameOpacity))
                if let caption {
                    Text(caption)
                        .font(.inter(Theme.fontXXS))
                        .foregroundColor(captionColor)
                }
            }
            Spacer()
            trailingControl
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: state)
        }
        .padding(.vertical, Theme.spacingSM)
        .contentShape(Rectangle())
        .onTapGesture { if state.isInteractive { onTap() } }
        .accessibilityLabel("\(candidate.name). \(accessibilityStateLabel)")
        .accessibilityAddTraits(isSelectedForAccessibility ? .isSelected : [])
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .default:
            EmptyView()
        case .selected:
            Image(systemName: "checkmark").foregroundColor(Theme.gold)
        case .sending:
            ProgressView().tint(Theme.gold)
        case .sent:
            Image(systemName: "checkmark.circle.fill").foregroundColor(Color.green.opacity(0.75))
        case .rateLimited:
            Image(systemName: "clock.badge.exclamationmark").foregroundColor(Theme.gold.opacity(0.85))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.error)
        }
    }

    private var caption: String? {
        switch state {
        case .sent:                    return "Sent"
        case .rateLimited:              return "Rate limited"
        case .error(let message):       return message
        default:                        return nil
        }
    }

    private var captionColor: Color {
        switch state {
        case .error: return Theme.error
        default:     return Theme.textSecondary
        }
    }

    private var isSelectedForAccessibility: Bool {
        switch state {
        case .selected, .sent: return true
        default:                return false
        }
    }

    private var accessibilityStateLabel: String {
        switch state {
        case .default:      return "Not selected"
        case .selected:      return "Selected"
        case .sending:       return "Sending"
        case .sent:          return "Sent"
        case .rateLimited:   return "Rate limited"
        case .error(let m):  return m
        }
    }
}
