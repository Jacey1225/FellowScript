// AgentChatReconnectRegressionTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, backend step 11 finding #3 /
// frontend step 12 fix.
//
// Before the fix, AgentChatViewModel.receiveLoop() (Chat/AgentChatView.swift)
// only re-armed itself inside the `.success` branch of wsTask.receive() — on
// `.failure` (dropped connection, backgrounding, idle-timeout) the closure
// just returned and the agent chat silently stopped receiving replies for
// the rest of that view's lifetime, with no reconnect attempt or visible
// error state. This is the same "unresponsive stateful WS channel" pattern
// backend step 8 / frontend step 9 fixed for ChatThreadViewModel (the
// messaging WS) — this test mirrors ChatWebSocketReconnectRegressionTests'
// approach for that fix, applied to the agent WS.
//
// The fix added scheduleReconnect() (capped exponential backoff: 1s, 2s,
// 4s, ... capped at 30s) invoked from receiveLoop()'s `.failure` case, plus
// a published `isConnected` flag surfaced as a "Reconnecting…" banner.
//
// Uses a real (loopback) NWListener that accepts each raw TCP connection and
// resets it before completing a valid WebSocket handshake — the same
// technique ChatWebSocketReconnectRegressionTests uses, since
// URLSessionWebSocketTask isn't mockable/injectable and doesn't route
// through custom URLProtocol subclasses (unlike NetworkService's plain HTTP
// calls). This deterministically drives `.failure` on every connection
// attempt without needing full RFC 6455 framing — this test observes retry
// timing, not message payloads.
//
// What this proves:
//   1. A connection failure triggers at least one further connection
//      attempt (previously: exactly one attempt, ever).
//   2. Consecutive retries are spaced with growing delays (capped
//      exponential backoff), not an immediate busy-loop.
//   3. `isConnected` reflects the failed/reconnecting state.
//
// Caveat: timing-sensitive (loopback jitter), and like every other WS/
// network-timing regression test in this pipeline (steps 10, 12), cannot
// actually be executed in this environment — no Xcode/simulator available
// (xcodebuild/xcrun simctl absent). Verified via `swiftc -parse` only; run
// with `xcodebuild test` once Xcode is available.

import XCTest
import Network
@testable import FellowScript

final class AgentChatReconnectRegressionTests: XCTestCase {

    /// Same flaky-listener technique as ChatWebSocketReconnectRegressionTests
    /// — duplicated locally (rather than shared) to keep each regression test
    /// file independently runnable/removable per this project's per-bug test
    /// file convention.
    final class FlakyListener {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "agent-chat-reconnect-test.listener")
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

    @MainActor
    func test_agentChatViewModel_retriesWithGrowingBackoff_afterEachConnectionFailure() async throws {
        let listener = try FlakyListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"

        let vm = AgentChatViewModel()
        await vm.load(service: service, agentId: "agent-1", userId: "test-user")

        // Let the reconnect loop run through several failure -> backoff ->
        // retry cycles: ~1s, then ~2s between attempts. ~4.5s should observe
        // at least 3 attempts.
        try await Task.sleep(nanoseconds: 4_500_000_000)

        vm.disconnect()

        let timestamps = listener.acceptTimestamps()
        XCTAssertGreaterThanOrEqual(
            timestamps.count, 3,
            "AgentChatViewModel must keep retrying the WebSocket connection after each failure. " +
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

        XCTAssertFalse(
            vm.isConnected,
            "isConnected should reflect the failed/reconnecting state; before the fix this publisher didn't exist at all"
        )
    }
}
