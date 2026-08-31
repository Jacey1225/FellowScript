// SOURCE: hooks/useAgentChat.js (WebSocket chat, message rendering),
//         Reader.jsx (AgentChatPanel, msg-bubble-markdown styling)
// KEY STATE: messages, inputText, isThinking
// INTERACTIONS: send message via WebSocket, receive streamed response, markdown rendering
// DEPENDENCY: Theme.swift, Models.swift
//
// VISUAL: ported onto the "Ember Glass" language already established by
// ChatThreadView.swift (task 20260830-agent-chat-visual-parity-ios) — same
// custom in-body header (RoundIconButton + avatar-initial badge + identity
// label + bottom hairline), same whole-canvas ambient RadialGradient wash,
// same Reconnecting… pill, same MessageGroupRow-derived bubble/avatar/
// sender-name treatment, same Capsule composer + circular gold-gradient send
// button. The header intentionally omits the regular chat's "Schedule" pill
// (agent chats have no scheduling concept) — a plain two-element header
// (back + identity), not a truncated three-element one. Presentation-only:
// AgentChatViewModel's websocket/reconnect/send lifecycle is untouched.

import SwiftUI
import Combine

// ── ViewModel (WebSocket + history) ──────────────────────────────────────────

@MainActor
final class AgentChatViewModel: ObservableObject {
    @Published var messages:   [FSAgentMessage] = []
    @Published var isThinking  = false
    // Surfaced in the view as a small "Reconnecting…" banner, same pattern as
    // ChatThreadViewModel. Previously receiveLoop() only re-armed itself in
    // the `.success` branch of wsTask.receive — on `.failure` (dropped
    // connection, backgrounding, idle-timeout) the closure just returned and
    // the chat silently stopped receiving replies for the rest of the view's
    // lifetime with no reconnect attempt or visible error state (backend
    // step 11 finding #3).
    @Published var isConnected: Bool = true
    // Set when a send fails outright (wsTask?.send's completion handler) so
    // the input bar can show the message wasn't delivered instead of just
    // silently clearing isThinking after the 30s timeout.
    @Published var sendError: String? = nil

    private var wsTask: URLSessionWebSocketTask?
    private var wsBase:   String = ""
    private var agentId:  String = ""
    private var userId:   String = ""
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    // Set by disconnect() (view going away) so a `.failure` from that
    // intentional cancel doesn't trigger a reconnect loop.
    private var isDisconnecting = false

    func load(service: DataServiceProtocol, agentId: String, userId: String) async {
        messages = (try? await service.fetchAgentMessages(userId: userId, agentId: agentId)) ?? []
        connectWebSocket(wsBase: service.wsBase, agentId: agentId, userId: userId)
    }

    func sendMessage(text: String) {
        guard !text.isEmpty && !isThinking else { return }
        let iso = ISO8601DateFormatter().string(from: Date())
        messages.append(FSAgentMessage(id: UUID().uuidString, text: text, mine: true, timestamp: iso))
        isThinking = true
        let body = ["content": text]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let str  = String(data: data, encoding: .utf8) else {
            isThinking = false
            sendError = "Could not send message."
            return
        }
        wsTask?.send(.string(str)) { [weak self] error in
            guard let self, let error else { return }
            // Previously discarded entirely — the message stayed in the
            // transcript looking sent, and isThinking spun for the full 30s
            // timeout with no indication anything went wrong.
            Task { @MainActor in
                self.isThinking = false
                self.sendError  = "Message could not be sent: \(error.localizedDescription)"
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if self?.isThinking == true { self?.isThinking = false }
        }
    }

    func disconnect() {
        isDisconnecting = true
        reconnectTask?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func connectWebSocket(wsBase: String, agentId: String, userId: String) {
        self.wsBase  = wsBase
        self.agentId = agentId
        self.userId  = userId
        guard let url = URL(string: "\(wsBase)/agent/ws/\(agentId)/\(userId)") else { return }
        wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask?.resume()
        isConnected = true
        // Do NOT reset reconnectAttempt here — this is called both for the
        // initial connect (where reconnectAttempt is already 0) and for
        // every retry scheduleReconnect() makes. Resetting it here made the
        // exponential backoff never actually grow past its first ~1s delay,
        // since scheduleReconnect() calls straight back into this function.
        // reconnectAttempt is reset instead in receiveLoop()'s `.success`
        // case, once a frame actually arrives and the connection is
        // confirmed genuinely live.
        receiveLoop()
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                // A frame arrived, so this connection is confirmed live —
                // this is the "genuinely fresh/successful connection" point,
                // not merely a call to connectWebSocket(). Reset backoff here.
                self.reconnectAttempt = 0
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? String {
                    let reply = FSAgentMessage(
                        id:        UUID().uuidString,
                        text:      content,
                        mine:      false,
                        timestamp: (json["timestamp"] as? String) ?? ISO8601DateFormatter().string(from: Date())
                    )
                    Task { @MainActor in
                        self.messages.append(reply)
                        self.isThinking = false
                    }
                }
                // Keep listening regardless of whether this particular frame
                // parsed — an unparseable frame (e.g. a control frame)
                // shouldn't end the loop the same way a dropped connection does.
                self.receiveLoop()
            case .failure:
                // The task itself failed. This used to just return, silently
                // ending the chat for the rest of the view's lifetime.
                // Reconnect with capped exponential backoff instead.
                Task { @MainActor in self.scheduleReconnect() }
            }
        }
    }

