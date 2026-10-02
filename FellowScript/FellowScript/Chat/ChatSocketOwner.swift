// ChatSocketOwner.swift — task 20261001-message-threads step 10 (10a).
// The one WebSocket a signed-in user holds to /message/ws/{userId}, extracted
// from ChatThreadViewModel with identical behaviour (capped exponential
// backoff reconnect, backoff reset only once a frame actually arrives,
// intentional-close guard for backgrounding/teardown).
//
// WHY ONE OWNER: the server keeps exactly ONE websocket per user and a new
// connection replaces the old one. A thread view that opened its own socket
// would therefore kill the main chat's live updates. Threads are a MODE of the
// same ChatThreadViewModel (activeThread), and that view model owns exactly
// one ChatSocketOwner, so main-chat frames, thread frames, acks, and
// message_deleted / message_restored frames all arrive on the same socket.
//
// This type only owns connection lifecycle and raw frame delivery; it knows
// nothing about messages. The view model supplies `onFrame` and
// `onConnectionChange`.

import Foundation

@MainActor
final class ChatSocketOwner {
    /// Every parsed JSON object frame, delivered on the main actor, in order.
    var onFrame: (([String: Any]) -> Void)?
    /// true when a connection attempt starts, false when a drop schedules a
    /// reconnect (drives the "Reconnecting…" pill).
    var onConnectionChange: ((Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private(set) var wsBase: String = ""
    private(set) var userId: String = ""
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    // Set by disconnect() (view going away / app backgrounded) so the
    // `.failure` from that intentional cancel does not start a reconnect loop.
    private var isDisconnecting = false

    var isOpen: Bool { task != nil }

    func connect(wsBase: String, userId: String) {
        self.wsBase = wsBase
        self.userId = userId
        guard let url = URL(string: "\(wsBase)/message/ws/\(userId)") else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        onConnectionChange?(true)
        // Do NOT reset reconnectAttempt here: this runs for the initial
        // connect and for every retry scheduleReconnect() makes; resetting it
        // would keep the backoff stuck at its first ~1s delay. It is reset in
        // receive(), once a frame proves the connection is live.
        receive(on: t)
    }

    /// Fire-and-forget send on the current socket (no-op when closed).
    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    /// Intentional close (view teardown). Does not reconnect.
    func disconnect() {
        isDisconnecting = true
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// App went to the background: close proactively so the server stops
    /// treating this client as online (task 20260902-chat-push-notification-failure).
    func handleAppBackgrounded() {
        guard !isDisconnecting else { return }
        disconnect()
    }

    /// Resumes a connection this owner itself closed via handleAppBackgrounded().
    /// Does nothing when it never connected or was torn down for good.
    func handleAppForegrounded() {
        guard isDisconnecting, !wsBase.isEmpty else { return }
        isDisconnecting = false
        reconnectAttempt = 0
        connect(wsBase: wsBase, userId: userId)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A result from a socket that has since been replaced or closed
                // must not start a second connection.
                guard self.task === t else { return }
                switch result {
                case .success(let msg):
                    self.reconnectAttempt = 0
                    if case .string(let text) = msg,
                       let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onFrame?(json)
                    }
                    // Keep listening whether or not this frame parsed.
                    self.receive(on: t)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !isDisconnecting else { return }
        onConnectionChange?(false)
        task = nil
        reconnectAttempt += 1
        let delaySeconds = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0) // 1s, 2s, 4s, ..., capped at 30s
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isDisconnecting else { return }
            self.connect(wsBase: self.wsBase, userId: self.userId)
        }
    }
}
