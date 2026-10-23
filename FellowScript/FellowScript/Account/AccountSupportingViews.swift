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
                .font(.system(size: Theme.fontDisplayLG, weight: .heavy))
                .foregroundColor(Theme.gold)
            Text(label)
                .font(.system(size: Theme.fontXXS)).tracking(3).textCase(.uppercase)
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
        FSFormScaffold(
            title: "New Agent",
            dirty: !role.isEmpty,
            onClose: { dismiss() },
            content: {
                FSFormCard(title: "Custom role") {
                    FSField(label: "Role description", optional: true, text: $role,
                            helper: "Optionally give this agent a custom role. Leave blank to use the default spiritual guide role.",
                            accessibilityName: "Agent role description",
                            multiline: true, minLines: 4)
                }
            },
            bar: {
                FSPinnedActionBar(secondaryTitle: "Cancel", onSecondary: { dismiss() },
                                  primaryTitle: "Create", onPrimary: { onCreate(); dismiss() })
            }
        )
        // Shared keyboard-dismiss convention (task 20260831-interaction-polish-conventions).
        .dismissesKeyboardOnScrollAndTap()
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

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
        FSFormScaffold(
            title: "Timezone",
            onClose: { dismiss() },
            content: {
                FSField(label: "Search", text: $query, placeholder: "Search timezones",
                        leadingSymbol: "magnifyingglass", capitalization: .never, autocorrect: false)
                FSFormCard {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element) { idx, tz in
                            Button(action: { onPick(tz); dismiss() }) {
                                HStack(spacing: 12) {
                                    Text(tz)
                                        .font(.fsBody)
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                    ZStack {
                                        Circle().strokeBorder(tz == selected ? Theme.gold : Theme.fieldBorder, lineWidth: 2)
                                            .frame(width: 22, height: 22)
                                        if tz == selected { Circle().fill(Theme.gold).frame(width: 12, height: 12) }
                                    }
                                }
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tz == selected ? "\(tz), selected" : tz)
                            if idx < filtered.count - 1 { Divider().overlay(Theme.borderGray) }
                        }
                    }
                }
            },
            bar: {
                FSPinnedActionBar(primaryTitle: "Done", onPrimary: { dismiss() })
            }
        )
        .dismissesKeyboardOnScrollAndTap()
        .preferredColorScheme(.dark)
    }
}

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
                Text(event.prompt.isEmpty ? "Untitled devotion" : String(event.prompt.prefix(50)))
                    .font(.system(size: Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(event.scheduleSummary)
                    Text("·")
                    Text(agentName)
                }
                .font(.system(size: Theme.fontXS))
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
            .accessibilityLabel(isFiring ? "Writing devotion now" : "Write devotion now")
            .accessibilityHint("Has your AI study partner write this scheduled devotion right now and saves a note, without waiting for its schedule.")
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
        .accessibilityLabel("Scheduled devotion: \(event.prompt.isEmpty ? "Untitled devotion" : String(event.prompt.prefix(50))). Scheduled \(event.scheduleSummary).")
        .accessibilityHint("Double-tap and hold for options.")
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: "Delete", onDelete)
        .accessibilityAction(named: "Fire Now", onFire)
    }
}
