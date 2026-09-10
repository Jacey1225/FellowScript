// ChatMessageDisappearReentryRegressionTests.swift — testing gate coverage
// for task 20260910-chat-message-disappear-reentry.
//
// Bug: a friend (DM) message appears immediately via the optimistic local
// echo (ChatThreadViewModel.sendMessage), but silently vanishes the next
// time the thread is reloaded if the backend actually rejected/failed to
// save it — the client had no way to learn a send failed, because
// receiveLoop() only ever acted on a frame if `json["text"]` unwrapped,
// silently skipping the backend's own explicit `{"type":"error",...}`
// frames (design-notes.md; api/backend/interactions/websockets.py
// ConnectionManager.send_msg).
//
// Backend step 1 found no server-side defect — ordinary friend-DM sends
// reliably succeed and persist — so this suite covers the two real gaps the
// fix closes on the client:
//   1. receiveLoop() now explicitly branches on json["type"] (error/ping/
//      default) instead of silently no-oping on any frame lacking `text`.
//   2. A `{"type":"error",...}` frame flags the oldest still-unconfirmed
//      optimistic message (FIFO correlation, design-notes.md) instead of
//      leaving it to quietly disappear on the next reload with zero signal.
// Plus the acceptance-criteria baseline that must NOT regress: a send the
// backend actually saves survives thread re-entry on both a warm (cached)
// and cold reload.
//
// Uses the same real-loopback-WebSocket-server technique as
// ChatGroupSelfEchoDedupRegressionTests (URLSessionWebSocketTask isn't
// mockable/injectable) — duplicated locally rather than shared, per this
// project's per-bug test file convention.
import XCTest
import SwiftUI
import Network
import ViewInspector
@testable import FellowScript

final class ChatMessageDisappearReentryRegressionTests: XCTestCase {

    /// Minimal local WebSocket server — see ChatGroupSelfEchoDedupRegressionTests'
    /// own copy for the full rationale. Duplicated here rather than shared.
    final class WSTestServer {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "chat-disappear-reentry-test.server")
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
            throw NSError(domain: "WSTestServer", code: 1,
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
            throw NSError(domain: "WSTestServer", code: 2,
                           userInfo: [NSLocalizedDescriptionKey: "no client connection completed the handshake in time"])
        }

