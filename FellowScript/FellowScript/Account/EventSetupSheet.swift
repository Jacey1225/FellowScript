// Multi-step sheet for creating a new heartbeat event.
// Step 1: Recurrence (Daily / Weekly / Monthly)
// Step 2: Day picker (weekday pills for Weekly, 1-31 grid for Monthly; skipped for Daily)
// Step 3: Agent picker (if more than one), time, and prompt

import SwiftUI

struct EventSetupSheet: View {
    let agents:   [FSAgent]
    var existing: FSHeartbeat? = nil
    let onSave:   (_ agentId: String, _ prompt: String, _ timestamps: [String?]) -> Void

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
                    .font(.lora(Theme.fontSM))
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
        .background(Theme.bgPage.ignoresSafeArea())
        .navigationTitle(isEditing ? "Edit Event" : "New Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
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
                    Text(title).font(.lora(Theme.fontBody)).foregroundColor(Theme.parchment)
                    Text(description).font(.lora(Theme.fontSM)).foregroundColor(Theme.textMuted)
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
        .background(Theme.bgPage.ignoresSafeArea())
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
                            .font(.lora(Theme.fontSM))
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
                            .font(.lora(Theme.fontXS))
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

    private var detailsScreen: some View {
        Form {
            if agents.count > 1 {
                Section {
                    Picker("Agent", selection: $selectedAgentId) {
                        ForEach(agents) { agent in
                            Text(agent.displayLabel).tag(agent.id)
                        }
                    }
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                } header: {
                    Text("AGENT")
                        .font(.lora(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
                }
                .listRowBackground(Theme.cardBg)
            }

            Section {
                DatePicker("Time", selection: $selectedTime, displayedComponents: .hourAndMinute)
                    .font(.lora(Theme.fontBody))
                    .labelsHidden()
                    .accentColor(Theme.gold)
            } header: {
                Text("EVENT TIME")
                    .font(.lora(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
            }
            .listRowBackground(Theme.cardBg)

            Section {
                Text("The agent will respond to this prompt when the event fires and save the response as a note.")
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.cardBg)
                TextEditor(text: $prompt)
                    .font(.lora(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
                    .listRowBackground(Theme.cardBg)
            } header: {
                Text("PROMPT")
                    .font(.lora(Theme.fontXXS)).tracking(4).foregroundColor(Theme.textGoldMuted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bgPage)
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditing ? "Update" : "Save") {
                    onSave(selectedAgentId,
                           prompt.trimmingCharacters(in: .whitespaces),
                           buildTimestamps())
                    dismiss()
                }
                .foregroundColor(Theme.gold)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || selectedAgentId.isEmpty)
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

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
