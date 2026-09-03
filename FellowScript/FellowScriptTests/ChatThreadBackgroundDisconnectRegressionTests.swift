// ChatThreadBackgroundDisconnectRegressionTests.swift — regression coverage
// for task: 20260902-chat-push-notification-failure, frontend step 2.
//
// Before this fix, ChatThreadViewModel's WebSocket was only ever closed by
// `.onDisappear` on the chat view (the view leaving the hierarchy) — not by
// the app itself being backgrounded while the chat thread stayed the
// mounted, foreground-most screen (e.g. the user hits the Home button
// without navigating away). That left `active_connections[uid]` registered
// server-side well after the app could no longer surface an incoming frame
// as a notification: `ws.send_json` "succeeded" at the TCP-write level into
// a suspended client, so ConnectionManager.send_msg never fell through to
// the offline-APNs-push branch for that recipient (the actual reported
// symptom this task fixed).
//
// The fix added ChatThreadViewModel.handleAppBackgrounded() /
// handleAppForegrounded(), wired to `.onChange(of: scenePhase)` in
// ChatThreadView, which reuse the existing isDisconnecting-guarded
// disconnect()/connectWebSocket() plumbing that already backs
// onDisappear/reconnect. The backend heartbeat (step 1) remains the real
// backstop for disconnection modes the client can't self-report (force-quit,
// dropped network) — this only shrinks the race window for the common
// graceful-backgrounding case.
//
// Uses the same loopback FlakyListener technique as
// ChatWebSocketReconnectRegressionTests (URLSessionWebSocketTask isn't
// mockable/injectable and doesn't route through a custom URLProtocol) to
// observe *connection-attempt cadence* rather than message payloads:
//
//   1. A freshly backgrounded chat stops attempting to (re)connect —
//      handleAppBackgrounded() must reuse disconnect()'s isDisconnecting
//      guard so scheduleReconnect() no-ops instead of continuing to retry
//      into the background.
//   2. Foregrounding the same chat resumes connection attempts —
//      handleAppForegrounded() must actually re-invoke connectWebSocket(),
//      not leave the socket permanently closed until the view itself is
//      torn down and rebuilt.
//
// Caveat: timing-sensitive (loopback jitter), consistent with every other
// WS-timing regression test in this suite (see
// ChatWebSocketReconnectRegressionTests/AgentChatReconnectRegressionTests for
// the same caveat and mitigation technique).
import XCTest
import Network
@testable import FellowScript

final class ChatThreadBackgroundDisconnectRegressionTests: XCTestCase {

    /// Same flaky-listener technique as ChatWebSocketReconnectRegressionTests
    /// — duplicated locally (rather than shared) to keep each regression test
    /// file independently runnable/removable per this project's per-bug test
    /// file convention.
    final class FlakyListener {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "chat-bg-disconnect-test.listener")
        private var _acceptTimestamps: [Date] = []
        private let lock = NSLock()

        // See ChatWebSocketReconnectRegressionTests.FlakyListener for why this
        // gates on `.ready` rather than just polling `listener.port`.
        private var isReady = false

