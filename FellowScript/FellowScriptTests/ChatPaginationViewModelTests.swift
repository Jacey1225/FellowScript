// ChatPaginationViewModelTests.swift -- task 20261001-chat-pagination,
// testing step 10. ChatThreadViewModel paging: capability gate, applyHistory,
// loadOlder merge/dedup/order, retry after failure, stale-generation discard,
// DiskCache window, ack reconciliation by client_ref (real local WebSocket),
// and the pure anchor-id helper.
// Not asserted (not implemented on iOS by design): 5 s lost-ack refetch,
// "New messages" pill.

import XCTest
@testable import FellowScript

@MainActor
final class ChatPaginationViewModelTests: XCTestCase {

    private func m(_ id: String, _ ts: String = "2026-10-01T10:00:00Z", mine: Bool = false) -> FSMessage {
        FSMessage(id: id, text: "t-\(id)", mine: mine, sender: mine ? "" : "someone", timestamp: ts)
    }
    private func uid(_ l: String) -> String { "\(l)-\(UUID().uuidString)" }
    private func caps(group: Bool = false, dm: Bool = false) -> FSCapabilities {
        FSCapabilities(features: ["chat_pagination": group, "chat_pagination_dm": dm], exploreLink: nil, termsCurrent: true)
    }
    private func cursor(_ id: String) -> FSMessageCursor { FSMessageCursor(timestamp: "ts-\(id)", seq: 1, id: id) }
    private func page(_ msgs: [FSMessage], more: Bool, cursorId: String? = nil) -> FSMessagePage {
        FSMessagePage(messages: msgs, hasMore: more, cursor: more ? cursor(cursorId ?? msgs.first!.id) : nil)
    }
    private func service() -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.wsBaseOverride = "ws://127.0.0.1:1"
        return s
    }
    private let dm = FSContact(id: "friend-1", name: "Friend", type: .friend)
    private let group = FSContact(id: "group-1", name: "G", type: .group, toUsers: ["me", "x"])

    // MARK: capability gate

    func test_gate_flagOffOrMissing_requestsNoLimit_andStaysLegacy() async {
        for c in [FSCapabilities.allOff, caps(group: false, dm: false)] {
            let s = service()
            s.historyResult = .paged(page([m("a")], more: true))
            s.fetchFriendMessagesResult = [m("legacy")]
            let vm = ChatThreadViewModel()
            await vm.load(service: s, contact: dm, userId: uid("gate"), capabilities: c)
            XCTAssertEqual(s.historyLimits.count, 1)
            XCTAssertNil(s.historyLimits[0], "false/missing capability = legacy full-history fetch")
            XCTAssertFalse(vm.pagingEnabled)
            XCTAssertFalse(vm.hasMoreOlder)
            XCTAssertEqual(vm.messages.map(\.id), ["legacy"])
            vm.disconnect()
        }
    }

    func test_gate_isPerKind_groupFlagDoesNotEnableDM_andViceVersa() async {
        let s1 = service()
        s1.fetchFriendMessagesResult = [m("l")]
        let vm1 = ChatThreadViewModel()
        await vm1.load(service: s1, contact: dm, userId: uid("g1"), capabilities: caps(group: true, dm: false))
        XCTAssertNil(s1.historyLimits.first!)
        vm1.disconnect()

        let s2 = service()
        s2.fetchGroupMessagesResult = [m("l")]
        let vm2 = ChatThreadViewModel()
        await vm2.load(service: s2, contact: group, userId: uid("g2"), capabilities: caps(group: false, dm: true))
        XCTAssertNil(s2.historyLimits.first!)
        vm2.disconnect()

        let s3 = service()
        s3.historyResult = .paged(page([m("p")], more: false))
        let vm3 = ChatThreadViewModel()
        await vm3.load(service: s3, contact: dm, userId: uid("g3"), capabilities: caps(dm: true))
        XCTAssertEqual(s3.historyLimits.first!, ChatThreadViewModel.initialPageLimit)
        vm3.disconnect()

        let s4 = service()
        s4.historyResult = .paged(page([m("p")], more: false))
        let vm4 = ChatThreadViewModel()
        await vm4.load(service: s4, contact: group, userId: uid("g4"), capabilities: caps(group: true))
        XCTAssertEqual(s4.historyLimits.first!, ChatThreadViewModel.initialPageLimit)
        vm4.disconnect()
    }

    func test_flagOn_butLegacyShapeReturned_staysLegacy_neverBlank() async {
        let s = service()
        s.historyResult = .legacy([m("a"), m("b")])
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: uid("lshape"), capabilities: caps(dm: true))
        XCTAssertFalse(vm.pagingEnabled)
        XCTAssertEqual(vm.messages.map(\.id), ["a", "b"])
        vm.disconnect()
    }

    func test_pagedLoad_setsState() async {
        let s = service()
        s.historyResult = .paged(page([m("5"), m("6")], more: true, cursorId: "5"))
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: uid("pl"), capabilities: caps(dm: true))
        XCTAssertTrue(vm.pagingEnabled)
        XCTAssertTrue(vm.hasMoreOlder)
        XCTAssertEqual(vm.messages.map(\.id), ["5", "6"])
        vm.disconnect()
    }

    func test_failedFetch_keepsCachedMessages() async {
        let user = uid("cachekeep")
        let key = "messages:\(ChatThreadViewModel.roomKey(contact: dm, userId: user))"
        await DiskCache.shared.save([m("cached")], forKey: key)
        let s = service()
        s.fetchFriendMessagesError = AppError.networkError("down")
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: user, capabilities: caps(dm: true))
        XCTAssertEqual(vm.messages.map(\.id), ["cached"])
        vm.disconnect()
    }

    // MARK: loadOlder

    private func pagedVM(_ s: ThrowingTestDataService, contact: FSContact? = nil, newest: [FSMessage]? = nil) async -> ChatThreadViewModel {
        let c = contact ?? dm
        s.historyResult = .paged(page(newest ?? [m("5"), m("6")], more: true, cursorId: "5"))
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: c, userId: "me-\(UUID().uuidString)",
                      capabilities: c.type == .group ? caps(group: true) : caps(dm: true))
        return vm
    }

    func test_loadOlder_prepends_inServerOrder_dedups_byId_andBumpsToken() async {
        let s = service()
        let vm = await pagedVM(s)
        // page contains an id already present ("5") plus a newer-timestamp-looking
        // older row: order must follow the server, not a timestamp re-sort.
        s.olderResults = [.success(page([m("3", "2026-10-02T00:00:00Z"), m("4"), m("5")], more: true, cursorId: "3"))]
        let token = vm.olderMergeToken
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        XCTAssertEqual(vm.messages.map(\.id), ["3", "4", "5", "6"])
        XCTAssertEqual(Set(vm.messages.map(\.id)).count, vm.messages.count, "no duplicate ids")
        XCTAssertEqual(vm.olderMergeToken, token + 1)
        XCTAssertTrue(vm.hasMoreOlder)
        XCTAssertEqual(s.olderCursors.first, cursor("5"), "first older fetch uses the initial page's cursor")

        s.olderResults = [.success(page([m("1"), m("2")], more: false))]
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        XCTAssertEqual(s.olderCursors.last, cursor("3"), "cursor advances to the previous page's next cursor")
        XCTAssertEqual(vm.messages.map(\.id), ["1", "2", "3", "4", "5", "6"])
        XCTAssertFalse(vm.hasMoreOlder)

        // At the end: no further request.
        let calls = s.olderCursors.count
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        XCTAssertEqual(s.olderCursors.count, calls)
        vm.disconnect()
    }

    func test_loadOlder_allDuplicates_doesNotBumpToken_butAdvancesCursor() async {
        let s = service()
        let vm = await pagedVM(s)
        s.olderResults = [.success(page([m("5"), m("6")], more: true, cursorId: "x"))]
        let token = vm.olderMergeToken
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        XCTAssertEqual(vm.olderMergeToken, token)
        XCTAssertEqual(vm.messages.map(\.id), ["5", "6"])
        vm.disconnect()
    }

    func test_loadOlder_failure_setsRetryFlag_keepsMessages_andRetrySucceeds() async {
        let s = service()
        let vm = await pagedVM(s)
        s.olderResults = [.failure(AppError.networkError("flaky"))]
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        XCTAssertTrue(vm.olderLoadFailed)
        XCTAssertTrue(vm.hasMoreOlder, "a failure must not claim start-of-conversation")
        XCTAssertEqual(vm.messages.map(\.id), ["5", "6"])
        XCTAssertFalse(vm.isLoadingOlder)

        s.olderResults = [.success(page([m("4")], more: false))]
        await vm.loadOlder(service: s, contact: dm, userId: "me")   // retry reuses the SAME cursor
        XCTAssertFalse(vm.olderLoadFailed)
        XCTAssertEqual(s.olderCursors, [cursor("5"), cursor("5")])
        XCTAssertEqual(vm.messages.map(\.id), ["4", "5", "6"])
        XCTAssertFalse(vm.hasMoreOlder)
        vm.disconnect()
    }

    func test_loadOlder_noopOnLegacyThread() async {
        let s = service()
        s.fetchFriendMessagesResult = [m("a")]
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: uid("legacyold"), capabilities: .allOff)
        s.olderResults = [.success(page([m("z")], more: false))]
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        XCTAssertTrue(s.olderCursors.isEmpty)
        XCTAssertEqual(vm.messages.map(\.id), ["a"])
        vm.disconnect()
    }

    func test_loadOlder_groupThread_passesIsGroup() async {
        let s = service()
        let vm = await pagedVM(s, contact: group)
        s.olderResults = [.success(page([m("4")], more: false))]
        await vm.loadOlder(service: s, contact: group, userId: "me")
        XCTAssertEqual(vm.messages.map(\.id), ["4", "5", "6"])
        vm.disconnect()
    }

    func test_reload_afterPaging_resetsToNewestPage() async {
        let s = service()
        let vm = await pagedVM(s)
        s.olderResults = [.success(page([m("4")], more: true, cursorId: "4"))]
        await vm.loadOlder(service: s, contact: dm, userId: "me")
        XCTAssertEqual(vm.messages.count, 3)
        s.historyResult = .paged(page([m("5"), m("6"), m("7")], more: true, cursorId: "5"))
        await vm.load(service: s, contact: dm, userId: "me-reload", capabilities: caps(dm: true))
        XCTAssertEqual(vm.messages.map(\.id), ["5", "6", "7"])
        vm.disconnect()
    }

    func test_pagedThread_diskCacheKeepsOnlyNewest50() async {
        let user = uid("cachewin")
        let many = (0..<80).map { m(String(format: "m%03d", $0)) }
        let s = service()
        s.historyResult = .paged(page(many, more: true, cursorId: "m000"))
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: user, capabilities: caps(dm: true))
        XCTAssertEqual(vm.messages.count, 80, "memory keeps the whole page")
        let key = "messages:\(ChatThreadViewModel.roomKey(contact: dm, userId: user))"
        let cached: [FSMessage]? = await DiskCache.shared.load([FSMessage].self, forKey: key)
        XCTAssertEqual(cached?.count, ChatThreadViewModel.cacheWindow)
        XCTAssertEqual(cached?.last?.id, "m079")
        XCTAssertEqual(cached?.first?.id, "m030")
        vm.disconnect()
    }

    func test_legacyThread_diskCacheKeepsEverything() async {
        let user = uid("cachelegacy")
        let many = (0..<80).map { m(String(format: "m%03d", $0)) }
        let s = service()
        s.fetchFriendMessagesResult = many
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: user, capabilities: .allOff)
        let key = "messages:\(ChatThreadViewModel.roomKey(contact: dm, userId: user))"
        let cached: [FSMessage]? = await DiskCache.shared.load([FSMessage].self, forKey: key)
        XCTAssertEqual(cached?.count, 80)
        vm.disconnect()
    }

    // MARK: anchor id (pure)

    func test_anchorId_isPrefixed_stable_andCannotCollideWithGroupId() {
        XCTAssertEqual(MessageGroupRow.anchorId(for: "abc"), "msg-anchor:abc")
        XCTAssertNotEqual(MessageGroupRow.anchorId(for: "abc"), "abc")
        XCTAssertEqual(MessageGroupRow.anchorId(for: "abc"), MessageGroupRow.anchorId(for: "abc"))
    }

    // MARK: ack reconciliation (real local WebSocket)

    private func connectedPagedVM(_ s: ThrowingTestDataService, server: ChatGroupSelfEchoDedupRegressionTests.WSTestServer,
                                  port: UInt16, flagOn: Bool = true) async throws -> (ChatThreadViewModel, String) {
        s.wsBaseOverride = "ws://127.0.0.1:\(port)"
        let user = uid("ack")
        if flagOn { s.historyResult = .paged(page([m("srv-1")], more: false)) } else { s.fetchFriendMessagesResult = [m("srv-1")] }
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: user, capabilities: flagOn ? caps(dm: true) : .allOff)
        try await server.waitForConnection()
        return (vm, user)
    }

    func test_ack_replacesBubbleInPlace_withServerIdAndTimestamp_notAppended() async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = service()
        let (vm, user) = try await connectedPagedVM(s, server: server, port: port)

        vm.sendMessage(text: "hello", attachment: nil, contact: dm, userId: user)
        XCTAssertEqual(vm.messages.count, 2)
        let localId = vm.messages.last!.id
        let rev = vm.ackRevision

        try server.sendFrame(["type": "ack", "client_ref": localId, "id": "server-id-9", "timestamp": "2026-10-01T12:00:00+00:00"])
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(vm.messages.map(\.id), ["srv-1", "server-id-9"], "replaced in place, not appended")
        XCTAssertEqual(vm.messages.last?.timestamp, "2026-10-01T12:00:00+00:00")
        XCTAssertEqual(vm.messages.last?.text, "hello")
        XCTAssertTrue(vm.messages.last?.mine ?? false)
        XCTAssertEqual(vm.ackRevision, rev + 1)
        vm.disconnect()
    }

    func test_ack_whenServerIdAlreadyPresent_deletesOptimisticBubble() async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = service()
        let (vm, user) = try await connectedPagedVM(s, server: server, port: port)

        vm.sendMessage(text: "hello", attachment: nil, contact: dm, userId: user)
        let localId = vm.messages.last!.id
        // ack names an id a refetch already delivered ("srv-1")
        try server.sendFrame(["type": "ack", "client_ref": localId, "id": "srv-1", "timestamp": "2026-10-01T12:00:00Z"])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(vm.messages.map(\.id), ["srv-1"])
        vm.disconnect()
    }

    func test_ack_unknownClientRef_changesNothing() async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = service()
        let (vm, user) = try await connectedPagedVM(s, server: server, port: port)
        vm.sendMessage(text: "hello", attachment: nil, contact: dm, userId: user)
        let before = vm.messages.map(\.id)
        let rev = vm.ackRevision
        try server.sendFrame(["type": "ack", "client_ref": "nope", "id": "server-x", "timestamp": "t"])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(vm.messages.map(\.id), before)
        XCTAssertEqual(vm.ackRevision, rev)
        vm.disconnect()
    }

    func test_errorFrame_isNeverAnAck_marksOldestPendingFailed() async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = service()
        let (vm, user) = try await connectedPagedVM(s, server: server, port: port)
        vm.sendMessage(text: "hello", attachment: nil, contact: dm, userId: user)
        let localId = vm.messages.last!.id
        // Even if an error frame carried client_ref/id it must not reconcile.
        try server.sendFrame(["type": "error", "reason": "save_failed", "client_ref": localId, "id": "bogus"])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(vm.messages.last?.id, localId, "error frame must not replace the bubble id")
        XCTAssertTrue(vm.failedMessageIds.contains(localId))
        vm.disconnect()
    }

    func test_liveFrame_dedupById_andAckFrameNeverRendersAsBubble() async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = service()
        let (vm, _) = try await connectedPagedVM(s, server: server, port: port)

        // frame for a row history already delivered -> no duplicate
        try server.sendFrame(["id": "srv-1", "from_user": "friend-1", "text": "dup", "timestamp": "2026-10-01T10:00:00Z"])
        // new row with id -> appended once, even if delivered twice
        let fresh: [String: Any] = ["id": "live-2", "from_user": "friend-1", "text": "new", "timestamp": "2026-10-01T10:05:00Z"]
        try server.sendFrame(fresh)
        try server.sendFrame(fresh)
        // ack-shaped frame with no text is not a bubble
        try server.sendFrame(["type": "ack", "client_ref": "zzz", "id": "q"])
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(vm.messages.map(\.id), ["srv-1", "live-2"])
        vm.disconnect()
    }
}
