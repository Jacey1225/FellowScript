// Scheduled devotion form (TA1, Forms kit): FSFormScaffold with the
// WHO & WHEN / PROMPT / REPEAT stepper rail and a pinned Back / Next / Save bar.
// Task 20261105-onboarding-redo: visual/structure change only. The save
// contract (onSave arguments, idempotency key, timestamps, group and
// notesPublic rules) is unchanged. Recurrence keeps Daily / Weekly / Monthly
// with the existing day pickers, now inline in the REPEAT step.
//
// Onboarding hooks: reports sheet-opened and step-reached signals to
// OnboardingEngine (no-ops outside a walkthrough), shows the coach card, and
// can prefill a starter prompt.

import SwiftUI

struct EventSetupSheet: View {
    let agents:   [FSAgent]
    // Task 20260902-group-tagged-devotions: the user's own groups, sourced by the
    // caller from the existing NetworkService.fetchContacts(userId:) data.
    var groups:   [String: FSGroup] = [:]
    var existing: FSHeartbeat? = nil
    /// Prefilled prompt for a new devotion (onboarding starter). Ignored when editing.
    var starterPrompt: String? = nil
    // notesPublic: deny-by-default edit-permission choice for notes this event generates.
    // idempotencyKey: a fresh UUID per Save tap, threaded to the server so a
    // double-submit is deduped (task 20260905-heartbeat-timezone-duplicate-bugs).
    let onSave:   (_ agentId: String, _ prompt: String, _ timestamps: [String?], _ groupId: String?, _ notesPublic: Bool, _ idempotencyKey: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var onboarding = OnboardingEngine.shared

    // In-flight guard: complements the server-side idempotency_key + UNIQUE index.
    @State private var isSaving = false

    enum Recurrence: Hashable { case daily, weekly, monthly }

    @State private var step = 0
    @State private var selectedAgentId:   String       = ""
    @State private var recurrence:        Recurrence   = .daily
    @State private var selectedWeekdays:  Set<Int>     = []
    @State private var selectedMonthDays: Set<Int>     = []
    @State private var selectedTime                    = Date()
    @State private var prompt                          = ""
    @State private var promptError:       String?      = nil
    @State private var daysError:         String?      = nil
    // "" means no group / personal.
    @State private var selectedGroupId:   String       = ""
    // Deny-by-default: only meaningful once a group is selected.
    @State private var notesPublic:       Bool         = false
    @State private var seeded = false

    private static let steps = ["Who & when", "Prompt", "Repeat"]
    private var isEditing: Bool { existing != nil }
    private var lastStep: Bool { step == Self.steps.count - 1 }
    private var promptTrimmed: String { prompt.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        FSFormScaffold(
            title: isEditing ? "Edit scheduled devotion" : "New scheduled devotion",
            dirty: !isSaving && (!promptTrimmed.isEmpty && existing == nil || step > 0),
            rail: AnyView(FSStepperRail(steps: Self.steps, current: step,
                                        maxReachable: isEditing ? Self.steps.count - 1 : step,
                                        onSelect: { goTo($0) })),
            onClose: { dismiss() },
            content: {
                switch step {
                case 0:  whoAndWhenCards
                case 1:  promptCard
                default: repeatCards
                }
            },
            bar: {
                FSPinnedActionBar(
                    secondaryTitle: step == 0 ? "Cancel" : "Back",
                    onSecondary: { if step == 0 { dismiss() } else { goTo(step - 1) } },
                    primaryTitle: lastStep ? (isEditing ? "Update" : "Save") : "Next",
                    primaryDimmed: primaryDimmed,
                    saving: isSaving,
                    onPrimary: primaryTapped
                )
            }
        )
        .preferredColorScheme(.dark)
        .dismissesKeyboardOnScrollAndTap()
        .onboardingCoach(surfaces: [.devotionSheet])
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if selectedAgentId.isEmpty { selectedAgentId = agents.first?.id ?? "" }
            if let hb = existing { prefill(from: hb) }
            else if prompt.isEmpty, let starterPrompt { prompt = starterPrompt }
            if !isEditing { onboarding.report(.devotionSheetOpened) }
        }
        .onDisappear { onboarding.surfaceDismissed(.devotionSheet) }
    }