        func sendFrame(_ json: [String: Any]) throws {
            lock.lock(); let connection = readyConnections.last; lock.unlock()
            guard let connection else {
                throw NSError(domain: "WSTestServer", code: 3,
                               userInfo: [NSLocalizedDescriptionKey: "no ready connection to send on"])
            }
            let data = try JSONSerialization.data(withJSONObject: json)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "textFrame", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true,
                             completion: .contentProcessed { _ in })
        }
    }

    private func freshUserId(_ label: String) -> String { "\(label)-\(UUID().uuidString)" }

    // MARK: - 1. Error frame flags the oldest pending optimistic message, doesn't duplicate

    func test_errorFrame_flagsOptimisticMessage_asFailed_notAppendedAsPhantomInboundMessage() async throws {
        let server = try WSTestServer()
        let port = try await server.start()
        defer { server.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"
        service.fetchFriendMessagesResult = []

        let userId = freshUserId("sender")
        let contact = FSContact(id: "friend-1", name: "Test Friend", type: .friend)

        let vm = await ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: userId)
        try await server.waitForConnection()

        let sentText = "This one gets rejected"
        await vm.sendMessage(text: sentText, attachment: nil, contact: contact, userId: userId)

        let afterOptimistic = await vm.messages
        let optimisticId = afterOptimistic.first(where: { $0.text == sentText })?.id
        XCTAssertNotNil(optimisticId, "sendMessage() must append the optimistic bubble immediately")

        // Backend rejects the send (ConnectionManager.send_msg's ContentRejected
        // path) and sends its own explicit error frame back over the sender's
        // socket -- no `text` key, so before this fix receiveLoop()'s bare
        // `let msgText = json["text"] as? String` guard silently swallowed the
        // ENTIRE frame body: no log, no UI feedback, no rollback.
        try server.sendFrame([
            "type": "error",
            "reason": "message_rejected",
            "detail": "Guideline 1.2 content filter match",
        ])

        try await Task.sleep(nanoseconds: 500_000_000)

        let afterError = await vm.messages
        let failedIds = await vm.failedMessageIds

        XCTAssertEqual(
            afterError.filter { $0.text == sentText }.count, 1,
            "an error frame must not create a second/duplicate bubble -- the original optimistic " +
            "message stays exactly once, just flagged as failed"
        )
        XCTAssertTrue(
            failedIds.contains(optimisticId!),
            "receiveLoop() must recognize {\"type\":\"error\",...} and flag the corresponding " +
            "optimistic message id in failedMessageIds, not silently drop the frame"
        )

        await vm.disconnect()
    }

    // MARK: - 2. Ping frame is an explicit no-op

    func test_pingFrame_isExplicitNoOp_doesNotMutateMessagesOrFailedIds() async throws {
        let server = try WSTestServer()
        let port = try await server.start()
        defer { server.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"
        service.fetchFriendMessagesResult = []

        let userId = freshUserId("sender")
        let contact = FSContact(id: "friend-2", name: "Test Friend", type: .friend)

        let vm = await ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: userId)
        try await server.waitForConnection()

        let beforeCount = await vm.messages.count

        try server.sendFrame(["type": "ping"])
        try await Task.sleep(nanoseconds: 500_000_000)

        let afterMessages = await vm.messages
        let afterFailed = await vm.failedMessageIds

        XCTAssertEqual(afterMessages.count, beforeCount,
                        "a heartbeat ping frame must not append/remove any message")
        XCTAssertTrue(afterFailed.isEmpty,
                       "a ping frame must never be mistaken for an error frame")

        await vm.disconnect()
    }

    // MARK: - 3. Ordinary friend-DM delivery frame (no `type` key) still works

    func test_ordinaryFriendDMFrame_noTypeKey_stillAppendsNormally() async throws {
        let server = try WSTestServer()
        let port = try await server.start()
        defer { server.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"
        service.fetchFriendMessagesResult = []

        let userId = freshUserId("viewer")
        let friendId = "friend-3"
        let contact = FSContact(id: friendId, name: "Real Friend", type: .friend)

        let vm = await ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: userId)
        try await server.waitForConnection()

        let inboundText = "Hey, got your note!"
        try server.sendFrame([
            "from_user": friendId,
            "text": inboundText,
            "group_id": "",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ])

        try await Task.sleep(nanoseconds: 500_000_000)

        let messages = await vm.messages
        let inbound = messages.first(where: { $0.text == inboundText })
        XCTAssertNotNil(inbound,
                         "an ordinary chat delivery frame (no `type` key) must still fall through " +
                         "to the existing text-frame handling, unchanged by the new explicit switch")
        XCTAssertEqual(inbound?.mine, false)

        await vm.disconnect()
    }

    // MARK: - 4. Retry action: resend, clear failed state, no duplicate

    func test_retryFailedMessage_removesFailedEntry_resendsSameText_clearsFailedState() async throws {
        let server = try WSTestServer()
        let port = try await server.start()
        defer { server.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"
        service.fetchFriendMessagesResult = []

        let userId = freshUserId("sender")
        let contact = FSContact(id: "friend-4", name: "Test Friend", type: .friend)

        let vm = await ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: userId)
        try await server.waitForConnection()

        let text = "Retry me"
        await vm.sendMessage(text: text, attachment: nil, contact: contact, userId: userId)
        let originalId = await vm.messages.first(where: { $0.text == text })?.id
        XCTAssertNotNil(originalId)

        try server.sendFrame(["type": "error", "reason": "message_not_saved", "detail": "db write failed"])
        try await Task.sleep(nanoseconds: 500_000_000)

        var failedIds = await vm.failedMessageIds
        XCTAssertTrue(failedIds.contains(originalId!), "precondition: the send must be flagged failed before retrying")

        await vm.retryFailedMessage(originalId!, contact: contact, userId: userId)
        try await Task.sleep(nanoseconds: 200_000_000)

        let afterRetry = await vm.messages
        failedIds = await vm.failedMessageIds

        XCTAssertFalse(afterRetry.contains(where: { $0.id == originalId! }),
                        "retryFailedMessage() must remove the old failed entry, not leave it alongside the new attempt")
        XCTAssertFalse(failedIds.contains(originalId!),
                        "the old failed id must be cleared from failedMessageIds")
        XCTAssertEqual(afterRetry.filter { $0.text == text }.count, 1,
                        "exactly one bubble with the retried text must remain -- the new resend, not a duplicate")

        await vm.disconnect()
    }

    // MARK: - 5. Successful DM send survives reload (warm + cold) -- acceptance-criteria baseline

    @MainActor
    func test_successfulSend_survivesReload_coldStart_noPriorCache() async throws {
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1" // nothing listening; load() doesn't block on connect
        let userId = freshUserId("cold")
        let contact = FSContact(id: "friend-cold", name: "Cold Friend", type: .friend)
        let sessionKey = ChatThreadViewModel.roomKey(contact: contact, userId: userId)

        // No prior DiskCache entry at all for this fresh sessionKey (cold reload).
        await DiskCache.shared.remove(forKey: "messages:\(sessionKey)")

        // First open: thread starts empty, user sends a message.
        service.fetchFriendMessagesResult = []
        let vm1 = ChatThreadViewModel()
        await vm1.load(service: service, contact: contact, userId: userId)
        vm1.sendMessage(text: "Saved on the server", attachment: nil, contact: contact, userId: userId)
        vm1.disconnect()

        // User leaves and returns: a brand-new ChatThreadView/viewModel is
        // created (matches real SwiftUI @StateObject lifecycle), and this
        // time the server's history fetch reflects the now-persisted
        // message -- exactly what backend step 1 confirmed happens for an
        // ordinary friend-DM send that the server actually saves.
        service.fetchFriendMessagesResult = [
            FSMessage(id: "server-assigned-1", text: "Saved on the server", mine: true, sender: "",
                      timestamp: ISO8601DateFormatter().string(from: Date())),
        ]
        let vm2 = ChatThreadViewModel()
        await vm2.load(service: service, contact: contact, userId: userId)

        XCTAssertTrue(vm2.messages.contains(where: { $0.text == "Saved on the server" }),
                       "a message the backend actually saved must be present on a cold reload with no prior cache")
        vm2.disconnect()
    }

    @MainActor
    func test_successfulSend_survivesReload_warmCache_freshFetchOverwritesWithConfirmedMessage() async throws {
        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:1"
        let userId = freshUserId("warm")
        let contact = FSContact(id: "friend-warm", name: "Warm Friend", type: .friend)
        let sessionKey = ChatThreadViewModel.roomKey(contact: contact, userId: userId)

        // Warm cache: a prior, older thread state already on disk (as a real
        // prior load() would have written) -- distinct from what the fresh
        // fetch below will return, so this test actually exercises the
        // cache-first-then-overwrite path rather than trivially matching.
        let staleCache = [FSMessage(id: "old-1", text: "older message", mine: false, sender: "Warm Friend",
                                     timestamp: "2026-09-01T00:00:00.000Z")]
        await DiskCache.shared.save(staleCache, forKey: "messages:\(sessionKey)")

        service.fetchFriendMessagesResult = [
            FSMessage(id: "old-1", text: "older message", mine: false, sender: "Warm Friend",
                      timestamp: "2026-09-01T00:00:00.000Z"),
            FSMessage(id: "server-assigned-2", text: "Saved on the server, warm case", mine: true, sender: "",
                      timestamp: ISO8601DateFormatter().string(from: Date())),
        ]

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: userId)

        XCTAssertTrue(vm.messages.contains(where: { $0.text == "Saved on the server, warm case" }),
                       "a message the backend saved must survive a warm (cached) reload -- the fresh " +
                       "fetch at the end of load() must win over the stale cache-first read")
        vm.disconnect()
    }

    // MARK: - 6. A failed send does NOT survive reload as a phantom -- and it surfaced visibly first

    @MainActor
    func test_failedSend_doesNotPersistAsPhantom_onNextReload() async throws {
        let server = try WSTestServer()
        let port = try await server.start()
        defer { server.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"
        service.fetchFriendMessagesResult = []

        let userId = freshUserId("failer")
        let contact = FSContact(id: "friend-fail", name: "Fail Friend", type: .friend)
        let sessionKey = ChatThreadViewModel.roomKey(contact: contact, userId: userId)
        await DiskCache.shared.remove(forKey: "messages:\(sessionKey)")

        let vm1 = ChatThreadViewModel()
        await vm1.load(service: service, contact: contact, userId: userId)
        try await server.waitForConnection()

        vm1.sendMessage(text: "Never actually saved", attachment: nil, contact: contact, userId: userId)
        let failedId = vm1.messages.first(where: { $0.text == "Never actually saved" })?.id
        XCTAssertNotNil(failedId)

        try server.sendFrame(["type": "error", "reason": "message_rejected", "detail": "blocked"])
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(vm1.failedMessageIds.contains(failedId!),
                       "the sender must see a visible signal (failedMessageIds -> the retry line) " +
                       "before the message would otherwise silently vanish")
        vm1.disconnect()

        // Reload: the server's history fetch (ground truth) never had this
        // message -- reproduces the exact reported bug shape if the client
        // had no error signal, except now it's an expected, surfaced outcome
        // rather than a silent, unexplained disappearance.
        let vm2 = ChatThreadViewModel()
        await vm2.load(service: service, contact: contact, userId: userId)
        XCTAssertFalse(vm2.messages.contains(where: { $0.text == "Never actually saved" }),
                        "a message the backend never saved correctly does not reappear on reload")
        vm2.disconnect()
    }

    // MARK: - 7. MessageGroupRow renders the retry affordance and wires it to onRetry

    @MainActor
    func test_messageGroupRow_failedMessageId_rendersRetryLine_tapInvokesOnRetryWithMessageId() throws {
        let msg = FSMessage(id: "failed-msg-1", text: "Didn't send", mine: true, sender: "",
                             timestamp: "2026-09-10T12:00:00.000Z")
        let group = MessageDisplayGroup(id: msg.id, senderInitial: "Y", senderName: "You",
                                         timeLabel: "3:00 PM", isOutgoing: true, date: nil, messages: [msg])

        var retriedIds: [String] = []
        let sut = MessageGroupRow(
            group: group,
            failedMessageIds: [msg.id],
            onRetry: { id in retriedIds.append(id) }
        )

        XCTAssertNoThrow(try sut.inspect().find(button: "Couldn't send — tap to retry"),
                          "a message whose id is in failedMessageIds must render the retry affordance")

        try sut.inspect().find(button: "Couldn't send — tap to retry").tap()
        XCTAssertEqual(retriedIds, [msg.id], "tapping the retry line must invoke onRetry with the failed message's id")
    }

    @MainActor
    func test_messageGroupRow_messageNotInFailedSet_rendersNoRetryLine() throws {
        let msg = FSMessage(id: "ok-msg-1", text: "Sent fine", mine: true, sender: "",
                             timestamp: "2026-09-10T12:00:00.000Z")
        let group = MessageDisplayGroup(id: msg.id, senderInitial: "Y", senderName: "You",
                                         timeLabel: "3:00 PM", isOutgoing: true, date: nil, messages: [msg])

        let sut = MessageGroupRow(group: group, failedMessageIds: [])
        XCTAssertThrowsError(try sut.inspect().find(button: "Couldn't send — tap to retry"),
                              "a message not in failedMessageIds must not render the retry line")
    }
}
