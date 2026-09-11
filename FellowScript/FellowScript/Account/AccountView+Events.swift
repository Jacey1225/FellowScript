// AccountView+Events.swift — AI-agent events (scheduled check-ins): list,
// manual "execute now" trigger, create/edit sheet entry point. Split out of
// AccountView.swift (readability #6, 20260904-frontend-arch-sweep) -- same
// type, same behavior, just this section's own file. See AccountView.swift's
// header comment for the full split rationale and the list of sibling
// section files.

import SwiftUI

extension AccountView {

    var eventsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Events")

            Text("Events are AI-powered check-ins. When the scheduled time arrives, your agent responds to the prompt and saves a note.")
                .font(.inter(Theme.fontSM))
                .foregroundColor(Theme.textMuted)

            // Manual "execute now" confirmation (task
            // 20260901-heartbeat-manual-trigger-button) — mirrors
            // editProfileSection's editMsg banner pattern. Free-tier-cap and
            // genuine-failure outcomes go through the existing limitMsg/
            // agentMsg alerts below instead of this banner.
            if let msg = vm.eventFireMsg {
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: msg.type == .success ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                    Text(msg.text)
                        .font(.inter(Theme.fontSM))
                }
                .foregroundColor(msg.type == .success ? Theme.success : Theme.gold)
                .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                .background((msg.type == .success ? Theme.success : Theme.gold).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }

            // Loading-vs-genuinely-empty distinction (task
            // 20260910-account-events-refresh-regression, re-entry after the
            // build-42 fetchAgents fix -- real and worth keeping, but not
            // the actual root cause of the reported symptom). Direct
            // evidence gathered this pass: production logs show real,
            // recent client requests to GET /agent/{user_id} and GET
            // /agent/{user_id}/{agent_id}/heartbeats succeeding with clean,
            // decodable data -- the fetch path itself is not broken. But
            // AccountViewModel.load() is a single all-or-nothing round: it
            // commits NOTHING (not `agents`, not `events`) to @Published
            // state until every one of its 7 concurrent fetches AND the
            // full per-agent heartbeats TaskGroup has resolved (the
            // `generation` guard gates one single commit point at the very
            // end -- see AccountViewModel.swift's `load()`). AccountView's
            // own `.task`/`.refreshable` deliberately don't gate this
            // screen's body on `vm.isLoading` (so a refresh never blanks
            // already-shown content -- see refreshAccountData()'s doc
            // comment), which is the right call for already-populated
            // data, but it left this specific empty-state branch unable to
            // tell "still fetching, nothing committed yet" apart from
            // "fetch finished, this account genuinely has zero events" --
            // both render this exact same "No events yet" text. A user who
            // checks (or force-quits) before that round finishes -- e.g.
            // testing rapidly, re-triggering a refresh before the previous
            // one lands -- sees the confirmed-empty copy every single time,
            // even though the round is actually still in flight and (per
            // the production logs) does eventually succeed. Distinguishing
            // the two states here doesn't change when data actually
            // commits (that's AccountViewModel.load()'s own concern, not
            // this view's), it only stops the view from asserting "you
            // have no events" while that's not actually known yet.
            if vm.events.isEmpty && vm.isLoading {
                Divider().background(Theme.borderGoldFaint)
                HStack(spacing: Theme.spacingSM) {
                    ProgressView().tint(Theme.gold)
                    Text("Loading your events…")
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textMuted)
                }
            } else if vm.events.isEmpty {
                Divider().background(Theme.borderGoldFaint)
                Text("No events yet. Tap + to schedule one.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(vm.events) { event in
                    Divider().background(Theme.borderGoldFaint)
                    EventRow(
                        event:     event,
                        agentName: agentName(for: event.agent_id),
                        isFiring:  vm.firingHeartbeatIds.contains(event.id),
                        onEdit:    { activeSheet = .editEvent(event) },
                        onDelete:  { vm.removeEvent(event) },
                        onFire:    { Task { await vm.fireHeartbeatNow(event) } }
                    )
                }
            }

            Divider().background(Theme.borderGoldFaint)
            Button(action: {
                guard !vm.agents.isEmpty else { return }
                appState.requestPushNotifications()
                activeSheet = .newEvent
            }) {
                ghostLabelPill(icon: "plus", "New Event", color: vm.agents.isEmpty ? Theme.textMuted : Theme.gold)
            }
            .disabled(vm.agents.isEmpty)
            .accessibilityLabel("Create new event")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    func agentName(for agentId: String) -> String {
        vm.agents.first(where: { $0.id == agentId })?.displayLabel ?? "Agent"
    }
}
