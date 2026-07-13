// SOURCE: frontend/src/pages/Dashboard.jsx (widget layout), NotesSidebar.jsx, MessagingSidebar.jsx
// KEY STATE: notes, highlights, agents, agentMessages (all loaded from service)
// INTERACTIONS: tap recent note → NoteEditor, tap highlight → BibleReader,
//               tap "Continue conversation" → AgentChatView, tap "Create first note"
// DEPENDENCY: AppState.swift, Theme.swift, MockDataService.swift, Models.swift

import SwiftUI
import Combine

// ── Community activity feed item ──────────────────────────────────────────────
struct CommunityActivityItem: Codable {
    enum Kind: String, Codable { case message, groupNote }
    let kind:      Kind
    let name:      String   // contact name or group name
    let preview:   String   // message text or note title
    let timestamp: String   // ISO string; empty → display "recent"

    var icon: String {
        kind == .message ? "bubble.left.fill" : "note.text"
    }

    var timeLabel: String {
        guard !timestamp.isEmpty else { return "recent" }
        let parsers: [ISO8601DateFormatter] = {
            let a = ISO8601DateFormatter()
            a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let b = ISO8601DateFormatter()
            return [a, b]
        }()
        let date = parsers.lazy.compactMap { $0.date(from: timestamp) }.first
        guard let d = date else { return "recent" }
        let diff = Date().timeIntervalSince(d)
        if diff < 60      { return "just now" }
        if diff < 3_600   { return "\(Int(diff / 60))m ago" }
        if diff < 86_400  { return "\(Int(diff / 3_600))h ago" }
        return "\(Int(diff / 86_400))d ago"
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    var service: DataServiceProtocol = MockDataService.shared

    @Published var notes:             [String: FSNote]         = [:]
    @Published var highlights:        [FSHighlight]             = []
    @Published var agents:            [FSAgent]                = []
    @Published var lastAgentMsg:      FSAgentMessage?          = nil
    @Published var sessionPreview:    FSSession?               = nil
    @Published var isLoading          = true
    @Published var featuredHighlight: FSHighlight?
    @Published var communityItems:    [CommunityActivityItem]  = []

    func load(service: DataServiceProtocol, userId: String) async {
        self.service = service
        isLoading = true
        defer { isLoading = false }

        // ── Cache-first: render the dashboard instantly from last-known data ──────
        // Reuses the same cache keys Notes/Chat write to, so the widgets are warm
        // as soon as any tab has loaded once.
        if let cached: [String: FSNote] = await DiskCache.shared.load([String: FSNote].self, forKey: "notes:\(userId)") {
            notes = cached
            isLoading = false
        }
        if let cachedHl: [String: String] = await DiskCache.shared.load([String: String].self, forKey: "highlights:\(userId)") {
            let list = cachedHl.map { FSHighlight.from(key: $0.key, color: $0.value) }.sorted { $0.book < $1.book }
            highlights = list
            if featuredHighlight == nil { featuredHighlight = list.randomElement() }
        }
        if let cached: [FSAgent] = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(userId)") {
            agents = cached
        }
        if let cached: FSAgentMessage = await DiskCache.shared.load(FSAgentMessage.self, forKey: "lastAgentMsg:\(userId)") {
            lastAgentMsg = cached
        }
        if let cached: [CommunityActivityItem] = await DiskCache.shared.load([CommunityActivityItem].self, forKey: "community:\(userId)") {
            communityItems = cached
        }

        async let notesTask    = try? service.fetchNotes(userId: userId)
        async let hlTask       = try? service.fetchHighlights(userId: userId)
        async let agentsTask   = try? service.fetchAgents(userId: userId)
        async let contactsTask = try? service.fetchContacts(userId: userId)

        notes  = (await notesTask)  ?? [:]
        agents = (await agentsTask) ?? []

        var hlDict: [String: String] = [:]
        if let hl = await hlTask {
            hlDict = hl
            let list = hl.map { FSHighlight.from(key: $0.key, color: $0.value) }
                         .sorted { $0.book < $1.book }
            highlights        = list
            featuredHighlight = list.randomElement()
        }

        // Fetch last agent message for the widget
        if let firstAgent = agents.first,
           let msgs = try? await service.fetchAgentMessages(userId: userId, agentId: firstAgent.id) {
            lastAgentMsg = msgs.last
        }

        // Build community activity items from contacts + group notes
        let (contactList, _) = (await contactsTask) ?? ([], [:])
        buildCommunityItems(contacts: contactList)

        // ── Write fresh data back to the (shared) cache ──────────────────────────
        await DiskCache.shared.save(notes,  forKey: "notes:\(userId)")
        await DiskCache.shared.save(agents, forKey: "agents:\(userId)")
        await DiskCache.shared.save(hlDict, forKey: "highlights:\(userId)")
        if let m = lastAgentMsg { await DiskCache.shared.save(m, forKey: "lastAgentMsg:\(userId)") }
        await DiskCache.shared.save(communityItems, forKey: "community:\(userId)")
    }

