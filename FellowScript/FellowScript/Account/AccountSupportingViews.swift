// AccountSupportingViews.swift — small, already-independent view structs
// AccountView.swift used to also define: StatBox (the Overview stat tile),
// NewAgentSheet, TimeZonePickerSheet, and EventRow. Split out (readability
// #6, 20260904-frontend-arch-sweep) -- same types, same behavior, no
// interface change. See AccountView.swift's header comment for the full
// split rationale and the list of sibling section files.

import SwiftUI

// ── Stat box ──────────────────────────────────────────────────────────────────
struct StatBox: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.playfair(Theme.fontDisplayLG))
                .foregroundColor(Theme.gold)
            Text(label)
                .font(.inter(Theme.fontXXS)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingSM)
        .accessibilityLabel("\(value) \(label)")
    }
}

// ── New agent sheet ───────────────────────────────────────────────────────────
// Visual redesign (task 20260902-submenu-visual-redesign): moved off native
// Form/Section onto the shared warm-bloom-ground background + widgetCard()
// layout; the "CUSTOM ROLE (OPTIONAL)" header keeps its already-correct
// styling, just moved out of Form's header: closure into a plain Text above
// the card. .medium detent and callback wiring unchanged.
struct NewAgentSheet: View {
    @Binding var role: String
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    Text("CUSTOM ROLE (OPTIONAL)")
                        .font(.inter(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)

                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("Optionally give this agent a custom role. Leave blank to use the default spiritual guide role.")
                            .font(.inter(Theme.fontSM))
                            .foregroundColor(Theme.textSecondary)
                        TextEditor(text: $role)
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80)
                            .accessibilityLabel("Agent role description")
                    }
                    .widgetCard()
                }
                .padding(Theme.spacingLG)
            }
            .warmBloomBackground()
            // Shared keyboard-dismiss convention (task
            // 20260831-interaction-polish-conventions).
            .dismissesKeyboardOnScrollAndTap()
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            // Follow-up polish (task 20260902-submenu-followup-polish): same
            // ghost-chip-Cancel / PillButton-Create / centered-`.principal`-
            // title treatment as ChatRootView's AddFriendSheet/AddGroupSheet
            // -- see AddFriendSheet's toolbar comment for the full rationale.
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) { cancelGhostChip }
                        .buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .principal) {
                    Text("New Agent")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    PillButton(title: "Create") { onCreate(); dismiss() }
                }
                .suppressAutomaticGlassChrome()
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    // Ghost-chip Cancel label (see ChatRootView.swift's sheetGhostCancelLabel
    // for the shared recipe/rationale comment -- bespoke per-sheet copy here
    // rather than a new cross-file shared component per this task's spec).
    private var cancelGhostChip: some View {
        Text("Cancel")
            .font(.inter(Theme.fontSM))
            .foregroundColor(Theme.textSecondary)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Theme.parchment.opacity(0.06)))
            .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
    }
}

// ── Timezone picker sheet ───────────────────────────────────────────────────
// Full IANA timezone list via Foundation (mirrors the web Account page's use
// of Intl.supportedValuesOf('timeZone')); searchable since there are 400+.
struct TimeZonePickerSheet: View {
    let selected: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var allZones: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }
    private var filtered: [String] {
        guard !query.isEmpty else { return allZones }
        return allZones.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { tz in
                Button(action: { onPick(tz); dismiss() }) {
                    HStack {
                        Text(tz)
                            .font(.inter(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                        Spacer()
                        if tz == selected {
                            Image(systemName: "checkmark").foregroundColor(Theme.gold)
                        }
                    }
                }
                .listRowBackground(Theme.cardBg)
                .accessibilityLabel(tz == selected ? "\(tz), selected" : tz)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .searchable(text: $query, prompt: "Search timezones")
            .navigationTitle("Timezone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ── Event row (shown in Events section) ───────────────────────────────────────
struct EventRow: View {
    let event:     FSHeartbeat
    let agentName: String
    // Manual "execute now" trigger (task 20260901-heartbeat-manual-trigger-button).
    let isFiring:  Bool
    let onEdit:    () -> Void
    let onDelete:  () -> Void
    let onFire:    () -> Void

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.12)).frame(width: 30, height: 30)
                Image(systemName: "bolt.fill").foregroundColor(Theme.gold).font(.caption)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.prompt.isEmpty ? "Untitled Event" : String(event.prompt.prefix(50)))
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(event.scheduleSummary)
                    Text("·")
                    Text(agentName)
                }
                .font(.inter(Theme.fontXS))
                .foregroundColor(Theme.textMuted)
            }
            Spacer()
            // Always-visible "execute now": unlike Edit/Delete (which stay in
            // the long-press context menu below), this fires immediately on
            // tap rather than needing that menu discovered first. A separate
            // glyph from the row's own bolt.fill identity icon above avoids
            // visually implying the row icon itself is tappable.
            Button(action: onFire) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.16)).frame(width: 28, height: 28)
                    if isFiring {
                        ProgressView().tint(Theme.gold).scaleEffect(0.7)
                    } else {
                        Image(systemName: "play.fill").foregroundColor(Theme.gold).font(.caption2)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isFiring)
            .accessibilityLabel(isFiring ? "Firing event now" : "Fire event now")
            .accessibilityHint("Immediately runs this event's agent and saves a note, without waiting for its schedule.")
            // Discoverability hint: signals a long-press context menu is available.
            Image(systemName: "ellipsis")
                .foregroundColor(Theme.textMuted)
                .font(.caption)
                .accessibilityHidden(true)
        }
        // Whole row is the long-press target (Spacer included).
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Event: \(event.prompt.isEmpty ? "Untitled Event" : String(event.prompt.prefix(50))). Scheduled \(event.scheduleSummary).")
        .accessibilityHint("Double-tap and hold for options.")
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: "Delete", onDelete)
        .accessibilityAction(named: "Fire Now", onFire)
    }
}
