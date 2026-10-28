// CallRingTracker.swift: caller-side ring state for the one shared call
// screen (task 20261028-dm-direct-call, step 7). Used for DM rings and group
// session rings alike; owned by CallController so it lives exactly as long as
// the call. It never decides an outcome itself: it polls
// GET /devotions/ring/status and shows what the server (the authority on the
// 45s ring timeout) reports. A failed poll keeps the last known state
// (preserve-on-failed-refresh) and never invents a result.

import SwiftUI
import Combine

@MainActor
final class CallRingTracker: ObservableObject {
    struct Target: Equatable {
        let id: String
        let name: String
        /// ringing | answered | declined | canceled | timed_out
        var status: String
    }

    enum Phase: Equatable { case ringing, declined, noAnswer }

    @Published private(set) var targets: [Target] = []

    private var sessionId = ""
    private var userId = ""
    private var service: DataServiceProtocol?
    private var pollTask: Task<Void, Never>?

    private static let pollNanos: UInt64 = 2_000_000_000
    /// Hard stop for the poll loop (server ring is 45s) so a dead status
    /// route can never keep polling for the whole call.
    private static let maxPollSeconds = 120.0

    /// What the banner should show, or nil (nothing rung, or someone answered).
    var phase: Phase? {
        guard !targets.isEmpty, !targets.contains(where: { $0.status == "answered" }) else { return nil }
        if targets.contains(where: { $0.status == "ringing" }) { return .ringing }
        return targets.allSatisfy({ $0.status == "declined" }) ? .declined : .noAnswer
    }

    var bannerText: String? {
        guard let phase else { return nil }
        let pending = targets.filter { $0.status == "ringing" }
        let single = targets.count == 1 ? targets[0].name : nil
        switch phase {
        case .ringing:
            if pending.count == 1 { return "Ringing \(pending[0].name)..." }
            return "Ringing \(pending.count) people..."
        case .declined:
            return single.map { "\($0) declined." } ?? "No one joined. They declined."
        case .noAnswer:
            return single.map { "\($0) didn't answer." } ?? "No one answered."
        }
    }

    /// Starts (or extends) tracking for targets that were just rung.
    func begin(sessionId: String, targets newTargets: [(id: String, name: String)],
               service: DataServiceProtocol?, userId: String) {
        guard !newTargets.isEmpty, !userId.isEmpty else { return }
        if self.sessionId != sessionId { targets = [] }
        self.sessionId = sessionId
        self.service = service
        self.userId = userId
        for t in newTargets {
            let fresh = Target(id: t.id, name: t.name, status: "ringing")
            if let i = targets.firstIndex(where: { $0.id == t.id }) { targets[i] = fresh } else { targets.append(fresh) }
        }
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var waited = 0.0
            while !Task.isCancelled, waited < Self.maxPollSeconds {
                try? await Task.sleep(nanoseconds: Self.pollNanos)
                if Task.isCancelled { return }
                waited += Double(Self.pollNanos) / 1_000_000_000
                guard let self else { return }
                if await self.pollOnce() == false { return }
            }
        }
    }

    /// Returns false once nothing is ringing any more (stop polling).
    private func pollOnce() async -> Bool {
        guard let ringService = service as? RingLifecycleServiceProtocol else { return false }
        do {
            let rings = try await ringService.fetchRingStatus(devotionId: sessionId, userId: userId)
            for i in targets.indices {
                if let entry = rings[targets[i].id] { targets[i].status = entry.status }
            }
        } catch {
            // Keep the last known state; try again next tick.
        }
        return targets.contains(where: { $0.status == "ringing" })
    }

    /// Rings the people who declined or did not answer once more, through the
    /// same ring route (server cooldown still applies).
    func ringAgain() {
        guard let service, !userId.isEmpty else { return }
        let retry = targets.filter { $0.status != "ringing" && $0.status != "answered" }
        guard !retry.isEmpty else { return }
        let sid = sessionId, uid = userId
        Task { @MainActor in
            let notice = "They weren't alerted. Try ringing again in a few minutes."
            do {
                let results = try await service.ringMembers(userId: uid, sessionId: sid, targetIds: retry.map(\.id))
                let sent = retry.filter { results[$0.id]?.sent == true }
                if sent.isEmpty { CallController.shared.showRingDeliveryNotice(notice) }
                else {
                    for t in sent { CallController.shared.sentRingTargets.insert(t.id) }
                    begin(sessionId: sid, targets: sent.map { ($0.id, $0.name) }, service: service, userId: uid)
                }
            } catch {
                CallController.shared.showRingDeliveryNotice(notice)
            }
        }
    }

    /// Caller hung up (or left) while rings are still out: tell the server so
    /// the other device's CallKit UI is dismissed. Best effort, never blocks
    /// ending the call. Also clears all state.
    func cancelOutstandingAndReset() {
        if let ringService = service as? RingLifecycleServiceProtocol, !userId.isEmpty {
            let sid = sessionId, uid = userId
            for t in targets where t.status == "ringing" {
                Task {
                    try? await ringService.respondToRing(devotionId: sid, userId: uid, targetId: t.id, outcome: .canceled)
                }
            }
        }
        pollTask?.cancel(); pollTask = nil
        targets = []; sessionId = ""; userId = ""; service = nil
    }
}

/// Slim status banner shown at the top of the call screen (below the call
/// header). One banner for both DM and group rings.
struct OutgoingRingBanner: View {
    @ObservedObject var tracker: CallRingTracker
    let onLeave: () -> Void

    var body: some View {
        if let phase = tracker.phase, let text = tracker.bannerText {
            VStack(spacing: Theme.spacingXS) {
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: phase == .ringing ? "phone.arrow.up.right" : "phone.down")
                        .foregroundColor(Theme.gold)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                }
                if phase != .ringing {
                    HStack(spacing: Theme.spacingSM) {
                        Button("Call again") { tracker.ringAgain() }
                            .font(.inter(Theme.fontSM))
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, Theme.spacingMD)
                            .frame(minHeight: 44)
                        Button("Leave", action: onLeave)
                            .font(.inter(Theme.fontSM))
                            .foregroundColor(Theme.gold)
                            .padding(.horizontal, Theme.spacingMD)
                            .frame(minHeight: 44)
                            .overlay(Capsule().stroke(Theme.gold, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, Theme.spacingSM)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderGoldFaint, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.updatesFrequently)
            .onChange(of: phase) { _, new in
                if let t = tracker.bannerText, new != .ringing { AccessibilityNotification.Announcement(t).post() }
            }
            .onAppear { AccessibilityNotification.Announcement(text).post() }
        }
    }
}
