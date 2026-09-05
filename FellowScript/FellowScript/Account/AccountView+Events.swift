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

            if vm.events.isEmpty {
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
