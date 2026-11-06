// AskAiChatListTests.swift — task 20261106-remove-agents-ask-ai, testing step 8.
//
// Covers the iOS "Ask AI" changes behind capability `ask_ai_default_agent`:
//   1. Capability fails closed (missing / off = legacy agents UI).
//   2. Flag OFF: ChatViewModel behaves exactly as before (agents fetched and
//      cached under agents:<uid>; the Ask AI chat list is never touched).
//   3. Flag ON: the Ask AI chat list is fetched and cached under
//      askAiChats:<uid>; agents are neither fetched nor read/written.
//   4. Throw-not-fabricate / preserve-cache-on-failed-refresh: a failed
//      refresh keeps the on-screen list and the cache, flags the banner, and
//      a later success clears it; a cold start with the network down shows
//      the cached list.
//   5. createAskAiChat success prepends + caches; failure surfaces an error
//      and fabricates nothing.
//   6. NetworkService routes the local Ask AI handle to the agent-id-free
//      /ask-ai/{user} surface while real agent ids keep the legacy /agent
//      routes (old-server compatibility).

import XCTest
@testable import FellowScript

@MainActor
final class AskAiChatListTests: XCTestCase {

    private func freshUserId() -> String { "ask-ai-\(UUID().uuidString)" }

    private func caps(askAi: Bool?) -> FSCapabilities {
        guard let askAi else { return .allOff }
        return FSCapabilities(features: ["ask_ai_default_agent": askAi], exploreLink: nil, termsCurrent: true)
    }

    private func chat(_ id: String, _ title: String = "", last: String? = nil) -> FSAgentChat {
        FSAgentChat(id: id, title: title, createdAt: "2026-11-01T08:00:00", lastMessageAt: last)
    }

    // MARK: 1. capability fails closed

    func test_askAiEnabled_failsClosed() {
        XCTAssertFalse(FSCapabilities.allOff.askAiEnabled, "missing flag must read as off")
        XCTAssertFalse(caps(askAi: false).askAiEnabled)
        XCTAssertTrue(caps(askAi: true).askAiEnabled)
        XCTAssertTrue(FSAgent.askAi.isAskAi)
        XCTAssertFalse(FSAgent(id: "real-agent-id", name: "Guide").isAskAi)
    }

    // MARK: 2. flag OFF = unchanged

    func test_flagOff_fetchesAgents_andNeverTouchesAskAiList() async {
        let vm = ChatViewModel()
        vm.capabilities = caps(askAi: false)
        let service = ThrowingTestDataService()
        service.agentChatsResult = [chat("c1", "Should not appear")]
        let uid = freshUserId()

        await vm.load(service: service, userId: uid)

        XCTAssertEqual(service.fetchAgentsCallCount, 1, "flag off must still fetch the agents list")
        XCTAssertEqual(vm.agents.count, 1)
        XCTAssertTrue(vm.askAiChats.isEmpty, "flag off must not populate the Ask AI list")
        XCTAssertFalse(vm.askAiRefreshFailed)
        let cachedChats: [FSAgentChat]? = await DiskCache.shared.load([FSAgentChat].self, forKey: "askAiChats:\(uid)")
        XCTAssertNil(cachedChats, "flag off must not write the askAiChats cache")
        let cachedAgents: [FSAgent]? = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(uid)")
        XCTAssertNotNil(cachedAgents, "flag off keeps writing agents:<uid>")
    }

    // MARK: 3. flag ON

    func test_flagOn_loadsAskAiChats_cachesThem_andSkipsAgents() async {
        let vm = ChatViewModel()
        vm.capabilities = caps(askAi: true)
        let service = ThrowingTestDataService()
        service.agentChatsResult = [chat("c1", "John 1", last: "2026-11-02T09:00:00"), chat("c2", "Psalm 23")]
        let uid = freshUserId()

        await vm.load(service: service, userId: uid)

        XCTAssertEqual(vm.askAiChats.map(\.id), ["c1", "c2"])
        XCTAssertFalse(vm.askAiRefreshFailed)
        XCTAssertEqual(service.fetchAgentsCallCount, 0, "flag on must not fetch agents at all")
        XCTAssertTrue(vm.agents.isEmpty)
        let cachedChats: [FSAgentChat]? = await DiskCache.shared.load([FSAgentChat].self, forKey: "askAiChats:\(uid)")
        XCTAssertEqual(cachedChats?.map(\.id), ["c1", "c2"])
        let cachedAgents: [FSAgent]? = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(uid)")
        XCTAssertNil(cachedAgents, "flag on must not write agents:<uid>")
    }

