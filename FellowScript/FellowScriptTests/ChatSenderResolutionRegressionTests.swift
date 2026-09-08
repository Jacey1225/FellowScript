// ChatSenderResolutionRegressionTests.swift — regression coverage for task
// 20260908-chat-userid-exposure-standalone-media, frontend step 1 / testing
// step 3 (Bug 1, priority).
//
// Root cause: NetworkService+Messaging.swift's history-fetch path and
// ChatThreadViewModel.receiveLoop()'s live-frame path both used to stamp the
// raw `from_user` user id straight onto `FSMessage.sender`, which
// MessageGroupRow.swift/MessageAttachments.swift then rendered directly as
// the visible sender name/accessibility label — exposing a raw user id
// where a display name should appear, for both live-delivered and
// history-loaded messages, in both DM and group threads.
//
// The fix resolves at message-construction time (not render time):
//   • ChatThreadViewModel.load() maps every fetched FSMessage through
//     resolvedMessage(_:senderName:) — for a DM, using `contact.name` when
//     `from_user == contact.id` (no extra network call); for a group, using
//     a memberId -> username map now also returned by
//     resolveGroupMemberPhotos (which already fetched `u.username` per
//     member for the photo feature but used to discard it).
//   • receiveLoop() resolves the same way via resolvedSenderName(forRawId:),
//     reading the same currentContact/groupUsernameById state load() already
//     populated, so the live path needs no extra fetch either.
//   • A failed/unresolvable lookup (fetchUser throws, or a from_user with no
//     entry in the map) falls back to the raw id — the pre-fix behavior, not
//     a new regression — rather than crashing or blanking the label.
//
// This file covers the history-fetch path (both DM and group, including a
// partial group-member lookup failure) directly through ChatThreadViewModel
// .load(); the live-frame DM path via a real local WebSocket loopback server
// (mirroring ChatGroupSelfEchoDedupRegressionTests' technique, which already
// covers the live-frame GROUP path as of this same task); and integration
// with MessageDisplayGroup.grouped(from:me:) to prove consecutive-message
// grouping still groups correctly once `sender` holds a resolved name
// instead of a raw id.
import XCTest
import Network
@testable import FellowScript

@MainActor
final class ChatSenderResolutionRegressionTests: XCTestCase {

    private func rawMessage(_ id: String, sender: String, text: String = "hi", mine: Bool = false) -> FSMessage {
        FSMessage(id: id, text: text, mine: mine, sender: sender, timestamp: "2026-09-08T12:00:00.000Z")
    }

    // MARK: - History-fetch path: DM

    func test_load_dmHistory_incomingMessage_fromUserMatchingContactId_resolvesToContactName() async {
        let contact = FSContact(id: "friend-id-1", name: "Real Friend Name", type: .friend)
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1" // no real socket needed for this assertion
        service.fetchFriendMessagesResult = [
            rawMessage("m1", sender: contact.id), // raw from_user id, as NetworkService+Messaging.swift hands back
        ]

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: "viewer-1")

