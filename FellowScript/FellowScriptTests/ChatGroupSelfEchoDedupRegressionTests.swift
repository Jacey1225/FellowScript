// ChatGroupSelfEchoDedupRegressionTests.swift — regression coverage for
// task: 20260902-group-chat-message-duplication, frontend step 2
// (ChatThreadView.swift's ChatThreadViewModel.receiveLoop()).
//
// Before the fix, a group send fanned the message out to every member in
// `to_users`, which the client itself populates as the full member list
// *including the sender* (sendMessage()'s `contact.toUsers`). Backend step 1
// stops re-delivering that live WebSocket frame back to the sender at the
// source, but this test proves the CLIENT-side defense-in-depth
// independently: even if a self-authored frame does arrive over the socket
// (backend bug, a future regression there, or a race), receiveLoop() must
// recognize `from_user == wsUserId` and drop it rather than appending a
// second, raw-UUID-labeled bubble on top of the optimistic local echo
// already shown by sendMessage().
//
// This also proves the fix does NOT over-suppress: an inbound frame from a
// genuinely different group member must still be appended normally.
//
// Like ChatWebSocketReconnectRegressionTests, URLSessionWebSocketTask can't
// be meaningfully mocked/subclassed and doesn't route through a custom
// URLProtocol, so this drives a REAL local WebSocket server using Network
// framework's NWProtocolWebSocket (server-side RFC 6455 handshake + framing
// handled by the OS), rather than the raw-TCP-reset trick the reconnect test
// uses (which only needs to fail the handshake, never complete it).
import XCTest
import Network
@testable import FellowScript

final class ChatGroupSelfEchoDedupRegressionTests: XCTestCase {

    /// A minimal local WebSocket server: accepts a real RFC 6455 handshake
    /// (via NWProtocolWebSocket, so the OS does the handshake/framing) and
    /// lets the test push arbitrary JSON text frames to the most recently
    /// accepted connection, standing in for the backend's `send_msg` fan-out.
    final class WSTestServer {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "chat-dedup-test.server")
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

        /// Keeps reading (and discarding) whatever the client sends — e.g.
        /// the client's own outbound `sendMessage()` frame — so the
        /// connection's receive side never backs up.
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

        /// Waits until at least one client connection has completed the
        /// WebSocket handshake (i.e. ChatThreadViewModel.connectWebSocket()'s
        /// URLSessionWebSocketTask successfully connected to this server).
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

        /// Sends a JSON text frame to the most recently accepted connection,
        /// mirroring `ConnectionManager.send_msg`'s `frame` dict shape
        /// (`from_user`, `text`, `group_id`, `timestamp`).
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

    func test_groupSend_selfEchoedFrame_isDroppedNotDuplicated_otherMembersFrame_stillAppended() async throws {
        let server = try WSTestServer()
        let port = try await server.start()
        defer { server.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"

        let senderId = "sender-user-1"
        let otherMemberId = "other-member-2"
        let contact = FSContact(
            id: "group-1", name: "Study Group", type: .group,
            toUsers: [senderId, otherMemberId, "other-member-3"]
        )

        let vm = await ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: senderId)

        // Wait for the real WebSocket handshake to complete before driving
        // any frames through it.
        try await server.waitForConnection()

        // ── 1. Sender sends a message: optimistic local echo appended immediately ──
        let sentText = "Hey everyone, see you Wednesday!"
        await vm.sendMessage(text: sentText, attachment: nil, contact: contact, userId: senderId)

        let afterOptimistic = await vm.messages
        XCTAssertEqual(afterOptimistic.filter { $0.text == sentText }.count, 1,
                        "sendMessage() must append exactly one optimistic local bubble")
        XCTAssertTrue(afterOptimistic.first(where: { $0.text == sentText })?.mine ?? false,
                      "the optimistic bubble must be marked mine: true")

        // ── 2. Simulate the self-echo: server relays the sender's own message ──
        // back to their own socket (task 20260902's root cause). Before the
        // fix, receiveLoop() appended this unconditionally as a brand-new,
        // non-mine FSMessage with a raw-UUID sender label -- the exact
        // duplicate bubble from the bug report's screenshot.
        try server.sendFrame([
            "from_user": senderId,
            "text": sentText,
            "group_id": contact.id,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ])

        // Give receiveLoop's async dispatch a moment to process (or, if the
        // bug were present, to wrongly append) the frame.
        try await Task.sleep(nanoseconds: 500_000_000)

        let afterSelfEcho = await vm.messages
        let afterSelfEchoDescription = afterSelfEcho
            .map { "(\($0.text.prefix(12)), mine=\($0.mine), sender=\($0.sender))" }
            .joined(separator: ", ")
        XCTAssertEqual(
            afterSelfEcho.filter { $0.text == sentText }.count, 1,
            "A self-echoed inbound frame (from_user == the sender's own wsUserId) must be " +
            "dropped, not appended as a second bubble. Before the fix this count would be 2: " +
            "the optimistic 'mine' bubble plus a duplicate non-mine bubble with a raw-UUID " +
            "sender label. Got messages: [\(afterSelfEchoDescription)]"
        )

        // ── 3. A genuinely different group member's message must still land ──
        // proving the fix doesn't over-suppress real inbound traffic.
        let otherText = "Sounds good, I'll bring snacks"
        try server.sendFrame([
            "from_user": otherMemberId,
            "text": otherText,
            "group_id": contact.id,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ])

        try await Task.sleep(nanoseconds: 500_000_000)

        let final = await vm.messages
        let otherMessage = final.first(where: { $0.text == otherText })
        XCTAssertNotNil(otherMessage,
                         "an inbound frame from a genuinely different group member must still be appended")
        XCTAssertEqual(otherMessage?.mine, false)
        XCTAssertEqual(otherMessage?.sender, otherMemberId)

        // Total tally: exactly one bubble for the sender's own message, one
        // for the other member's -- no duplicates anywhere.
        XCTAssertEqual(final.filter { $0.text == sentText }.count, 1)
        XCTAssertEqual(final.filter { $0.text == otherText }.count, 1)

        await vm.disconnect()
    }
}