    var recentNote: (String, FSNote)? {
        notes.max(by: { $0.value.timestamp < $1.value.timestamp })
             .map { ($0.key, $0.value) }
    }

    private func buildCommunityItems(contacts: [FSContact]) {
        var items: [CommunityActivityItem] = []

        // Most recent message: first contact with a non-empty preview
        if let contact = contacts.first(where: { !$0.preview.isEmpty }) {
            items.append(CommunityActivityItem(
                kind:      .message,
                name:      contact.name,
                preview:   contact.preview,
                timestamp: ""
            ))
        }

        // Most recent group note: personal notes that belong to a group
        if let groupNote = notes.values
            .filter({ !$0.group_id.isEmpty })
            .sorted(by: { $0.timestamp > $1.timestamp })
            .first {
            items.append(CommunityActivityItem(
                kind:      .groupNote,
                name:      groupNote.title.isEmpty ? "Untitled" : groupNote.title,
                preview:   groupNote.preview,
                timestamp: groupNote.timestamp
            ))
        }

        // Notes with timestamps sort above message items (which have no timestamp)
        items.sort {
            if !$0.timestamp.isEmpty && $1.timestamp.isEmpty { return true }
            if $0.timestamp.isEmpty && !$1.timestamp.isEmpty { return false }
            return $0.timestamp > $1.timestamp
        }

        communityItems = Array(items.prefix(2))
    }
}

// ── Dashboard root ────────────────────────────────────────────────────────────
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = DashboardViewModel()
    @State private var navigateToNote: FSNote? = nil
    @State private var showNewNote = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: Theme.spacingMD) {
                        // Section header
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your Profile")
                                .font(.lora(Theme.fontXXS))
                                .tracking(5)
                                .textCase(.uppercase)
                                .foregroundColor(Theme.textGoldMuted)
                            Text("Good morning, \(appState.currentUser?.username ?? "friend")")
                                .font(.playfair(Theme.fontDisplayLG))
                                .foregroundColor(Theme.parchment)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.top, Theme.spacingSM)

                        // 1 — Recent Note Widget
                        RecentNoteWidget(note: vm.recentNote, onTap: { n in navigateToNote = n }, onNew: { showNewNote = true })

                        // 2 — Community Activity Widget
                        CommunityActivityWidget(items: vm.communityItems)

                        // 3 — Highlighted Verse Widget
                        HighlightedVerseWidget(
                            highlight: vm.featuredHighlight,
                            onTap: { h in
                                appState.pendingBibleNav = BibleNavTarget(book: h.book, chapter: h.chapter, verse: h.verse)
                            }
                        )

                        // 4 — Recent Agent Conversation Widget
                        RecentAgentWidget(
                            agent:   vm.agents.first,
                            lastMsg: vm.lastAgentMsg
                        )
                    }
                    .padding(.bottom, Theme.spacingXL)
                }
            }
            .navigationBarHidden(true)
        }
        .task {
            if let uid = appState.currentUser?.user_id {
                await vm.load(service: appState.service, userId: uid)
            }
        }
        .sheet(item: $navigateToNote) { note in
            NoteEditorView(note: note, noteId: note.id, isReadOnly: true)
        }
        .sheet(isPresented: $showNewNote) {
            NoteEditorView(note: nil, noteId: nil, isReadOnly: false)
        }
    }
}

