// Multi-step sheet for creating a new heartbeat event.
// Step 1: Recurrence (Daily / Weekly / Monthly)
// Step 2: Day picker (weekday pills for Weekly, 1-31 grid for Monthly; skipped for Daily)
// Step 3: Agent picker (if more than one), time, and prompt

import SwiftUI

struct EventSetupSheet: View {
    let agents:   [FSAgent]
    // Task 20260902-group-tagged-devotions: the user's own groups, sourced
    // by the caller from the existing NetworkService.fetchContacts(userId:)
    // data (no new fetch path) so the group picker below can list them.
    var groups:   [String: FSGroup] = [:]
    var existing: FSHeartbeat? = nil
    // notesPublic: task 20260903-notes-public-repurpose, step 6 -- the
    // deny-by-default edit-permission choice for every note this event
    // generates on fire, mirroring notes.public's post-repurpose meaning.
    let onSave:   (_ agentId: String, _ prompt: String, _ timestamps: [String?], _ groupId: String?, _ notesPublic: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Recurrence { case daily, weekly, monthly }
    enum SetupScreen: Hashable { case days, details }

    @State private var selectedAgentId:   String       = ""
    @State private var recurrence:        Recurrence   = .daily
    @State private var selectedWeekdays:  Set<Int>     = []
    @State private var selectedMonthDays: Set<Int>     = []
    @State private var selectedTime                    = Date()
    @State private var prompt                          = ""
    @State private var path:              [SetupScreen] = []
    // "" means no group / personal.
    @State private var selectedGroupId:   String       = ""
    // Deny-by-default (task 20260903-notes-public-repurpose, step 6): only
    // meaningful once a group is selected -- an ungrouped/personal event's
    // notes have no other group member who could edit them.
    @State private var notesPublic:       Bool         = false

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack(path: $path) {
            recurrenceScreen
                .navigationDestination(for: SetupScreen.self) { screen in
                    switch screen {
                    case .days:    dayPickerScreen
                    case .details: detailsScreen
                    }
                }
        }
        .preferredColorScheme(.dark)
        // Shared keyboard-dismiss convention (task
        // 20260831-interaction-polish-conventions) — applied at the
        // NavigationStack root so it covers detailsScreen's prompt
        // TextEditor regardless of which pushed screen is showing.
        .dismissesKeyboardOnScrollAndTap()
        .onAppear {
            if selectedAgentId.isEmpty {
                selectedAgentId = agents.first?.id ?? ""
            }
            if let hb = existing {
                prefill(from: hb)
            }
        }
    }

    // ── Pre-fill helpers ──────────────────────────────────────────────────────

    private func prefill(from hb: FSHeartbeat) {
        prompt          = hb.prompt
        selectedAgentId = hb.agent_id.isEmpty ? (agents.first?.id ?? "") : hb.agent_id
        selectedGroupId = hb.group_id ?? ""
        notesPublic     = hb.notes_public

        // Extract time: timestamps store UTC "HH:mm"; DateFormatter with UTC tz
        // returns a Date whose local representation the DatePicker will display.
        let nonNil = hb.timestamps.enumerated().compactMap { idx, ts in ts.map { (idx, $0) } }
        if let firstTime = nonNil.first?.1 {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            f.timeZone = TimeZone(identifier: "UTC")
            if let parsed = f.date(from: firstTime) { selectedTime = parsed }
        }

        let count = nonNil.count
        if count == 31 {
            recurrence = .daily
            path = [.details]
        } else {
            recurrence = .monthly
            selectedMonthDays = Set(nonNil.map { $0.0 + 1 })
            path = [.days, .details]
        }
    }

    // ── Step 1: Recurrence ────────────────────────────────────────────────────