        init() throws {
            listener = try NWListener(using: .tcp)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.lock.lock()
                    self?.isReady = true
                    self?.lock.unlock()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.lock()
                self._acceptTimestamps.append(Date())
                self.lock.unlock()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed:
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: self.queue)
            }
        }

        func start() async throws -> UInt16 {
            listener.start(queue: queue)
            for _ in 0..<100 {
                lock.lock()
                let ready = isReady
                lock.unlock()
                if ready, let port = listener.port, port.rawValue != 0 {
                    return port.rawValue
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NSError(domain: "FlakyListener", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }

        func stop() { listener.cancel() }

        func acceptTimestamps() -> [Date] {
            lock.lock(); defer { lock.unlock() }
            return _acceptTimestamps
        }
    }

    /// Collapses raw TCP accepts less than `attemptGapThreshold` apart into
    /// one logical connection attempt — same rationale/values as
    /// ChatWebSocketReconnectRegressionTests' `coalesce`.
    private let attemptGapThreshold: TimeInterval = 0.6

    private func coalesce(_ raw: [Date]) -> [Date] {
        var result: [Date] = []
        for ts in raw {
            if let last = result.last, ts.timeIntervalSince(last) < attemptGapThreshold {
                continue
            }
            result.append(ts)
        }
        return result
    }

    @MainActor
    func test_handleAppBackgrounded_stopsReconnectAttempts_handleAppForegrounded_resumesThem() async throws {
        let listener = try FlakyListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"

        let vm = ChatThreadViewModel()
        let contact = FSContact(id: "peer-1", name: "Test Friend", type: .friend)
        await vm.load(service: service, contact: contact, userId: "test-user")

        // Phase 1: let the always-failing listener drive at least 2 logical
        // connection attempts, proving the reconnect loop is actually active
        // before we try to stop it.
        let phase1Deadline = Date().addingTimeInterval(8.0)
        var attempts = coalesce(listener.acceptTimestamps())
        while attempts.count < 2 && Date() < phase1Deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            attempts = coalesce(listener.acceptTimestamps())
        }
        XCTAssertGreaterThanOrEqual(
            attempts.count, 2,
            "precondition failed: expected the reconnect loop to already be retrying " +
            "before testing that backgrounding stops it. Got \(attempts.count) attempt(s)."
        )

        // Phase 2: background the chat. This must reuse disconnect()'s
        // isDisconnecting guard, which makes any in-flight/future
        // scheduleReconnect() call no-op instead of continuing to retry.
        vm.handleAppBackgrounded()
        let countAtBackground = coalesce(listener.acceptTimestamps()).count

        // Observe for a window comfortably longer than this backoff schedule
        // would need to produce at least one more attempt if backgrounding
        // had NOT stopped it (next gaps are ~1s/2s/4s...) — if the bug
        // regressed, attempts.count would keep climbing here.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let countAfterBackgroundWindow = coalesce(listener.acceptTimestamps()).count

        XCTAssertEqual(
            countAfterBackgroundWindow, countAtBackground,
            "handleAppBackgrounded() must stop further (re)connection attempts — before this " +
            "fix, only onDisappear closed the socket, so a backgrounded-but-still-mounted chat " +
            "kept retrying/registering with the server, which is exactly the stale-registered-" +
            "socket condition that suppressed push notifications. Attempts grew from " +
            "\(countAtBackground) to \(countAfterBackgroundWindow) while backgrounded."
        )

        // Phase 3: foreground the chat again — this must actually resume
        // connecting, not leave the socket closed until the view itself is
        // torn down and recreated.
        vm.handleAppForegrounded()

        let phase3Deadline = Date().addingTimeInterval(8.0)
        var afterForeground = coalesce(listener.acceptTimestamps())
        while afterForeground.count <= countAfterBackgroundWindow && Date() < phase3Deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            afterForeground = coalesce(listener.acceptTimestamps())
        }

        XCTAssertGreaterThan(
            afterForeground.count, countAfterBackgroundWindow,
            "handleAppForegrounded() must resume connection attempts after a prior " +
            "handleAppBackgrounded() call — got \(afterForeground.count) logical attempt(s), " +
            "expected more than the \(countAfterBackgroundWindow) observed before foregrounding."
        )

        vm.disconnect()

        // Settle window before returning: this test drives real loopback
        // sockets/timers for several seconds, and NWListener/URLSessionTask
        // teardown (stop()/cancel() above) completes asynchronously on their
        // own background queues. Without a brief pause here, that teardown
        // work can still be executing when the *next* test suite in the same
        // process starts — observed directly as flaky failures in
        // ChatWebSocketReconnectRegressionTests' own tight backoff-ratio
        // assertions when run immediately after this one, even though that
        // test passes reliably in isolation. This mirrors the "brief settle
        // window" precedent already used in
        // ChatWebSocketReconnectRegressionTests.coalesce's own post-loop
        // pause, just applied at the suite-teardown boundary instead of
        // mid-test.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}