    func test_flagOn_doesNotClobberExistingAgentsCache() async {
        let uid = freshUserId()
        let legacy = [FSAgent(id: "old-agent", name: "Old")]
        await DiskCache.shared.save(legacy, forKey: "agents:\(uid)")
        let vm = ChatViewModel()
        vm.capabilities = caps(askAi: true)
        let service = ThrowingTestDataService()
        service.agentChatsResult = [chat("c1")]

        await vm.load(service: service, userId: uid)

        let cachedAgents: [FSAgent]? = await DiskCache.shared.load([FSAgent].self, forKey: "agents:\(uid)")
        XCTAssertEqual(cachedAgents?.map(\.id), ["old-agent"],
                       "agents:<uid> must be left untouched with the flag on so flag-off rollback still has its cache")
    }

    // MARK: 4. preserve cache on failed refresh

    func test_flagOn_failedRefresh_keepsListAndCache_andFlagsBanner_thenRecovers() async {
        let vm = ChatViewModel()
        vm.capabilities = caps(askAi: true)
        let service = ThrowingTestDataService()
        service.agentChatsResult = [chat("c1", "John 1"), chat("c2", "Psalm 23")]
        let uid = freshUserId()
        await vm.load(service: service, userId: uid)
        XCTAssertEqual(vm.askAiChats.count, 2)

        service.agentChatsError = AppError.networkError("simulated chats failure")
        await vm.refresh(service: service, userId: uid)

        XCTAssertEqual(vm.askAiChats.map(\.id), ["c1", "c2"],
                       "a failed refresh must not blank or fabricate the Ask AI list")
        XCTAssertTrue(vm.askAiRefreshFailed, "failure must raise the non-blocking banner flag")
        let cached: [FSAgentChat]? = await DiskCache.shared.load([FSAgentChat].self, forKey: "askAiChats:\(uid)")
        XCTAssertEqual(cached?.map(\.id), ["c1", "c2"], "failed refresh must not overwrite the cache")

        service.agentChatsError = nil
        service.agentChatsResult = [chat("c3", "New one")]
        await vm.refresh(service: service, userId: uid)
        XCTAssertEqual(vm.askAiChats.map(\.id), ["c3"], "a proven success replaces the list (including shrinking it)")
        XCTAssertFalse(vm.askAiRefreshFailed)
    }

    func test_flagOn_coldStart_networkDown_showsCachedList() async {
        let uid = freshUserId()
        await DiskCache.shared.save([chat("cached-1", "From cache")], forKey: "askAiChats:\(uid)")
        let vm = ChatViewModel()
        vm.capabilities = caps(askAi: true)
        let service = ThrowingTestDataService()
        service.agentChatsError = AppError.networkError("offline")

        await vm.load(service: service, userId: uid)

        XCTAssertEqual(vm.askAiChats.map(\.id), ["cached-1"], "cached chat list must show when the first fetch fails")
        XCTAssertTrue(vm.askAiRefreshFailed)
    }

    func test_flagOn_emptyServerList_isProvenSuccess_notFailure() async {
        let vm = ChatViewModel()
        vm.capabilities = caps(askAi: true)
        let service = ThrowingTestDataService()
        service.agentChatsResult = []
        await vm.load(service: service, userId: freshUserId())
        XCTAssertTrue(vm.askAiChats.isEmpty)
        XCTAssertFalse(vm.askAiRefreshFailed, "an empty but successful response is not a failure")
    }

    // MARK: 5. create chat

