// SOURCE: hooks/useAgentChat.js (WebSocket chat, message rendering),
//         Reader.jsx (AgentChatPanel, msg-bubble-markdown styling)
// KEY STATE: messages, inputText, isThinking
// INTERACTIONS: send message via WebSocket, receive streamed response, markdown rendering
// DEPENDENCY: Theme.swift, Models.swift

import SwiftUI

struct AgentChatView: View {
    let agent: FSAgent
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var messages:   [FSAgentMessage] = []
    @State private var inputText   = ""
    @State private var isThinking  = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Message list ──────────────────────────────────────────
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Theme.spacingMD) {
                                ForEach(messages) { msg in
                                    AgentMessageBubble(message: msg)
                                        .id(msg.id)
                                        .accessibilityLabel("\(msg.mine ? "You" : "Agent"): \(msg.text)")
                                }

                                // Thinking indicator
                                if isThinking {
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
                        .onChange(of: messages.count) { _ in
                            if let last = messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: isThinking) { t in
                            if t { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                        }
                    }

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
                            .disabled(isThinking)
                            .accessibilityLabel("Message to agent")

                        Button(action: sendMessage) {
                            Image(systemName: isThinking ? "circle.dotted" : "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(inputText.isEmpty || isThinking ? Theme.gold.opacity(0.35) : Theme.gold)
                                .rotationEffect(isThinking ? .degrees(360) : .zero)
                                .animation(isThinking ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isThinking)
                        }
                        .disabled(inputText.isEmpty || isThinking)
                        .accessibilityLabel(isThinking ? "Waiting for agent response" : "Send message")
                    }
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.navBg)
                    .overlay(alignment: .top) { Divider().background(Theme.borderGoldFaint) }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
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
        .onAppear { messages = MockDataService.mockAgentMessages }
    }

    private func sendMessage() {
        guard !inputText.isEmpty && !isThinking else { return }
        let userMsg = FSAgentMessage(
            id:        UUID().uuidString,
            text:      inputText,
            mine:      true,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        messages.append(userMsg)
        inputText   = ""
        isThinking  = true

        // Simulate agent response (in production this streams via WebSocket)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let reply = FSAgentMessage(
                id:        UUID().uuidString,
                text:      "That's a wonderful question. Let me reflect on that Scripture with you…",
                mine:      false,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            messages.append(reply)
            isThinking = false
        }
    }
}

// ── Agent message bubble (mirrors .msg-bubble-markdown styling) ──────────────
struct AgentMessageBubble: View {
    let message: FSAgentMessage

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacingSM) {
            if !message.mine {
                // Agent avatar
                ZStack {
                    Circle()
                        .fill(Theme.gold.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "brain")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.gold)
                }
                .accessibilityHidden(true)
            }

            if message.mine { Spacer(minLength: 60) }

            VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .font(.lora(Theme.fontSM))
                    .foregroundColor(message.mine ? Theme.parchment : Theme.parchment.opacity(0.80))
                    .lineSpacing(4)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(
                        message.mine
                        ? Theme.gold.opacity(0.18)
                        : Color.white.opacity(0.05)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusLG)
                            .stroke(
                                message.mine
                                ? Theme.gold.opacity(0.30)
                                : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: message.mine ? .trailing : .leading)

                Text(message.formattedTime)
                    .font(.lora(Theme.fontXXS))
                    .foregroundColor(Theme.gold.opacity(0.40))
            }

            if !message.mine { Spacer(minLength: 60) }
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
