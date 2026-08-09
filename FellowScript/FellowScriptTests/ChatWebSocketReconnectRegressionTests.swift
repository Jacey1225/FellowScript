// ChatWebSocketReconnectRegressionTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, step 8 (backend) finding #2 /
// step 9 (frontend) fix.
//
// Before the fix, ChatThreadViewModel (ChatThreadView.swift) opened exactly
// one URLSessionWebSocketTask per thread view with no reconnect logic:
// receiveLoop() only re-armed itself inside the `.success` branch of
// wsTask.receive(); on `.failure` (network blip, backgrounding, an
// idle-timeout, or the server-side stale-socket eviction added by backend
// step 8's ConnectionManager fix) the closure just returned and receiveLoop
// was never called again — the thread silently stopped receiving live
// messages for the rest of that view's lifetime, with no visible error state
// and no attempt to recover. This is exactly the "unresponsive interaction on
// a stateful WS channel" pattern this audit was scoped to find.
//
// The fix added `scheduleReconnect()`, invoked from receiveLoop()'s
// `.failure` case, with capped exponential backoff (1s, 2s, 4s, ... capped at
// 30s) and a published `isConnected` flag surfaced as a "Reconnecting…"
// banner.
//
// This test proves the fix using a real (loopback) network path rather than
// mocking `URLSessionWebSocketTask` — that type can't be meaningfully
// subclassed/injected, and WebSocket tasks do not route through custom
// `URLProtocol` subclasses the way plain HTTP requests do (unlike the
// NetworkService REST tests in this target, which use StubURLProtocol). A
// minimal local `NWListener` stands in for the chat WS endpoint: it accepts
// each raw TCP connection and immediately resets it *without* completing a
// valid WebSocket handshake. That's sufficient to reliably drive
// `URLSessionWebSocketTask.receive()` into `.failure` on every attempt,
// without needing to implement full RFC 6455 framing (this test observes
// *retry timing*, not message payloads).
//
// What this proves:
//   1. A connection failure triggers at least one further connection
//      attempt (previously: exactly one attempt, ever — the bug this audit
//      caught).
//   2. Consecutive retries are spaced with growing delays (capped
//      exponential backoff), not an immediate busy-loop.
//   3. `isConnected` reflects the failed/reconnecting state (previously this
//      publisher didn't exist at all).
//
// Caveat: this test is timing-sensitive (loopback jitter) and, like the
// notes/highlights and auth/account regression suites (steps 4, 7, 9),
// cannot actually be executed in this environment — no Xcode/simulator is
// available (`xcodebuild`/`xcrun simctl` are absent; only command-line
// `swiftc`). Verified here via `swiftc -parse` only; run with
// `xcodebuild test` once Xcode is available.

import XCTest
import Network
@testable import FellowScript

final class ChatWebSocketReconnectRegressionTests: XCTestCase {

    /// Accepts raw TCP connections on an OS-assigned loopback port and resets
    /// each one immediately after the handshake completes, without ever
    /// returning a valid `HTTP/1.1 101 Switching Protocols` response. Records
    /// the timestamp of every accepted connection so the test can assert on
    /// retry cadence.
    final class FlakyListener {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "chat-ws-reconnect-test.listener")
        private var _acceptTimestamps: [Date] = []
        private let lock = NSLock()

        init() throws {
            listener = try NWListener(using: .tcp)
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

        /// Starts the listener and returns the OS-assigned port once bound.
        func start() async throws -> UInt16 {
            listener.start(queue: queue)
            for _ in 0..<100 {
                if let port = listener.port { return port.rawValue }
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

    func test_chatThreadViewModel_retriesWithGrowingBackoff_afterEachConnectionFailure() async throws {
        let listener = try FlakyListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"

        let vm = await ChatThreadViewModel()
        let contact = FSContact(id: "peer-1", name: "Test Friend", type: .friend)

        await vm.load(service: service, contact: contact, userId: "test-user")

        // Let the reconnect loop run through several failure -> backoff ->
        // retry cycles. The initial attempt fails almost instantly (loopback
        // reset); the fix's backoff schedules the next attempt after ~1s,
        // then ~2s. ~4.5s should be enough to observe at least 3 attempts.
        try await Task.sleep(nanoseconds: 4_500_000_000)

        await vm.disconnect()

        let timestamps = listener.acceptTimestamps()
        XCTAssertGreaterThanOrEqual(
            timestamps.count, 3,
            "ChatThreadViewModel must keep retrying the WebSocket connection after each failure. " +
            "Before the fix, receiveLoop()'s `.failure` case just returned and the socket never " +
            "reconnected again for the rest of the view's lifetime — only the single initial " +
            "attempt would show up here. Got \(timestamps.count) attempt(s)."
        )

        if timestamps.count >= 3 {
            let gap1 = timestamps[1].timeIntervalSince(timestamps[0])
            let gap2 = timestamps[2].timeIntervalSince(timestamps[1])
            XCTAssertGreaterThan(gap1, 0.4,
                "first retry should be delayed by the ~1s backoff, not immediate (busy-loop) — gap1=\(gap1)s")
            XCTAssertGreaterThan(gap2, gap1 * 1.2,
                "backoff between retries should grow (capped exponential), not stay constant — gap1=\(gap1)s gap2=\(gap2)s")
        }

        // Every attempt against this always-resetting listener fails, so
        // isConnected (the "Reconnecting…" banner's source of truth — see
        // frontend step 9) must be false by the time we stop observing.
        let isConnected = await vm.isConnected
        XCTAssertFalse(
            isConnected,
            "isConnected should reflect the failed/reconnecting state; before the fix this publisher didn't exist at all"
        )
    }
}
