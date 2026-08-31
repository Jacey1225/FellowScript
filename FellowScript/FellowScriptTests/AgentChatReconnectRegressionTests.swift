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

        // See ChatWebSocketReconnectRegressionTests.FlakyListener for why this
        // gates on `.ready` rather than just polling `listener.port`: that
        // property can briefly return a non-nil port 0 before the OS finishes
        // binding the real ephemeral port, which silently produces
        // "ws://127.0.0.1:0" and a 0-accept failure indistinguishable from
        // this test's other failure modes (e.g. an ATS block).
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

    @MainActor
    func test_agentChatViewModel_retriesWithGrowingBackoff_afterEachConnectionFailure() async throws {
        let listener = try FlakyListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"

        let vm = AgentChatViewModel()
        await vm.load(service: service, agentId: "agent-1", userId: "test-user")

        // Wait for at least 3 logical connection attempts (raw TCP accepts
        // coalesced across attemptGapThreshold-second bursts — see below),
        // polling instead of sleeping a single fixed duration.
        //
        // task 20260828-agent-chat-reconnect-backoff-flake: the old fixed
        // 4.5s window (the real backoff floor is 1s + 2s = 3s minimum
        // before a 3rd attempt) left too little slack to reliably survive
        // this sandbox's own CPU contention — the observed failure was
        // literally `attempts.count == 2` (a 3rd attempt existed, it just
        // hadn't landed by the deadline yet), not a wrong gap/ratio. This is
        // a recurrence of the exact residual flakiness already documented
        // for this same test in task 20260817-fix-preexisting-test-failures
        // ("11 clean / 3 failed" out of 14 isolated post-fix runs). Polling
        // up to a generous maxObservationWindow (instead of a single fixed
        // sleep) keeps the common-case runtime close to the old ~4.5s while
        // giving real headroom under contention, without weakening what the
        // test actually proves: it still requires >=3 real logical attempts
        // and a growing backoff below, it just no longer race-loses against
        // a too-tight fixed clock to observe the 3rd one.
        let attemptGapThreshold: TimeInterval = 0.6
        let maxObservationWindow: TimeInterval = 12.0
        let pollInterval: UInt64 = 200_000_000 // 0.2s

        // Raw accepts, coalesced into logical connection attempts. A single
        // logical connectWebSocket() call (initial connect or a
        // scheduleReconnect() retry) can produce a *burst* of several raw
        // TCP accepts on this listener within milliseconds of each other
        // (observed directly on the sibling
        // ChatWebSocketReconnectRegressionTests case: bursts of 2-4 accepts
        // spaced 5-16ms apart in a light-load run, but up to several
        // hundred ms apart under this sandbox's own CPU contention —
        // plausibly CFNetwork/URLSessionWebSocketTask racing or quickly
        // re-trying the raw socket connect internally before surfacing one
        // `.failure` up to the app). That burst noise is unrelated to the
        // app's own backoff and, if measured raw, makes gap1/gap2 read as
        // ~0s regardless of whether the production backoff logic is
        // correct. Collapsing consecutive accepts less than
        // `attemptGapThreshold` apart into one logical attempt (keeping the
        // first timestamp of each cluster — the moment that connection
        // attempt actually started) recovers the real attempt cadence. 0.6s
        // sits with real margin below the smallest real backoff delay (1s,
        // i.e. Task.sleep(1s) — that floor doesn't shrink under load, only
        // the burst spread and the observed real-delay overrun grow) while
        // still comfortably absorbing bursts observed to spread up to
        // ~0.4s under this sandbox's heavier contention.
        func coalesce(_ raw: [Date]) -> [Date] {
            var result: [Date] = []
            for ts in raw {
                if let last = result.last, ts.timeIntervalSince(last) < attemptGapThreshold {
                    continue // same burst as the previous logical attempt
                }
                result.append(ts)
            }
            return result
        }

        let deadline = Date().addingTimeInterval(maxObservationWindow)
        var attempts = coalesce(listener.acceptTimestamps())
        while attempts.count < 3 && Date() < deadline {
            try await Task.sleep(nanoseconds: pollInterval)
            attempts = coalesce(listener.acceptTimestamps())
        }
        // Brief settle window past the 3rd attempt so an in-flight burst
        // accept landing right after the loop exits doesn't get miscounted
        // as a spurious 4th logical attempt.
        try await Task.sleep(nanoseconds: 300_000_000)
        attempts = coalesce(listener.acceptTimestamps())

        vm.disconnect()

        let rawTimestamps = listener.acceptTimestamps()

        XCTAssertGreaterThanOrEqual(
            attempts.count, 3,
            "AgentChatViewModel must keep retrying the WebSocket connection after each failure. " +
            "Before the fix, receiveLoop()'s `.failure` case just returned and the socket never " +
            "reconnected again for the rest of the view's lifetime — only the single initial " +
            "attempt would show up here. Got \(attempts.count) logical attempt(s) " +
            "(from \(rawTimestamps.count) raw accepts) within \(maxObservationWindow)s."
        )

        if attempts.count >= 3 {
            let gap1 = attempts[1].timeIntervalSince(attempts[0])
            let gap2 = attempts[2].timeIntervalSince(attempts[1])
            XCTAssertGreaterThan(gap1, 0.4,
                "first retry should be delayed by the ~1s backoff, not immediate (busy-loop) — gap1=\(gap1)s")
            // 1.1x, not the "true" 2x the 1s/2s schedule implies — see
            // ChatWebSocketReconnectRegressionTests for why: this sandbox's
            // own CPU contention measurably inflates real scheduled delays
            // (e.g. an intended ~1s wait observed taking 1.7s), which
            // compresses the *measured* ratio between consecutive gaps
            // even when the underlying exponential backoff is working
            // correctly. 1.1x still sits with real margin above the
            // pre-fix bug's signature (every delay ~equal, ratio ~1.0).
            XCTAssertGreaterThan(gap2, gap1 * 1.1,
                "backoff between retries should grow (capped exponential), not stay constant — gap1=\(gap1)s gap2=\(gap2)s")
        }

        XCTAssertFalse(
            vm.isConnected,
            "isConnected should reflect the failed/reconnecting state; before the fix this publisher didn't exist at all"
        )
    }
}
