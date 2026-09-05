// AccountView+Agents.swift — AI agents list (enable/disable, rename,
// delete via context menu, create). Split out of AccountView.swift
// (readability #6, 20260904-frontend-arch-sweep) -- same type, same
// behavior, just this section's own file. See AccountView.swift's header
// comment for the full split rationale and the list of sibling section
// files.

import SwiftUI

extension AccountView {

    var agentsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Agents")

            Text("Enabled agents participate in your chats and can summarize study sessions.")
                .font(.inter(Theme.fontSM))
                .foregroundColor(Theme.textMuted)

            if vm.agents.isEmpty {
                Divider().background(Theme.borderGoldFaint)
                Text("No agents yet. Tap + to create one.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            } else {
                // Iterate over stable values (vm.agents), not ForEach($vm.agents) —
                // an index-keyed array Binding. Deleting the last row from inside
                // this row's own .contextMenu action, while ForEach($vm.agents) still
                // holds index-derived Bindings into the (now-shrunk-or-empty) array,
                // is a well-documented SwiftUI footgun (out-of-bounds access inside
                // SwiftUI's binding/diffing machinery once the dismiss transition
                // races the mutation) — this is what crashed
                // test_eventsSection_newEventDisabled_whenNoAgents_reenabledAfterCreatingAgent.
                // Sourcing the Toggle's binding via agentEnabledBinding(id:), keyed by
                // agent.id and re-resolved against vm.agents on every get/set, removes
                // the dangling-index hazard structurally instead of just timing around it.
                ForEach(vm.agents) { agent in
                    Divider().background(Theme.borderGoldFaint)
                    HStack(spacing: Theme.spacingMD) {
                        ZStack {
                            Circle().fill(Theme.gold.opacity(0.12)).frame(width: 36, height: 36)
                            Image(systemName: "brain").foregroundColor(Theme.gold)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayLabel)
                                .font(.inter(Theme.fontBody))
                                .foregroundColor(Theme.parchment)
                            Text(agent.role.isEmpty ? "Default spiritual guide role" : String(agent.role.prefix(60)))
                                .font(.inter(Theme.fontXS))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        // Enable/disable stays inline — it's a quick at-a-glance switch.
                        // vm.toggleAgent(id:enabled:) is already id-keyed (looks the
                        // agent up by id, not index) and is the sole source of truth
                        // for the optimistic update + revert-on-failure, so the
                        // binding's setter just delegates to it directly.
                        Toggle("", isOn: agentEnabledBinding(id: agent.id))
                            .labelsHidden()
                            .tint(Theme.gold)
                            .scaleEffect(0.85)
                            .accessibilityLabel(agent.enabled ? "Disable agent" : "Enable agent")
                        // Rename / delete moved into a long-press context menu.
                        Image(systemName: "ellipsis")
                            .foregroundColor(Theme.textMuted)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(action: {
                            renameText    = agent.name.isEmpty ? agent.displayLabel : agent.name
                            renameAgentId = agent.id
                        }) { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive, action: { vm.deleteAgent(id: agent.id) }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Agent: \(agent.displayLabel). \(agent.enabled ? "Enabled" : "Disabled").")
                    .accessibilityHint("Double-tap and hold for options.")
                    .accessibilityAction(named: "Rename agent") {
                        renameText    = agent.name.isEmpty ? agent.displayLabel : agent.name
                        renameAgentId = agent.id
                    }
                    .accessibilityAction(named: "Delete agent") { vm.deleteAgent(id: agent.id) }
                }
            }

            Divider().background(Theme.borderGoldFaint)
            Button(action: { activeSheet = .newAgent }) {
                ghostLabelPill(icon: "plus", "New Agent")
            }
            .accessibilityLabel("Create new agent")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    // id-keyed Binding for an individual agent row's Toggle, re-resolved against
    // vm.agents on every get/set instead of an index captured once at ForEach
    // build time. Pairs with ForEach(vm.agents) (value iteration) in agentsSection
    // above — together they remove the dangling-array-index crash that
    // ForEach($vm.agents) had when a row's own contextMenu deleted the last agent.
    func agentEnabledBinding(id: String) -> Binding<Bool> {
        Binding(
            get: { vm.agents.first(where: { $0.id == id })?.enabled ?? false },
            set: { vm.toggleAgent(id: id, enabled: $0) }
        )
    }
}