    private func scheduleReconnect() {
        guard !isDisconnecting else { return }
        isConnected = false
        wsTask = nil
        reconnectAttempt += 1
        let delaySeconds = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0) // 1s, 2s, 4s, …, capped at 30s
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isDisconnecting else { return }
            self.connectWebSocket(wsBase: self.wsBase, agentId: self.agentId, userId: self.userId)
        }
    }
}

// ── View ──────────────────────────────────────────────────────────────────────

struct AgentChatView: View {
    let agent: FSAgent
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @StateObject private var vm = AgentChatViewModel()
    @State private var inputText = ""

    private var userInitial: String {
        let name = appState.currentUser?.username ?? ""
        return name.isEmpty ? "U" : String(name.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            // Warm bloom ground — identical values to ChatThreadView.swift/
            // ChatRootView.swift/NotesListView.swift/NoteEditorView.swift, so
            // this screen shares the same ambient background treatment.
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                // ── Reconnecting banner (dropped-socket lifecycle state) ───
                if !vm.isConnected {
                    HStack(spacing: 6) {
                        ProgressView().tint(Theme.gold).scaleEffect(0.75)
                        Text("Reconnecting…")
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.textGoldMuted)
                    }
                    .padding(.horizontal, Theme.spacingSM)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.045))
                    .overlay(Capsule().stroke(Theme.borderGoldFaint, lineWidth: 1))
                    .clipShape(Capsule())
                    .topEdgeHighlight(Capsule())
                    .padding(.horizontal, Theme.spacingSM)
                    .padding(.top, Theme.spacingXS)
                    .accessibilityLabel("Reconnecting to agent")
                }

                // ── Message list ──────────────────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.spacingMD) {
                            ForEach(vm.messages) { msg in
                                AgentMessageBubble(message: msg, agentName: agent.displayLabel, userInitial: userInitial)
                                    .id(msg.id)
                            }

                            if vm.isThinking {
                                HStack(spacing: Theme.spacingSM) {
                                    TypingIndicator()
                                    Spacer()
                                }
                                .padding(.leading, Theme.spacingMD)
                                .id("thinking")
                            }
                        }
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.vertical, Theme.spacingSM)
                    }
                    .onChange(of: vm.messages.count) { _ in
                        if let last = vm.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: vm.isThinking) { t in
                        if t { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
        }
        .preferredColorScheme(.dark)
        .task {
            let uid = appState.currentUser?.user_id ?? ""
            await vm.load(service: appState.service, agentId: agent.id, userId: uid)
        }
        .onDisappear { vm.disconnect() }
        .alert("Message Not Sent", isPresented: Binding(
            get: { vm.sendError != nil },
            set: { if !$0 { vm.sendError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.sendError = nil }
        } message: {
            Text(vm.sendError ?? "")
        }
    }

    // ── Header: back · avatar/name — no "Schedule" pill (agent chats have no
    // scheduling concept), so this reads as an intentional two-element
    // header rather than the regular chat's three-element one. Mirrors
    // ChatThreadView.header's exact visual language otherwise. ──────────────
    private var header: some View {
        HStack(spacing: 14) {
            RoundIconButton(systemIcon: "chevron.left") { dismiss() }
                .accessibilityLabel("Go back")

            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.18))
                    Circle().stroke(Theme.borderGoldDim, lineWidth: 1)
                    Text(String(agent.displayLabel.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.gold)
                }
                .frame(width: 38, height: 38)

                Text(agent.displayLabel)
                    .font(.inter(Theme.fontHeading, weight: .bold))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(agent.displayLabel)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingSM)
        .padding(.bottom, Theme.spacingSM)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)
        }
    }

    // ── Composer (mirrors ChatThreadView.composer) ─────────────────────────
    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $inputText,
                      prompt: Text("Ask about Scripture…").foregroundColor(Theme.textSecondary), axis: .vertical)
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.parchment)
                .lineLimit(1...5)
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, Theme.spacingSM)
                .background(Color.white.opacity(0.05))
                .overlay(Capsule().stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(Capsule())
                .submitLabel(.send)
                .onSubmit(sendMessage)
                .disabled(vm.isThinking)
                .accessibilityLabel("Message to agent")

            Button(action: sendMessage) {
                ZStack {
                    Circle()
                        .fill(
                            inputText.isEmpty || vm.isThinking
                                ? AnyShapeStyle(Theme.gold.opacity(0.35))
                                : AnyShapeStyle(Theme.goldGradient)
                        )
                    Image(systemName: vm.isThinking ? "circle.dotted" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.ink)
                        .rotationEffect(vm.isThinking ? .degrees(360) : .zero)
                        .animation(vm.isThinking ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: vm.isThinking)
                }
                .frame(width: 38, height: 38)
            }
            .disabled(inputText.isEmpty || vm.isThinking)
            .accessibilityLabel(vm.isThinking ? "Waiting for agent response" : "Send message")
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingSM)
        .padding(.bottom, Theme.spacingMD)
        .background(Theme.bgPage.opacity(0.55))
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        vm.sendMessage(text: trimmed)
        inputText = ""
    }
}