    func test_createAskAiChat_success_prependsAndCaches() async {
        let vm = ChatViewModel()
        vm.capabilities = caps(askAi: true)
        let service = ThrowingTestDataService()
        service.agentChatsResult = [chat("old")]
        service.createAgentChatResult = chat("fresh", "Fresh")
        let uid = freshUserId()
        await vm.load(service: service, userId: uid)

        let created = await vm.createAskAiChat(userId: uid)

        XCTAssertEqual(created?.id, "fresh")
        XCTAssertEqual(vm.askAiChats.map(\.id), ["fresh", "old"])
        let cached: [FSAgentChat]? = await DiskCache.shared.load([FSAgentChat].self, forKey: "askAiChats:\(uid)")
        XCTAssertEqual(cached?.map(\.id), ["fresh", "old"])
    }

    func test_createAskAiChat_failure_throwsNotFabricates() async {
        let vm = ChatViewModel()
        vm.capabilities = caps(askAi: true)
        let service = ThrowingTestDataService()
        service.agentChatsResult = [chat("old")]
        let uid = freshUserId()
        await vm.load(service: service, userId: uid)
        service.createAgentChatError = AppError.networkError("chat limit reached")

        let created = await vm.createAskAiChat(userId: uid)

        XCTAssertNil(created, "failure must not return a made-up chat")
        XCTAssertEqual(vm.askAiChats.map(\.id), ["old"], "list unchanged on failed create")
        XCTAssertNotNil(vm.agentError, "failure must surface an error message")
    }
}

// MARK: 6. routing of the Ask AI handle vs legacy agent ids

final class AskAiRoutingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    func test_agentBase_mapsAskAiHandleToAgentIdFreeRoute_legacyIdsUnchanged() {
        XCTAssertEqual(NetworkService.agentBase(userId: "u1", agentId: FSAgent.askAiId), "/ask-ai/u1")
        XCTAssertEqual(NetworkService.agentBase(userId: "u1", agentId: "abc"), "/agent/u1/abc")
    }

    func test_fetchAgentChats_askAiHandle_hitsAskAiRoute_andNeverSendsHandleAsAgentId() async throws {
        StubURLProtocol.requestLog = []
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"chats": [{"id": "c1", "title": "T"}]}"#.data(using: .utf8)!

        let chats = try await NetworkService.shared.fetchAgentChats(userId: "u1", agentId: FSAgent.askAiId)

        XCTAssertEqual(chats.map(\.id), ["c1"])
        let paths = StubURLProtocol.requestLog.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/ask-ai/u1/chats") }, "paths: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("/agent/") }, "the local handle must never reach a legacy /agent route")
    }

    func test_fetchAgentChats_realAgentId_keepsLegacyRoute() async throws {
        StubURLProtocol.requestLog = []
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"chats": []}"#.data(using: .utf8)!

        _ = try await NetworkService.shared.fetchAgentChats(userId: "u1", agentId: "real-id")

        let paths = StubURLProtocol.requestLog.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/agent/u1/real-id/chats") }, "paths: \(paths)")
    }

    func test_fetchAgentChats_serverError_throws_insteadOfReturningEmptyList() async {
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail": "boom"}"#.data(using: .utf8)!
        do {
            let chats = try await NetworkService.shared.fetchAgentChats(userId: "u1", agentId: FSAgent.askAiId)
            XCTFail("a 500 must throw, got \(chats)")
        } catch {
            // expected: throw-not-fabricate
        }
    }

    func test_createAgentChat_askAiHandle_postsToAskAiRoute() async throws {
        StubURLProtocol.requestLog = []
        StubURLProtocol.stubStatusCode = 201
        StubURLProtocol.stubBody = #"{"id": "new-chat", "title": ""}"#.data(using: .utf8)!

        let chat = try await NetworkService.shared.createAgentChat(userId: "u1", agentId: FSAgent.askAiId)

        XCTAssertEqual(chat.id, "new-chat")
        let posts = StubURLProtocol.requestLog.filter { $0.method == "POST" }.map(\.path)
        XCTAssertTrue(posts.contains { $0.hasSuffix("/ask-ai/u1/chats") }, "posts: \(posts)")
    }
}