    private var recurrenceScreen: some View {
        ScrollView {
            VStack(spacing: Theme.spacingLG) {
                Text("How often?")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                    .padding(.top, Theme.spacingXL)

                Text("Choose a schedule for this event.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLG)

                VStack(spacing: Theme.spacingMD) {
                    recurrenceCard(.daily,   icon: "sun.max",              title: "Daily",
                                   description: "Every day of the month")
                    recurrenceCard(.weekly,  icon: "calendar.badge.clock", title: "Weekly",
                                   description: "Selected days of the week")
                    recurrenceCard(.monthly, icon: "calendar",             title: "Monthly",
                                   description: "Selected days of the month")
                }
                .padding(.horizontal, Theme.spacingLG)

                Spacer(minLength: Theme.spacingXL)
            }
            .frame(maxWidth: .infinity)
        }
        // Warm-bloom-ground background (task 20260902-submenu-visual-redesign,
        // via the shared Theme.warmBloomBackground() modifier) — same
        // treatment on this and the other two steps below so the whole
        // multi-step flow reads consistently.
        .warmBloomBackground()
        .navigationTitle(isEditing ? "Edit Event" : "New Event")
        .navigationBarTitleDisplayMode(.inline)
        // Follow-up polish (task 20260902-submenu-followup-polish): ghost-
        // chip Cancel (see ChatRootView.swift's sheetGhostCancelLabel for the
        // shared recipe/rationale) plus a `.principal` title item -- this
        // screen has no trailing toolbar item at all, so the default inline
        // title was never actually centered (it centers within the
        // leading/trailing gap, and an empty trailing side still counts as
        // asymmetric against a non-empty leading Cancel).
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) { cancelGhostChip }
                    .buttonStyle(.plain)
            }
            .suppressAutomaticGlassChrome()
            ToolbarItem(placement: .principal) {
                Text(isEditing ? "Edit Event" : "New Event")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.parchment)
            }
        }
    }

    private func recurrenceCard(_ r: Recurrence, icon: String, title: String, description: String) -> some View {
        Button(action: {
            recurrence = r
            path = r == .daily ? [.details] : [.days]
        }) {
            HStack(spacing: Theme.spacingMD) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.12)).frame(width: 44, height: 44)
                    Image(systemName: icon).foregroundColor(Theme.gold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.inter(Theme.fontBody)).foregroundColor(Theme.parchment)
                    Text(description).font(.inter(Theme.fontSM)).foregroundColor(Theme.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(Theme.textMuted).font(.caption)
            }
            .padding(Theme.spacingMD)
            .background(Theme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderGold.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // ── Step 2: Day picker ────────────────────────────────────────────────────

    private var dayPickerScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingLG) {
                if recurrence == .weekly {
                    weekdayPicker
                } else {
                    monthDayPicker
                }
                Spacer(minLength: Theme.spacingXL)
            }
            .padding(Theme.spacingLG)
        }
        .warmBloomBackground()
        .navigationTitle("Select Days")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Next") { path.append(.details) }
                    .foregroundColor(Theme.gold)
                    .disabled(recurrence == .weekly ? selectedWeekdays.isEmpty : selectedMonthDays.isEmpty)
            }
        }
    }

    private var weekdayPicker: some View {
        let days: [(String, Int)] = [
            ("Mon", 2), ("Tue", 3), ("Wed", 4), ("Thu", 5),
            ("Fri", 6), ("Sat", 7), ("Sun", 1)
        ]
        return VStack(alignment: .leading, spacing: Theme.spacingMD) {
            Text("Which days of the week?")
                .font(.playfair(Theme.fontDisplayMD))
                .foregroundColor(Theme.parchment)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 10) {
                ForEach(days, id: \.1) { day in
                    let sel = selectedWeekdays.contains(day.1)
                    Button(action: {
                        if sel { selectedWeekdays.remove(day.1) } else { selectedWeekdays.insert(day.1) }
                    }) {
                        Text(day.0)
                            .font(.inter(Theme.fontSM))
                            .foregroundColor(sel ? Theme.ink : Theme.parchment.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(sel ? Theme.gold : Theme.gold.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityAddTraits(sel ? .isSelected : [])
                }
            }
        }
    }

    private var monthDayPicker: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            Text("Which days of the month?")
                .font(.playfair(Theme.fontDisplayMD))
                .foregroundColor(Theme.parchment)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 7), spacing: 8) {
                ForEach(1...31, id: \.self) { day in
                    let sel = selectedMonthDays.contains(day)
                    Button(action: {
                        if sel { selectedMonthDays.remove(day) } else { selectedMonthDays.insert(day) }
                    }) {
                        Text("\(day)")
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(sel ? Theme.ink : Theme.parchment.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(sel ? Theme.gold : Theme.gold.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .accessibilityLabel("Day \(day)")
                    .accessibilityAddTraits(sel ? .isSelected : [])
                }
            }
        }
    }

    // ── Step 3: Details (agent + time + prompt) ───────────────────────────────

    // Visual redesign (task 20260902-submenu-visual-redesign): converted from
    // native Form/Section to ScrollView/VStack + widgetCard(), matching
    // recurrenceScreen/dayPickerScreen's existing shell above in this same
    // file — this was the one screen in the flow still on Form. Same section
    // order, same headers (carried over verbatim), same group-picker Menu
    // content/behavior (untouched — that's task 20260902-group-tagged-
    // devotions' logic, only its visual container changes here).
    private var detailsScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingLG) {
                if agents.count > 1 {
                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("AGENT")
                            .font(.inter(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
                        Picker("Agent", selection: $selectedAgentId) {
                            ForEach(agents) { agent in
                                Text(agent.displayLabel).tag(agent.id)
                            }
                        }
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    }
                    .widgetCard()
                }

                // Follow-up polish (task 20260902-submenu-followup-polish,
                // item 2): Event Time and Group were two stacked full-width
                // cards, which the reporter flagged as an awkward layout --
                // combined into one row/card here. Both controls' own
                // behavior is untouched: the DatePicker binding below and
                // the group-picker Menu's content/logic (task
                // 20260902-group-tagged-devotions) are moved verbatim, just
                // re-parented into a shared HStack instead of two
                // `.widgetCard()`s. Spacing between the two halves uses the
                // existing Theme.spacingMD scale rather than an ad hoc value.
                //
                // Testing bounce fix (still 20260902-submenu-followup-polish):
                // an even 50/50 split left the GROUP half too narrow for its
                // gold Menu pill, truncating "No Group" to "No Gro...". The
                // compact hourAndMinute DatePicker only needs its own
                // intrinsic width, so EVENT TIME no longer stretches to fill
                // half the row -- it sizes to content and GROUP (still
                // `maxWidth: .infinity`) absorbs the rest of the row's width.
                HStack(alignment: .top, spacing: Theme.spacingMD) {
                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("EVENT TIME")
                            .font(.inter(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
                        DatePicker("Time", selection: $selectedTime, displayedComponents: .hourAndMinute)
                            .font(.inter(Theme.fontBody))
                            .labelsHidden()
                            .accentColor(Theme.gold)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    // Task 20260902-group-tagged-devotions: gold pill-button
                    // trigger (same visual recipe as Chat/PillButton.swift's
                    // amber-gradient pill — Theme.goldGradient + Theme.ink
                    // text on a Capsule) that drops down a submenu of the
                    // user's groups, plus a "No Group" option. Selecting a
                    // group here is what sets group_id on the heartbeat;
                    // when it fires, the note it generates inherits this
                    // group_id automatically.
                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("GROUP")
                            .font(.inter(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
                        HStack {
                            Spacer()
                            Menu {
                                Button(action: { selectedGroupId = "" }) {
                                    Label("No Group", systemImage: selectedGroupId.isEmpty ? "checkmark" : "person.crop.circle")
                                }
                                if !sortedGroups.isEmpty {
                                    Divider()
                                    ForEach(sortedGroups) { group in
                                        Button(action: { selectedGroupId = group.id }) {
                                            Label(group.title.isEmpty ? "Untitled Group" : group.title,
                                                  systemImage: selectedGroupId == group.id ? "checkmark" : "person.3")
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.3.fill").font(.system(size: 13, weight: .bold))
                                    Text(selectedGroupLabel).font(.system(size: 15, weight: .bold))
                                }
                                .foregroundColor(Theme.ink)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(Theme.goldGradient)
                                .clipShape(Capsule())
                                .topEdgeHighlight(Capsule())
                                // Testing bounce fix: hug the label's own
                                // content width (same recipe as this file's
                                // cancelGhostChip) so the pill never gets
                                // squeezed/truncated by its half of the row,
                                // regardless of group-name length.
                                .fixedSize()
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        Text("Optionally tie this event's notes to one of your groups. Leave as No Group to keep it personal.")
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .widgetCard()

                // Edit-permission control (task 20260903-notes-public-repurpose,
                // step 6): only meaningful once this event is tied to a group --
                // an ungrouped/personal event's notes have no other group
                // member who could edit them, so the control is hidden rather
                // than shown disabled, mirroring NoteEditorView's own
                // edit-permission toggle (hidden outside a group context).
                if !selectedGroupId.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        Text("EDIT PERMISSION")
                            .font(.inter(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
                        Toggle(isOn: $notesPublic) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notesPublic ? "Group Can Edit" : "Owner Only")
                                    .font(.inter(Theme.fontBody))
                                    .foregroundColor(Theme.parchment)
                                Text("Whether other members of \(selectedGroupLabel) may edit the notes this event generates.")
                                    .font(.inter(Theme.fontXS))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                        .tint(Theme.gold)
                    }
                    .widgetCard()
                }

                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    Text("PROMPT")
                        .font(.inter(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
                    Text("The agent will respond to this prompt when the event fires and save the response as a note.")
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textMuted)
                    TextEditor(text: $prompt)
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100)
                }
                .widgetCard()

                Spacer(minLength: Theme.spacingXL)
            }
            .padding(Theme.spacingLG)
        }
        .warmBloomBackground()
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        // Follow-up polish (task 20260902-submenu-followup-polish):
        // Update/Save reuses PillButton's amber-gradient recipe directly
        // (same as the other three sheets' primary actions). A `.principal`
        // title item keeps "Details" centered regardless of this now-wider
        // trailing pill's width against the automatic system back button on
        // the leading side.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Details")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.parchment)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                PillButton(title: isEditing ? "Update" : "Save") {
                    onSave(selectedAgentId,
                           prompt.trimmingCharacters(in: .whitespaces),
                           buildTimestamps(),
                           selectedGroupId.isEmpty ? nil : selectedGroupId,
                           // Fail closed: an ungrouped event can't carry a
                           // meaningful edit-permission grant regardless of
                           // whatever the (hidden) toggle's stale state is.
                           selectedGroupId.isEmpty ? false : notesPublic)
                    dismiss()
                }
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || selectedAgentId.isEmpty)
            }
            .suppressAutomaticGlassChrome()
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private var sortedGroups: [FSGroup] {
        groups.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var selectedGroupLabel: String {
        guard !selectedGroupId.isEmpty else { return "No Group" }
        let title = groups[selectedGroupId]?.title ?? ""
        return title.isEmpty ? "Group" : title
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

    private func buildTimestamps() -> [String?] {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        let timeStr = f.string(from: selectedTime)
        var ts: [String?] = Array(repeating: nil, count: 31)

        switch recurrence {
        case .daily:
            return Array(repeating: timeStr, count: 31)

        case .weekly:
            let cal = Calendar.current; let now = Date()
            var comps = DateComponents()
            comps.year  = cal.component(.year,  from: now)
            comps.month = cal.component(.month, from: now)
            comps.day   = 1
            guard let firstDay = cal.date(from: comps),
                  let range = cal.range(of: .day, in: .month, for: now) else { return ts }
            for dayNum in 1...range.count {
                if let date = cal.date(byAdding: .day, value: dayNum - 1, to: firstDay) {
                    let weekday = cal.component(.weekday, from: date)
                    if selectedWeekdays.contains(weekday) { ts[dayNum - 1] = timeStr }
                }
            }

        case .monthly:
            for day in selectedMonthDays where day >= 1 && day <= 31 {
                ts[day - 1] = timeStr
            }
        }
        return ts
    }
}
