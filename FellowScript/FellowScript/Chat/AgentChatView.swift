// SOURCE: hooks/useAgentChat.js (WebSocket chat, message rendering),
//         Reader.jsx (AgentChatPanel, msg-bubble-markdown styling)
// KEY STATE: messages, inputText, isThinking
// INTERACTIONS: send message via WebSocket, receive streamed response, markdown rendering
// DEPENDENCY: Theme.swift, Models.swift

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

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Reconnecting banner (dropped-socket lifecycle state) ───
                    if !vm.isConnected {
                        HStack(spacing: 6) {
                            ProgressView().tint(Theme.gold).scaleEffect(0.75)
                            Text("Reconnecting…")
                                .font(.lora(Theme.fontXS))
                                .foregroundColor(Theme.textGoldMuted)
                        }
                        .padding(.horizontal, Theme.spacingSM)
                        .padding(.top, Theme.spacingXS)
                        .accessibilityLabel("Reconnecting to agent")
                    }

                    // ── Message list ──────────────────────────────────────────
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Theme.spacingMD) {
                                ForEach(vm.messages) { msg in
                                    AgentMessageBubble(message: msg)
                                        .id(msg.id)
                                        .accessibilityLabel("\(msg.mine ? "You" : "Agent"): \(msg.text)")
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
                    // ── Input bar ──────────────────────────────────────────────
                    HStack(spacing: Theme.spacingSM) {
                        TextField("Ask about Scripture…", text: $inputText, axis: .vertical)
                            .font(.lora(Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                            .lineLimit(1...5)
                            .padding(.horizontal, Theme.spacingMD)
                            .padding(.vertical, Theme.spacingSM)
                            .background(Theme.inputBg)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
                            .submitLabel(.send)
                            .onSubmit(sendMessage)
                            .disabled(vm.isThinking)
                            .accessibilityLabel("Message to agent")

                        Button(action: sendMessage) {
                            Image(systemName: vm.isThinking ? "circle.dotted" : "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(inputText.isEmpty || vm.isThinking ? Theme.gold.opacity(0.35) : Theme.gold)
                                .rotationEffect(vm.isThinking ? .degrees(360) : .zero)
                                .animation(vm.isThinking ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: vm.isThinking)
                        }
                        .disabled(inputText.isEmpty || vm.isThinking)
                        .accessibilityLabel(vm.isThinking ? "Waiting for agent response" : "Send message")
                    }
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.navBg)
                    .overlay(alignment: .top) { Divider().background(Theme.borderGoldFaint) }
                }
            }
            .navigationTitle(agent.displayLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(Theme.gold)
                    }
                    .accessibilityLabel("Close agent chat")
                }
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

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        vm.sendMessage(text: trimmed)
        inputText = ""
    }
}

// ── Agent message bubble ──────────────────────────────────────────────────────
struct AgentMessageBubble: View {
    let message: FSAgentMessage

    var body: some View {
        if message.mine {
            // User message: right-aligned bubble
            HStack(alignment: .top) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 2) {
                    MarkdownBodyView(text: message.text, isMine: true)
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.vertical, Theme.spacingSM)
                        .background(Theme.gold.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusLG)
                                .stroke(Theme.gold.opacity(0.30), lineWidth: 1)
                        )
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: .trailing)
                    Text(message.formattedTime)
                        .font(.lora(Theme.fontXXS))
                        .foregroundColor(Theme.gold.opacity(0.40))
                }
            }
            .accessibilityLabel("You: \(message.text)")
        } else {
            // Agent response: full-width floating text, no bubble
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                MarkdownBodyView(text: message.text, isMine: false, baseFontSize: Theme.fontBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(message.formattedTime)
                    .font(.lora(Theme.fontXXS))
                    .foregroundColor(Theme.gold.opacity(0.40))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.spacingXS)
            .accessibilityLabel("Agent: \(message.text)")
        }
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
