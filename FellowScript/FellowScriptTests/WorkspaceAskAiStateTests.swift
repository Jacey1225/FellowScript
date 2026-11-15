// WorkspaceAskAiStateTests.swift — task 20261115-ipad-askai-notegate, item 1 (testing).
// Display rules for the iPad Ask AI panel's inline chat list, plus structural checks
// that the embedded onShowChats path is wired and the sheet path is unchanged.

import XCTest
@testable import FellowScript

final class WorkspaceAskAiStateTests: XCTestCase {

    // MARK: content rules
    func test_loading_whenNoChatsAndLoading() {
        XCTAssertEqual(WorkspaceAskAiState.content(chatCount: 0, refreshFailed: false, isLoading: true), .loading)
    }
    func test_empty_whenNoChatsIdleNoError() {
        XCTAssertEqual(WorkspaceAskAiState.content(chatCount: 0, refreshFailed: false, isLoading: false), .empty)
    }
    func test_failedEmpty_whenNoChatsAndFailed_evenIfLoading() {
        XCTAssertEqual(WorkspaceAskAiState.content(chatCount: 0, refreshFailed: true, isLoading: false), .failedEmpty)
        XCTAssertEqual(WorkspaceAskAiState.content(chatCount: 0, refreshFailed: true, isLoading: true), .failedEmpty)
    }
    func test_list_whenChats_regardlessOfFailureOrLoading() {
        for failed in [false, true] {
            for loading in [false, true] {
                XCTAssertEqual(WorkspaceAskAiState.content(chatCount: 3, refreshFailed: failed, isLoading: loading), .list)
            }
        }
    }
    /// Failed refresh must keep previously loaded chats on screen (never blank them).
    func test_failedRefresh_preservesPreviousChats() {
        XCTAssertEqual(WorkspaceAskAiState.content(chatCount: 1, refreshFailed: true, isLoading: false), .list)
    }

    // MARK: banner
    func test_banner_nilWhenNotFailed() {
        XCTAssertNil(WorkspaceAskAiState.bannerMessage(chatCount: 0, refreshFailed: false))
        XCTAssertNil(WorkspaceAskAiState.bannerMessage(chatCount: 5, refreshFailed: false))
    }
    func test_banner_failedEmpty_vsFailedWithCache() {
        XCTAssertEqual(WorkspaceAskAiState.bannerMessage(chatCount: 0, refreshFailed: true), "Couldn't load your chats.")
        XCTAssertEqual(WorkspaceAskAiState.bannerMessage(chatCount: 2, refreshFailed: true), "Couldn't refresh. Showing saved chats.")
    }

    // MARK: flag
    func test_flag_onUsesPanel_offFallsBackToAgentPicker() {
        XCTAssertTrue(WorkspaceAskAiState.usesAskAiPanel(askAiEnabled: true))
        XCTAssertFalse(WorkspaceAskAiState.usesAskAiPanel(askAiEnabled: false))
    }
    func test_flagFailsClosed_allOffCapabilities() {
        XCTAssertFalse(WorkspaceAskAiState.usesAskAiPanel(askAiEnabled: FSCapabilities.allOff.askAiEnabled))
    }

    // MARK: conversation key
    func test_conversationKey_distinctPerChat_andLatestForNil() {
        XCTAssertNotEqual(WorkspaceAskAiState.conversationKey(chatId: "a"), WorkspaceAskAiState.conversationKey(chatId: "b"))
        XCTAssertEqual(WorkspaceAskAiState.conversationKey(chatId: "a"), WorkspaceAskAiState.conversationKey(chatId: "a"))
        XCTAssertEqual(WorkspaceAskAiState.conversationKey(chatId: nil), "askai-latest")
    }

    // MARK: structural wiring
    private func source(_ rel: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "FellowScriptTests" { url.deleteLastPathComponent() }
        url.deleteLastPathComponent()
        return try String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8)
    }

    /// Embedded path: Chats button calls onShowChats and returns before touching the sheet.
    /// Sheet path (non-embedded or no callback) still opens AgentChatsSheet.
    func test_agentChatView_embeddedChatsButton_callsOnShowChats_sheetPathUnchanged() throws {
        let src = try source("FellowScript/Chat/AgentChatView.swift")
        XCTAssertTrue(src.contains("var onShowChats: (() -> Void)? = nil"))
        let embedded = try XCTUnwrap(src.range(of: "if embedded, let onShowChats { onShowChats(); return }"))
        let sheetSet = try XCTUnwrap(src.range(of: "showChatsSheet = true", range: embedded.upperBound..<src.endIndex))
        XCTAssertLessThan(embedded.upperBound, sheetSet.lowerBound)
        XCTAssertTrue(src.contains("AgentChatsSheet("))
        XCTAssertTrue(src.contains(".sheet(isPresented: $showChatsSheet)"))
    }

    /// Panel opens the chat embedded, with onShowChats returning to the list; and only
    /// WorkspaceView (not iPhone ChatRootView) uses the panel.
    func test_panel_embedsChat_andReturnsToList() throws {
        let panel = try source("FellowScript/Workspace/WorkspaceAskAiPanel.swift")
        XCTAssertTrue(panel.contains("embedded: true, onShowChats: closeChat"))
        XCTAssertTrue(panel.contains("AgentLastVisitedChatStore()"))
        XCTAssertFalse(try source("FellowScript/Chat/ChatRootView.swift").contains("WorkspaceAskAiPanel"))
    }

    /// Flag-off branch keeps the agent chip picker.
    func test_workspaceView_flagOffKeepsAgentPickerList() throws {
        let src = try source("FellowScript/Workspace/WorkspaceView.swift")
        let start = try XCTUnwrap(src.range(of: "private var agentBody"))
        let body = String(src[start.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("WorkspaceAskAiState.usesAskAiPanel(askAiEnabled: appState.capabilities.askAiEnabled)"))
        XCTAssertTrue(body.contains("WorkspaceAskAiPanel(vm: startup.chatVM)"))
        XCTAssertTrue(body.contains("AgentPickerList(vm: startup.chatVM"))
    }
}
