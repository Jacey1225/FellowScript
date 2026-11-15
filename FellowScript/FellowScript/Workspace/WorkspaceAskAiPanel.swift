// WorkspaceAskAiPanel.swift — iPad dock panel for Ask AI (flag ask_ai_default_agent).
// Shows the user's chat list inline (no modal sheet in a docked panel), opens a chat
// as AgentChatView(embedded:) and returns to the list from its back / Chats button.
// Reuses ChatViewModel.askAiChats (cache-first, preserved on a failed refresh),
// AskAiChatRow, createAskAiChat and AgentLastVisitedChatStore, like ChatRootView.

import SwiftUI

struct WorkspaceAskAiPanel: View {
    @ObservedObject var vm: ChatViewModel
    @EnvironmentObject private var appState: AppState
    /// nil = list; otherwise the conversation key of the open chat.
    @State private var openKey: String?

    private var userId: String { appState.currentUser?.user_id ?? "" }

    var body: some View {
        Group {
            if let key = openKey {
                AgentChatView(agent: FSAgent.askAi, onBack: closeChat, embedded: true, onShowChats: closeChat)
                    .id(key)
            } else {
                listView
            }
        }
        .task {
            vm.capabilities = appState.capabilities
            await vm.load(service: appState.service, userId: userId)
        }
    }

    private func closeChat() {
        openKey = nil
        // The in-chat "new chat" may have created chats the cached list lacks.
        Task { await vm.refresh(service: appState.service, userId: userId) }
    }

    private func open(chatId: String?) {
        if let chatId { AgentLastVisitedChatStore().set(chatId, userId: userId, agentId: FSAgent.askAiId) }
        openKey = WorkspaceAskAiState.conversationKey(chatId: chatId)
    }

    private func startNewChat() {
        Task { if let chat = await vm.createAskAiChat(userId: userId) { open(chatId: chat.id) } }
    }

    private func retry() { Task { await vm.refresh(service: appState.service, userId: userId) } }

    private var listView: some View {
        let state = WorkspaceAskAiState.content(chatCount: vm.askAiChats.count,
                                                refreshFailed: vm.askAiRefreshFailed, isLoading: vm.isLoading)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your AI chats").font(.inter(Theme.fontHeading, weight: .bold)).foregroundColor(Theme.parchment)
                Spacer()
                Button(action: startNewChat) {
                    Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.goldLight).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New AI chat")
            }
            .padding(.horizontal, 14).padding(.top, 8)

            if let message = WorkspaceAskAiState.bannerMessage(chatCount: vm.askAiChats.count, refreshFailed: vm.askAiRefreshFailed) {
                HStack {
                    Text(message).font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button("Retry", action: retry)
                        .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold).frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 14)
            }

            switch state {
            case .loading:
                Spacer(); ProgressView().frame(maxWidth: .infinity); Spacer()
            case .failedEmpty:
                Spacer()
            case .empty:
                VStack(spacing: Theme.spacingMD) {
                    Spacer()
                    Image(systemName: "brain").font(.system(size: 40, weight: .light)).foregroundColor(Theme.gold.opacity(0.30))
                    Text("No AI chats yet.").font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    Button("Start a chat", action: startNewChat)
                        .font(.inter(Theme.fontBody, weight: .bold)).foregroundColor(Theme.gold).frame(minHeight: 44)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .list:
                List(vm.askAiChats) { chat in
                    AskAiChatRow(chat: chat)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                        .onTapGesture { open(chatId: chat.id) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("AI chat: \(chat.displayTitle)")
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await vm.refresh(service: appState.service, userId: userId) }
            }
        }
    }
}