// ── 1. Recent Note Widget ─────────────────────────────────────────────────────
struct RecentNoteWidget: View {
    let note:   (String, FSNote)?
    let onTap:  (FSNote) -> Void
    let onNew:  () -> Void

    var body: some View {
        Group {
            if let (_, n) = note {
                Button(action: { onTap(n) }) {
                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        sectionLabel("Recent Note")
                        Text(n.title.isEmpty ? "Untitled" : n.title)
                            .font(.playfair(Theme.fontHeading))
                            .foregroundColor(Theme.parchment)
                            .lineLimit(1)
                        Text(n.preview)
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                        Text(n.formattedTimestamp)
                            .font(.lora(Theme.fontXS))
                            .foregroundColor(Theme.textGoldMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetCard()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Recent note: \(note?.1.title ?? "")")
            } else {
                // Empty state
                VStack(spacing: Theme.spacingMD) {
                    sectionLabel("Recent Note")
                    Image(systemName: "note.text")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Theme.gold.opacity(0.30))
                    Text("No notes yet")
                        .font(.playfair(Theme.fontBody))
                        .foregroundColor(Theme.textSecondary)
                    Button(action: onNew) {
                        Text("Create your first note")
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.gold)
                            .padding(.horizontal, Theme.spacingMD)
                            .padding(.vertical, Theme.spacingSM)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radius)
                                    .stroke(Theme.borderGold, lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("Create your first note")
                }
                .frame(maxWidth: .infinity)
                .widgetCard()
            }
        }
        .padding(.horizontal, Theme.spacingMD)
    }
}

// ── 2. Community Activity Widget ──────────────────────────────────────────────
struct CommunityActivityWidget: View {
    let items: [CommunityActivityItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            sectionLabel("Community Activity")

            if items.isEmpty {
                VStack(spacing: Theme.spacingSM) {
                    Image(systemName: "person.3")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Theme.gold.opacity(0.30))
                    Text("No recent activity")
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.textSecondary)
                    Text("Add friends or join a group to see activity here.")
                        .font(.lora(Theme.fontXS))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("No recent community activity.")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    if idx > 0 {
                        Divider().background(Theme.borderGoldFaint)
                    }
                    HStack(alignment: .top, spacing: Theme.spacingMD) {
                        Image(systemName: item.icon)
                            .font(.system(size: 16))
                            .foregroundColor(Theme.gold.opacity(0.60))
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.lora(Theme.fontSM, weight: .semibold))
                                .foregroundColor(Theme.parchment)
                                .lineLimit(1)
                            Text(item.preview.isEmpty ? "—" : item.preview)
                                .font(.lora(Theme.fontSM))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text(item.timeLabel)
                            .font(.lora(Theme.fontXXS))
                            .foregroundColor(Theme.textMuted)
                            .padding(.top, 2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.name): \(item.preview), \(item.timeLabel)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetCard()
        .padding(.horizontal, Theme.spacingMD)
    }
}

// ── 3. Highlighted Verse Widget ───────────────────────────────────────────────
struct HighlightedVerseWidget: View {
    let highlight: FSHighlight?
    let onTap: (FSHighlight) -> Void

    private let verseTexts: [String: String] = [
        "John-1-1":       "In the beginning was the Word, and the Word was with God, and the Word was God.",
        "John-1-14":      "And the Word became flesh and dwelt among us, and we have seen his glory, glory as of the only Son from the Father, full of grace and truth.",
        "Psalms-23-1":    "The Lord is my shepherd; I shall not want.",
        "1 Samuel-23-2":  "David inquired of the Lord, saying, 'Shall I go and attack these Philistines?' And the Lord said to David, 'Go and attack the Philistines and save Keilah.'",
        "Genesis-1-1":    "In the beginning, God created the heavens and the earth.",
    ]