    // ── Pre-fill helpers ──────────────────────────────────────────────────────

    private func prefill(from hb: FSHeartbeat) {
        prompt          = hb.prompt
        selectedAgentId = hb.agent_id.isEmpty ? (agents.first?.id ?? "") : hb.agent_id
        selectedGroupId = hb.group_id ?? ""
        notesPublic     = hb.notes_public

        // Extract time: timestamps store literal local wall-clock "HH:mm" in
        // the owning user's timezone (task
        // 20260905-heartbeat-timezone-duplicate-bugs, Bug 1 -- matches the
        // backend's scheduler.py/agent.py interpretation since the
        // 20260901-heartbeat-backend-scheduling revision; this screen
        // previously double-converted through a hardcoded UTC timezone,
        // which is what caused a 9:00 AM pick to fire hours off). Parse with
        // the device's own local timezone so the digits round-trip back to
        // the DatePicker unchanged.
        let nonNil = hb.timestamps.enumerated().compactMap { idx, ts in ts.map { (idx, $0) } }
        if let firstTime = nonNil.first?.1 {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            f.timeZone = TimeZone.current
            if let parsed = f.date(from: firstTime) { selectedTime = parsed }
        }

        let count = nonNil.count
        if count == 31 {
            recurrence = .daily
        } else {
            recurrence = .monthly
            selectedMonthDays = Set(nonNil.map { $0.0 + 1 })
        }
    }

    // ── Navigation ────────────────────────────────────────────────────────────

    private var primaryDimmed: Bool {
        if isSaving { return true }
        switch step {
        case 0:  return selectedAgentId.isEmpty
        case 1:  return promptTrimmed.isEmpty
        default: return needsDays || promptTrimmed.isEmpty || selectedAgentId.isEmpty
        }
    }

    private var needsDays: Bool {
        (recurrence == .weekly && selectedWeekdays.isEmpty) || (recurrence == .monthly && selectedMonthDays.isEmpty)
    }

    /// Dimmed stays tappable: the tap runs validation and shows why (spec D8).
    private func primaryTapped() {
        guard !isSaving else { return }
        switch step {
        case 0:
            if !selectedAgentId.isEmpty { goTo(1) }
        case 1:
            if promptTrimmed.isEmpty { promptError = "Add a prompt so your study partner knows what to write." }
            else { goTo(2) }
        default:
            // Edit mode can reach this step via the rail with an earlier step now invalid:
            // never save an empty prompt or a missing agent.
            if selectedAgentId.isEmpty { goTo(0) }
            else if promptTrimmed.isEmpty { promptError = "Add a prompt so your study partner knows what to write."; goTo(1) }
            else if needsDays { daysError = "Choose at least one day." }
            else { saveDevotion() }
        }
    }

    private func goTo(_ target: Int) {
        guard target != step, target >= 0, target < Self.steps.count else { return }
        // Create mode: forward moves only through the validated primary button.
        step = target
        if target == 1 { onboarding.report(.devotionPromptStepReached) }
        if target == 2 { onboarding.report(.devotionRepeatStepReached) }
    }

    // ── Step 1: WHO & WHEN ────────────────────────────────────────────────────