// ── Agent message bubble ──────────────────────────────────────────────────────
// Single-message equivalent of MessageGroupRow (FSAgentMessage's shape is
// already ungrouped/one-bubble-per-message, so MessageDisplayGroup's
// multi-message grouping machinery doesn't apply) — same avatar badge and
// sender-name/time-label row as the regular chat. The bubble fill/stroke/
// corner-radius/topEdgeHighlight chrome, however, is intentionally
// asymmetric here (task 20260830-agent-chat-bubble-removal): only the
// user's own ("mine") message keeps the gold-tinted bubble container.
// Agent responses render bare against the screen's ambient bgPage +
// radial-gradient wash background — no fill/border/corner/edge-highlight —
// per the user's "content sitting on the root background" request. This
// intentionally diverges from MessageGroupRow's fully-symmetric treatment
// (per-screen component divergence is an accepted preference here).
struct AgentMessageBubble: View {
    let message: FSAgentMessage
    let agentName: String
    let userInitial: String

    private var senderName: String { message.mine ? "You" : agentName }
    private var senderInitial: String {
        message.mine ? userInitial : String(agentName.prefix(1)).uppercased()
    }

    var body: some View {
        // Reserved counter-side gutter (task 20260831-agent-chat-width-
        // separator): deliberately smaller than the opposite side's
        // avatar(32)+HStack-spacing(12)=44pt gutter so the widened text
        // column below reads as offset toward its sender's edge rather
        // than centered — Theme.spacingLG keeps it on the existing
        // spacing scale instead of the previous unlabeled "40" constant.
        HStack(alignment: .top, spacing: 12) {
            if message.mine { Spacer(minLength: Theme.spacingLG) }

            if !message.mine { avatar }

            VStack(alignment: message.mine ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if message.mine { Spacer(minLength: 0) }
                    Text(senderName)
                        .font(.inter(Theme.fontSM, weight: .bold))
                        .foregroundColor(Theme.parchment)
                    if !message.formattedTime.isEmpty {
                        Text(message.formattedTime)
                            .font(.inter(Theme.fontXXS))
                            .foregroundColor(Theme.textSecondary)
                    }
                    if !message.mine { Spacer(minLength: 0) }
                }

                Group {
                    if message.mine {
                        MarkdownBodyView(text: message.text, isMine: true, baseFontSize: Theme.fontBody)
                            .padding(.horizontal, Theme.spacingMD)
                            .padding(.vertical, Theme.spacingSM)
                            .background(Theme.gold.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radiusLG)
                                    .stroke(Theme.borderGoldDim, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
                            .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusLG))
                    } else {
                        // No fill/border/corner-radius/topEdgeHighlight — agent
                        // responses sit directly on the chat's ambient
                        // bgPage + radial-gradient background. Padding is kept
                        // so the text still aligns with the sender-name/time
                        // row above it.
                        MarkdownBodyView(text: message.text, isMine: false, baseFontSize: Theme.fontBody)
                            .padding(.horizontal, Theme.spacingMD)
                            .padding(.vertical, Theme.spacingSM)
                    }
                }
                // Widened from the previous 0.78 cap (task 20260831-agent-
                // chat-width-separator) so the message column uses most of
                // the screen width instead of reading as a narrow, near-
                // centered block; still screen-relative (not a fixed point
                // value) so it scales across device sizes per the mobile-
                // first sizing convention already used here.
                .frame(maxWidth: UIScreen.main.bounds.width * 0.90, alignment: message.mine ? .trailing : .leading)
            }

            if message.mine {
                avatar
            } else {
                Spacer(minLength: Theme.spacingLG)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(senderName): \(message.text)")
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(message.mine ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.gold.opacity(0.18)))
            Circle()
                .stroke(Theme.borderGoldDim, lineWidth: 1)
            Text(senderInitial)
                .font(.inter(Theme.fontXS, weight: .bold))
                .foregroundColor(message.mine ? Theme.ink : Theme.gold)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

// ── Typing indicator (three animated dots) ────────────────────────────────────
struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.gold.opacity(0.40))
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == i ? 1.4 : 1.0)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.13), value: phase)
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
        .onAppear { phase = 0; withAnimation { phase = 2 } }
        .accessibilityLabel("Agent is typing")
    }
}
