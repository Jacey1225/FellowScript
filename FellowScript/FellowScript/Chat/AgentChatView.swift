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

    private var wsTask: URLSessionWebSocketTask?

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
        if let data = try? JSONSerialization.data(withJSONObject: body),
           let str  = String(data: data, encoding: .utf8) {
            wsTask?.send(.string(str)) { _ in }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if self?.isThinking == true { self?.isThinking = false }
        }
    }

    func disconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func connectWebSocket(wsBase: String, agentId: String, userId: String) {
        guard let url = URL(string: "\(wsBase)/agent/ws/\(agentId)/\(userId)") else { return }
        wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask?.resume()
        receiveLoop()
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            if case .success(let msg) = result,
               case .string(let text) = msg,
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
                self.receiveLoop()
            }
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