    var body: some View {
        Group {
            if let h = highlight {
                Button(action: { onTap(h) }) {
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        sectionLabel("Highlighted Verse")

                        // Highlight color accent bar + reference
                        HStack(spacing: Theme.spacingSM) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: h.color))
                                .frame(width: 3)
                                .accessibilityHidden(true)
                            Text("\(h.book) \(h.chapter):\(h.verse)")
                                .font(.verseRef(Theme.fontXS))
                                .tracking(2)
                                .textCase(.uppercase)
                                .foregroundColor(Theme.goldDim)
                        }

                        // Verse text
                        let key = "\(h.book)-\(h.chapter)-\(h.verse)"
                        if let txt = verseTexts[key] {
                            Text(txt)
                                .font(.lora(Theme.fontBody))
                                .foregroundColor(Theme.parchment)
                                .lineSpacing(5)
                        }

                        Text("Tap to read in context →")
                            .font(.lora(Theme.fontXS))
                            .foregroundColor(Theme.textGoldMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetCard()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Highlighted verse: \(h.book) \(h.chapter):\(h.verse). Tap to read.")
            } else {
                VStack(spacing: Theme.spacingSM) {
                    sectionLabel("Highlighted Verse")
                    Image(systemName: "highlighter")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Theme.gold.opacity(0.30))
                    Text("No highlights yet")
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.textSecondary)
                    Text("Long-press a verse while reading to highlight it.")
                        .font(.lora(Theme.fontXS))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .widgetCard()
                .accessibilityLabel("No highlights yet. Long-press a verse while reading to highlight it.")
            }
        }
        .padding(.horizontal, Theme.spacingMD)
    }
}

// ── 4. Recent Agent Widget ────────────────────────────────────────────────────
struct RecentAgentWidget: View {
    let agent:   FSAgent?
    let lastMsg: FSAgentMessage?
    @State private var showAgentChat = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            sectionLabel("AI Study Partner")

            if let a = agent, let msg = lastMsg {
                HStack(alignment: .top, spacing: Theme.spacingMD) {
                    // Agent avatar
                    ZStack {
                        Circle()
                            .fill(Theme.gold.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "brain")
                            .foregroundColor(Theme.gold)
                            .font(.system(size: 18))
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.displayLabel)
                            .font(.lora(Theme.fontSM, weight: .semibold))
                            .foregroundColor(Theme.parchment)
                        Text(msg.text)
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        Text(msg.formattedTime)
                            .font(.lora(Theme.fontXXS))
                            .foregroundColor(Theme.textMuted)
                    }
                }

                Button(action: { showAgentChat = true }) {
                    Text("Continue conversation →")
                        .font(.lora(Theme.fontSM))
                        .foregroundColor(Theme.gold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingSM)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius)
                                .stroke(Theme.borderGold, lineWidth: 1)
                        )
                }
                .accessibilityLabel("Continue conversation with \(a.displayLabel)")
            } else {
                VStack(spacing: Theme.spacingSM) {
                    Image(systemName: "brain")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Theme.gold.opacity(0.30))
                    Text("No conversations yet")
                        .font(.lora(Theme.fontBody))
                        .foregroundColor(Theme.textSecondary)
                    Button(action: { showAgentChat = true }) {
                        Text("Start a conversation")
                            .font(.lora(Theme.fontSM))
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Start a conversation")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetCard()
        .padding(.horizontal, Theme.spacingMD)
        .sheet(isPresented: $showAgentChat) {
            if let a = agent {
                AgentChatView(agent: a)
            }
        }
    }
}

// ── Shared section label ──────────────────────────────────────────────────────
@ViewBuilder
func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.lora(Theme.fontXXS))
        .tracking(5)
        .textCase(.uppercase)
        .foregroundColor(Theme.textGoldMuted)
}