    @ViewBuilder private var whoAndWhenCards: some View {
        FSFormCard(title: "Details") {
            VStack(alignment: .leading, spacing: 16) {
                if agents.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Written by").font(.fsLabel).foregroundColor(Theme.textPrimary)
                        Picker("Written by", selection: $selectedAgentId) {
                            ForEach(agents) { agent in Text(agent.displayLabel).tag(agent.id) }
                        }
                        .labelsHidden()
                        .tint(Theme.gold)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Group").font(.fsLabel).foregroundColor(Theme.textPrimary)
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
                        HStack {
                            Text(selectedGroupLabel).font(.fsBody).foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: Theme.formFieldHeight)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fieldFill))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
                    }
                    .accessibilityLabel("Group, \(selectedGroupLabel)")
                    Text("Optionally tie this devotion's notes to one of your groups.")
                        .font(.fsHelper).foregroundColor(Theme.textSecondary)
                }
                HStack {
                    Text("Time").font(.fsLabel).foregroundColor(Theme.textPrimary)
                    Spacer()
                    DatePicker("Time", selection: $selectedTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .tint(Theme.gold)
                }
                .frame(minHeight: 44)
            }
        }
        // Hidden (not disabled) outside a group: an ungrouped event has no other editor.
        if !selectedGroupId.isEmpty {
            FSFormCard(title: "Permissions") {
                FSToggleRow(title: notesPublic ? "Group can edit" : "Owner only",
                            helper: "Whether other members of \(selectedGroupLabel) may edit the notes this devotion writes.",
                            isOn: $notesPublic)
            }
        }
    }

    // ── Step 2: PROMPT ────────────────────────────────────────────────────────

    private var promptCard: some View {
        FSFormCard(title: "Prompt") {
            Text("Every day at your chosen time, your AI study partner writes a devotion from this prompt and saves it as a note, even when the app is closed.")
                .font(.fsHelper).foregroundColor(Theme.textSecondary)
            FSField(label: "Prompt", required: true, text: $prompt,
                    state: promptError.map { .error($0) } ?? .normal,
                    multiline: true, minLines: 5)
                .onChange(of: prompt) { _, _ in promptError = nil }
        }
    }

    // ── Step 3: REPEAT ────────────────────────────────────────────────────────

    @ViewBuilder private var repeatCards: some View {
        FSFormCard(title: "Repeat") {
            FSSegmented(options: [(Recurrence.daily, "Daily"), (Recurrence.weekly, "Weekly"), (Recurrence.monthly, "Monthly")],
                        selection: $recurrence)
                .onChange(of: recurrence) { _, _ in daysError = nil }
            switch recurrence {
            case .daily:
                Text("Every day of the month.").font(.fsHelper).foregroundColor(Theme.textSecondary)
            case .weekly:
                weekdayPicker
            case .monthly:
                monthDayPicker
            }
            if let daysError {
                Text(daysError).font(.fsHelper).foregroundColor(Theme.error)
            }
        }
    }

    private var weekdayPicker: some View {
        let days: [(String, Int)] = [("Mon", 2), ("Tue", 3), ("Wed", 4), ("Thu", 5), ("Fri", 6), ("Sat", 7), ("Sun", 1)]
        return LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 10) {
            ForEach(days, id: \.1) { day in
                let sel = selectedWeekdays.contains(day.1)
                Button(action: {
                    if sel { selectedWeekdays.remove(day.1) } else { selectedWeekdays.insert(day.1) }
                    daysError = nil
                }) { FSChipLabel(title: day.0, selected: sel) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
    }

    private var monthDayPicker: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 7), spacing: 10) {
            ForEach(1...31, id: \.self) { day in
                let sel = selectedMonthDays.contains(day)
                Button(action: {
                    if sel { selectedMonthDays.remove(day) } else { selectedMonthDays.insert(day) }
                    daysError = nil
                }) { FSChipLabel(title: "\(day)", selected: sel, compact: true) }
                .buttonStyle(.plain)
                .accessibilityLabel("Day \(day)")
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
    }

    private func saveDevotion() {
        // In-flight guard: a rapid double-tap can't fire onSave twice.
        guard !isSaving else { return }
        isSaving = true
        let idempotencyKey = UUID().uuidString
        onSave(selectedAgentId,
               promptTrimmed,
               buildTimestamps(),
               selectedGroupId.isEmpty ? nil : selectedGroupId,
               // Fail closed: an ungrouped event can't carry an edit-permission grant.
               selectedGroupId.isEmpty ? false : notesPublic,
               idempotencyKey)
        dismiss()
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

    // Formats/stores the selected time as literal local wall-clock "HH:mm"
    // (task 20260905-heartbeat-timezone-duplicate-bugs, Bug 1) -- previously
    // hardcoded TimeZone(identifier: "UTC"), double-converting a value the
    // backend now interprets as local time in the owning user's
    // users.timezone (per the 20260901-heartbeat-backend-scheduling
    // revision), which caused a 9:00 AM pick to be stored/fired as if it
    // meant 9:00 AM UTC. iOS is the side that changes to match the
    // backend's now-sole-authority interpretation, not the reverse.
    private func buildTimestamps() -> [String?] {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        f.timeZone = TimeZone.current
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
