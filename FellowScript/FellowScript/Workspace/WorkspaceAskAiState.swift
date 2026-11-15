// WorkspaceAskAiState.swift — pure display rules for the iPad Ask AI panel's inline
// chat list (task 20261115-ipad-askai-notegate). No UI, so it is unit-testable.
// Mirrors the iOS Messages "AI" segment (ChatRootView.askAiList): a failed refresh
// keeps the cached chats on screen and adds a retry banner; nothing is fabricated.

import Foundation

enum WorkspaceAskAiState {
    enum Content: Equatable {
        /// First load in flight and nothing cached yet.
        case loading
        /// Loaded with no chats and no error: "No AI chats yet" plus Start a chat.
        case empty
        /// Refresh failed and there is nothing cached to show.
        case failedEmpty
        /// Chats to list (possibly stale when `refreshFailed`).
        case list
    }

    static func content(chatCount: Int, refreshFailed: Bool, isLoading: Bool) -> Content {
        if chatCount > 0 { return .list }
        if refreshFailed { return .failedEmpty }
        return isLoading ? .loading : .empty
    }

    /// Retry banner text, nil when the last refresh succeeded.
    static func bannerMessage(chatCount: Int, refreshFailed: Bool) -> String? {
        guard refreshFailed else { return nil }
        return chatCount == 0 ? "Couldn't load your chats." : "Couldn't refresh. Showing saved chats."
    }

    /// The panel shows the Ask AI list only when the flag is on; flag off keeps the
    /// existing agent picker unchanged.
    static func usesAskAiPanel(askAiEnabled: Bool) -> Bool { askAiEnabled }

    /// Chat the open conversation view should be keyed on, so switching rows rebuilds
    /// AgentChatView (its VM reads the last-visited chat on load).
    static func conversationKey(chatId: String?) -> String { "askai-\(chatId ?? "latest")" }
}