        XCTAssertEqual(vm.messages.first?.sender, "Real Friend Name",
                        "a DM's incoming message must be resolved to contact.name, not left as the raw from_user id")
        vm.disconnect()
    }

    func test_load_dmHistory_fromUserNotMatchingContactId_fallsBackToRawId_notCrashOrBlank() async {
        // Edge case flagged in the intake spec's open questions: a from_user
        // that doesn't match contact.id for some reason (future multi-device,
        // stale contact). Must degrade to the raw id -- the pre-fix
        // behavior -- rather than crash or render a blank label.
        let contact = FSContact(id: "friend-id-1", name: "Real Friend Name", type: .friend)
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1"
        service.fetchFriendMessagesResult = [
            rawMessage("m1", sender: "some-other-unresolved-id"),
        ]

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: "viewer-1")

        XCTAssertEqual(vm.messages.first?.sender, "some-other-unresolved-id",
                        "an unresolvable from_user must fall back to the raw id, not crash or blank the label")
        vm.disconnect()
    }

    func test_load_dmHistory_mineMessages_areLeftUntouched() async {
        // resolvedMessage(_:senderName:) must not touch `mine` messages —
        // they already carry sender: "" and are rendered as "You".
        let contact = FSContact(id: "friend-id-1", name: "Real Friend Name", type: .friend)
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1"
        service.fetchFriendMessagesResult = [
            rawMessage("mine-1", sender: "", mine: true),
        ]

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: "viewer-1")

        XCTAssertEqual(vm.messages.first?.sender, "", "an outgoing (mine) message's sender must stay empty, unaffected by sender resolution")
        vm.disconnect()
    }

    // MARK: - History-fetch path: group (multiple members, partial failure)

    func test_load_groupHistory_multipleMembers_eachResolvesToItsOwnDistinctUsername() async {
        let memberA = "member-a-id"
        let memberB = "member-b-id"
        let contact = FSContact(id: "group-1", name: "Study Group", type: .group, toUsers: ["viewer-1", memberA, memberB])
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1"
        service.fetchUserResultsById = [
            memberA: FSUser(user_id: memberA, username: "Alice", email: "alice@example.com"),
            memberB: FSUser(user_id: memberB, username: "Bob", email: "bob@example.com"),
        ]
        service.fetchGroupMessagesResult = [
            rawMessage("a1", sender: memberA),
            rawMessage("b1", sender: memberB),
        ]

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: "viewer-1")

        let bySender = Dictionary(uniqueKeysWithValues: vm.messages.map { ($0.id, $0.sender) })
        XCTAssertEqual(bySender["a1"], "Alice", "member A's message must resolve to member A's own username")
        XCTAssertEqual(bySender["b1"], "Bob", "member B's message must resolve to member B's own (distinct) username, " +
                        "not collapse onto member A's or a shared fixture value")
        vm.disconnect()
    }

    func test_load_groupHistory_oneMemberLookupFails_thatMemberFallsBackToRawId_othersStillResolve() async {
        // Best-effort resolution per resolveGroupMemberPhotos' doc comment:
        // a member who fails to resolve keeps the raw-id fallback, without
        // taking down resolution for the rest of the group.
        let goodMember = "good-member-id"
        let failingMember = "failing-member-id"
        let contact = FSContact(id: "group-1", name: "Study Group", type: .group, toUsers: ["viewer-1", goodMember, failingMember])
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1"
        service.fetchUserResultsById = [
            goodMember: FSUser(user_id: goodMember, username: "GoodMember", email: "good@example.com"),
        ]
        service.fetchUserErrorsById = [
            failingMember: AppError.networkError("simulated GET /user/{id} failure"),
        ]
        service.fetchGroupMessagesResult = [
            rawMessage("g1", sender: goodMember),
            rawMessage("f1", sender: failingMember),
        ]

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: "viewer-1")

        let bySender = Dictionary(uniqueKeysWithValues: vm.messages.map { ($0.id, $0.sender) })
        XCTAssertEqual(bySender["g1"], "GoodMember", "a member whose lookup succeeds must still resolve normally")
        XCTAssertEqual(bySender["f1"], failingMember,
                        "a member whose GET /user/{id} lookup fails must fall back to the raw id, not crash the whole load()")
        vm.disconnect()
    }

    // MARK: - Grouping continuity: MessageDisplayGroup.grouped keys off the now-resolved `sender`

    func test_load_thenGrouped_consecutiveMessagesFromSameResolvedSender_stillGroupTogether() async {
        let memberA = "member-a-id"
        let contact = FSContact(id: "group-1", name: "Study Group", type: .group, toUsers: ["viewer-1", memberA])
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1"
        service.fetchUserResultsById = [
            memberA: FSUser(user_id: memberA, username: "Alice", email: "alice@example.com"),
        ]
        service.fetchGroupMessagesResult = [
            rawMessage("a1", sender: memberA, text: "Hey"),
            rawMessage("a2", sender: memberA, text: "you there?"),
        ]

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: "viewer-1")

        let groups = MessageDisplayGroup.grouped(from: vm.messages, me: nil)
        XCTAssertEqual(groups.count, 1,
                        "two consecutive messages from the same real sender must still collapse into one group " +
                        "once `sender` holds the resolved username consistently, exactly as it did with the raw id before")
        XCTAssertEqual(groups.first?.senderName, "Alice")
        XCTAssertEqual(groups.first?.messages.map(\.id), ["a1", "a2"])
        vm.disconnect()
    }

    // MARK: - Live-frame path: DM (mirrors ChatGroupSelfEchoDedupRegressionTests'
    // group-side live-frame coverage, added by this same task)

    /// Minimal local WebSocket server -- duplicated locally rather than
    /// shared, matching this project's existing per-bug-test-file convention
    /// (see ChatThreadBackgroundDisconnectRegressionTests.FlakyListener's own
    /// doc comment for the same rationale).
    final class DMWSTestServer {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "chat-sender-resolution-dm-test.server")
        private let lock = NSLock()
        private var isListenerReady = false
        private var readyConnections: [NWConnection] = []

        init() throws {
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            let params = NWParameters.tcp
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            listener = try NWListener(using: params)

            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.lock.lock(); self?.isListenerReady = true; self?.lock.unlock()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .ready = state {
                        self.lock.lock(); self.readyConnections.append(connection); self.lock.unlock()
                    }
                }
                connection.start(queue: self.queue)
                self.drain(connection)
            }
        }

        private func drain(_ connection: NWConnection) {
            connection.receiveMessage { [weak self] _, _, isComplete, error in
                guard let self, error == nil else { return }
                self.drain(connection)
            }
        }

        func start() async throws -> UInt16 {
            listener.start(queue: queue)
            for _ in 0..<100 {
                lock.lock(); let ready = isListenerReady; lock.unlock()
                if ready, let port = listener.port, port.rawValue != 0 { return port.rawValue }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NSError(domain: "DMWSTestServer", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }

        func stop() { listener.cancel() }

        func waitForConnection(timeout: TimeInterval = 8.0) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock(); let hasConnection = !readyConnections.isEmpty; lock.unlock()
                if hasConnection { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NSError(domain: "DMWSTestServer", code: 2,
                           userInfo: [NSLocalizedDescriptionKey: "no client connection completed the handshake in time"])
        }

        func sendFrame(_ json: [String: Any]) throws {
            lock.lock(); let connection = readyConnections.last; lock.unlock()
            guard let connection else {
                throw NSError(domain: "DMWSTestServer", code: 3,
                               userInfo: [NSLocalizedDescriptionKey: "no ready connection to send on"])
            }
            let data = try JSONSerialization.data(withJSONObject: json)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "textFrame", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true,
                             completion: .contentProcessed { _ in })
        }
    }

    func test_receiveLoop_liveDMFrame_resolvesFromUserToContactName_withNoExtraFetch() async throws {
        let server = try DMWSTestServer()
        let port = try await server.start()
        defer { server.stop() }

        let contact = FSContact(id: "friend-id-1", name: "Real Friend Name", type: .friend)
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"
        // No fetchFriendMessagesResult set -> load() gets MockDataService's
        // fixed (userId-agnostic) fixture, irrelevant to this test; what
        // matters is the LIVE frame sent below.

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: "viewer-1")
        try await server.waitForConnection()

        let fetchUserCallsBeforeFrame = service.fetchUserCallCount

        try server.sendFrame([
            "from_user": contact.id,
            "text": "hello from the real websocket frame",
            "group_id": "",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ])
        try await Task.sleep(nanoseconds: 500_000_000)

        let incoming = vm.messages.first(where: { $0.text == "hello from the real websocket frame" })
        XCTAssertEqual(incoming?.sender, "Real Friend Name",
                        "a live-delivered DM frame's from_user must resolve to contact.name via " +
                        "resolvedSenderName(forRawId:), the same as the history-fetch path")
        XCTAssertEqual(service.fetchUserCallCount, fetchUserCallsBeforeFrame,
                        "a DM's live-frame resolution must reuse currentContact state load() already " +
                        "populated -- it must not trigger any additional GET /user/{id} fetch")

        vm.disconnect()
        // Settle window before returning, matching the precedent in
        // ChatThreadBackgroundDisconnectRegressionTests -- avoids this test's
        // NWListener/URLSessionTask teardown still running when the next
        // WS-timing test in this suite starts.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}
