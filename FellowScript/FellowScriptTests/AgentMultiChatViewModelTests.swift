// AgentMultiChatViewModelTests.swift — task 20261006-agent-multi-chat.
//
// Covers AgentChatViewModel's multi-chat logic (flag `agent_chats`):
//   * opens the last-visited chat; falls back to most recent when the stored
//     id is gone or none recorded; last-visited survives a "relaunch" (a new
//     store over the same UserDefaults suite)
//   * selectChat loads that chat's history, persists last-visited, clears
//     the previous chat's messages (no cross-chat bleed)
//   * createChat makes the new empty chat active and inserts it first;
//     a failure keeps the current chat and surfaces createChatError
//   * reply frames for a different chat are not appended to the visible
//     chat; frames without chat_id (legacy server) go to the active chat
//   * a failed list fetch keeps the previous list (preserve-cache) and sets
//     chatsError; flag off = legacy path (no chat calls, activeChatId nil)
//   * FSAgentChat decoding + NetworkService request shapes via StubURLProtocol

import XCTest
@testable import FellowScript

@MainActor
final class AgentMultiChatViewModelTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        suiteName = "agent-multichat-tests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        StubURLProtocol.resetRequestLog()
    }
    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> AgentLastVisitedChatStore { AgentLastVisitedChatStore(defaults: suite) }

    private func msg(_ id: String, _ text: String, mine: Bool = true) -> FSAgentMessage {
        FSAgentMessage(id: id, text: text, mine: mine, timestamp: "2026-10-06T10:00:00")
    }

    private func service(chats: [FSAgentChat]) -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.wsBaseOverride = "ws://127.0.0.1:1"   // never reachable; WS failures are irrelevant here
        s.agentChatsResult = chats
        s.agentChatMessages = ["c1": [msg("m1", "in c1")], "c2": [msg("m2", "in c2")], "c3": [msg("m3", "in c3")]]
        return s
    }

    private let chats = [FSAgentChat(id: "c1", title: "One"), FSAgentChat(id: "c2", title: "Two"), FSAgentChat(id: "c3", title: "Three")]

    func test_opensMostRecentChatWhenNoneRecorded() async {
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: service(chats: chats), agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        XCTAssertEqual(vm.activeChatId, "c1")
        XCTAssertEqual(vm.messages.map(\.text), ["in c1"])
        XCTAssertEqual(store().chatId(userId: "u", agentId: "a"), "c1")
    }

    func test_opensLastVisitedChat_andSurvivesRelaunch() async {
        store().set("c2", userId: "u", agentId: "a")
        let vm = AgentChatViewModel(lastVisited: store())   // fresh store/VM = relaunch
        await vm.load(service: service(chats: chats), agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        XCTAssertEqual(vm.activeChatId, "c2")
        XCTAssertEqual(vm.messages.map(\.text), ["in c2"])
    }

    func test_staleLastVisitedFallsBackToMostRecent() async {
        store().set("deleted-chat", userId: "u", agentId: "a")
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: service(chats: chats), agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        XCTAssertEqual(vm.activeChatId, "c1")
        XCTAssertEqual(store().chatId(userId: "u", agentId: "a"), "c1")
    }

    func test_lastVisitedIsPerUserAndAgent() async {
        store().set("c3", userId: "u", agentId: "other-agent")
        store().set("c3", userId: "other-user", agentId: "a")
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: service(chats: chats), agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        XCTAssertEqual(vm.activeChatId, "c1")
    }

    func test_selectChat_loadsThatChatsHistory_noBleed_andPersists() async {
        let svc = service(chats: chats)
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: svc, agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        await vm.selectChat("c3")
        XCTAssertEqual(vm.activeChatId, "c3")
        XCTAssertEqual(vm.messages.map(\.text), ["in c3"])
        XCTAssertEqual(store().chatId(userId: "u", agentId: "a"), "c3")
        XCTAssertEqual(svc.fetchAgentMessagesChatIds.last, "c3")
    }

    func test_selectChat_unknownIdIsIgnored() async {
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: service(chats: chats), agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        await vm.selectChat("not-mine")
        XCTAssertEqual(vm.activeChatId, "c1")
        XCTAssertEqual(store().chatId(userId: "u", agentId: "a"), "c1")
    }

    func test_selectChat_historyFailureShowsNoOtherChatsMessages() async {
        let svc = service(chats: chats)
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: svc, agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        svc.agentChatMessagesError = AppError.networkError("boom")
        await vm.selectChat("c2")
        XCTAssertEqual(vm.activeChatId, "c2")
        XCTAssertTrue(vm.messages.isEmpty, "never keep/fabricate another chat's messages")
        XCTAssertNotNil(vm.sendError)
    }

    func test_createChat_isActiveEmptyFirst_andPersisted() async {
        let svc = service(chats: chats)
        svc.createAgentChatResult = FSAgentChat(id: "new1")
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: svc, agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        await vm.createChat()
        XCTAssertEqual(vm.activeChatId, "new1")
        XCTAssertEqual(vm.chats.first?.id, "new1")
        XCTAssertEqual(vm.chats.count, 4)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isThinking)
        XCTAssertEqual(store().chatId(userId: "u", agentId: "a"), "new1")
    }

    func test_createChat_failureKeepsCurrentChat() async {
        let svc = service(chats: chats)
        svc.createAgentChatError = AppError.networkError("Chat limit reached")
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: svc, agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        await vm.createChat()
        XCTAssertEqual(vm.activeChatId, "c1")
        XCTAssertEqual(vm.chats.count, 3)
        XCTAssertEqual(vm.messages.map(\.text), ["in c1"])
        XCTAssertNotNil(vm.createChatError)
        XCTAssertFalse(vm.isCreatingChat)
    }

    func test_replyForOtherChatIsNotAppended_replyForActiveIs() async {
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: service(chats: chats), agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        vm.handleReply(msg("r1", "for c2", mine: false), frameChat: "c2")
        XCTAssertEqual(vm.messages.map(\.text), ["in c1"], "chat B reply must not appear in chat A")
        vm.handleReply(msg("r2", "for c1", mine: false), frameChat: "c1")
        XCTAssertEqual(vm.messages.map(\.text), ["in c1", "for c1"])
        vm.handleReply(msg("r3", "legacy frame", mine: false), frameChat: nil)
        XCTAssertEqual(vm.messages.last?.text, "legacy frame")
    }

    func test_chatListFailureKeepsPreviousList() async {
        let svc = service(chats: chats)
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: svc, agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        svc.agentChatsError = AppError.networkError("down")
        await vm.loadChats()
        XCTAssertEqual(vm.chats.count, 3)
        XCTAssertEqual(vm.activeChatId, "c1")
        XCTAssertNotNil(vm.chatsError)
    }

    func test_flagOff_legacyPath_noChatState() async {
        let svc = service(chats: chats)
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: svc, agentId: "a", userId: "u", chatsEnabled: false)
        defer { vm.disconnect() }
        XCTAssertNil(vm.activeChatId)
        XCTAssertTrue(vm.chats.isEmpty)
        XCTAssertTrue(svc.fetchAgentMessagesChatIds.isEmpty)
        await vm.createChat()
        XCTAssertNil(vm.activeChatId, "createChat is a no-op with the flag off")
        await vm.selectChat("c2")
        XCTAssertNil(vm.activeChatId)
    }

    func test_chatListEmpty_leavesNoActiveChat_noFabrication() async {
        let vm = AgentChatViewModel(lastVisited: store())
        await vm.load(service: service(chats: []), agentId: "a", userId: "u", chatsEnabled: true)
        defer { vm.disconnect() }
        XCTAssertNil(vm.activeChatId)
        XCTAssertTrue(vm.chats.isEmpty)
    }

    func test_FSAgentChat_decodesAndLabels() throws {
        let json = #"{"id":"x","title":"","created_at":"2026-10-06T10:00:00","last_message_at":null}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(FSAgentChat.self, from: json)
        XCTAssertEqual(c.id, "x")
        XCTAssertEqual(c.displayTitle, "New chat")
        XCTAssertNil(c.lastMessageAt)
        let t = try JSONDecoder().decode(FSAgentChat.self, from: #"{"id":"y","title":"Hello"}"#.data(using: .utf8)!)
        XCTAssertEqual(t.displayTitle, "Hello")
    }

    // ── NetworkService request shapes / failure behavior ──────────────────────

    func test_network_fetchAgentChats_decodesAndHitsChatsPath() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"chats":[{"id":"c9","title":"T","created_at":"2026-10-06T10:00:00","last_message_at":"2026-10-06T10:01:00"}]}"#.data(using: .utf8)!
        let got = try await NetworkService.shared.fetchAgentChats(userId: "u1", agentId: "a1")
        XCTAssertEqual(got.map(\.id), ["c9"])
        XCTAssertTrue(StubURLProtocol.requestLog.contains { $0.path.hasSuffix("/agent/u1/a1/chats") })
    }

    func test_network_fetchChatMessages_404Throws_neverFabricatesEmpty() async {
        StubURLProtocol.stubStatusCode = 404
        StubURLProtocol.stubBody = #"{"detail":{"code":"not_found","message":"Not found"}}"#.data(using: .utf8)!
        do {
            _ = try await NetworkService.shared.fetchAgentMessages(userId: "u1", agentId: "a1", chatId: "bad")
            XCTFail("expected throw")
        } catch { /* expected */ }
        XCTAssertTrue(StubURLProtocol.requestLog.contains { $0.url.contains("chat_id=bad") })
    }

    func test_network_createAgentChat_409Throws() async {
        StubURLProtocol.stubStatusCode = 409
        StubURLProtocol.stubBody = #"{"detail":{"code":"chat_limit"}}"#.data(using: .utf8)!
        do {
            _ = try await NetworkService.shared.createAgentChat(userId: "u1", agentId: "a1")
            XCTFail("expected throw")
        } catch { /* expected */ }
        XCTAssertTrue(StubURLProtocol.requestLog.contains { $0.method == "POST" && $0.path.hasSuffix("/agent/u1/a1/chats") })
    }
}
