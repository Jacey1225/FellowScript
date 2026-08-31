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

        // Set true only once the listener's stateUpdateHandler reports
        // `.ready` — `listener.port` can return a non-nil-but-zero port
        // (NWEndpoint.Port(rawValue: 0), the ".any" placeholder passed to
        // NWListener's initializer) for a brief window *before* the OS has
        // actually assigned + bound the real ephemeral port. Polling
        // `listener.port` alone (without gating on `.ready`) can observe that
        // transient zero value and hand callers "port 0", which then fails
        // to connect with errno 49 ("Can't assign requested address") on
        // every attempt — indistinguishable from this test's other 0-accept
        // failure modes (e.g. an ATS block) unless you look at the actual
        // connect() error, which is exactly what happened here: this bug was
        // masked behind an ATS diagnosis until the ATS gap was fixed and this
        // race was the only thing left causing the same "Got 0 attempt(s)"
        // symptom.
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

        /// Starts the listener and returns the OS-assigned port once the
        /// listener is actually `.ready` with a non-zero bound port.
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

    func test_chatThreadViewModel_retriesWithGrowingBackoff_afterEachConnectionFailure() async throws {
        let listener = try FlakyListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let service = ThrowingTestDataService()
        service.wsBaseOverride = "ws://127.0.0.1:\(port)"

        let vm = await ChatThreadViewModel()
        let contact = FSContact(id: "peer-1", name: "Test Friend", type: .friend)

        await vm.load(service: service, contact: contact, userId: "test-user")

        // Wait for at least 3 logical connection attempts (raw TCP accepts
        // coalesced across attemptGapThreshold-second bursts — see below),
        // polling instead of sleeping a single fixed duration.
        //
        // task 20260828-agent-chat-reconnect-backoff-flake: preemptively
        // hardened here too (same flakiness class, same technique) after
        // the sibling AgentChatReconnectRegressionTests case hit it for
        // real — the old fixed 4.5s window (the real backoff floor is 1s +
        // 2s = 3s minimum before a 3rd attempt) left too little slack to
        // reliably survive this sandbox's own CPU contention. This is the
        // exact residual flakiness already documented for this test in task
        // 20260817-fix-preexisting-test-failures ("11 clean / 3 failed" out
        // of 14 isolated post-fix runs). Polling up to a generous
        // maxObservationWindow (instead of a single fixed sleep) keeps the
        // common-case runtime close to the old ~4.5s while giving real
        // headroom under contention, without weakening what the test
        // actually proves: it still requires >=3 real logical attempts and
        // a growing backoff below, it just no longer race-loses against a
        // too-tight fixed clock to observe the 3rd one.
        let attemptGapThreshold: TimeInterval = 0.6
        let maxObservationWindow: TimeInterval = 12.0
        let pollInterval: UInt64 = 200_000_000 // 0.2s

        // Raw accepts, coalesced into logical connection attempts. A single
        // logical `connectWebSocket()` call — the initial connect or a
        // scheduleReconnect() retry — can produce a *burst* of several raw
        // TCP accepts on this listener within milliseconds of each other
        // (observed directly: bursts of 2-4 accepts spaced 5-16ms apart in
        // a light-load run, but up to several hundred ms apart under this
        // sandbox's own CPU contention — plausibly CFNetwork/
        // URLSessionWebSocketTask racing or quickly re-trying the raw
        // socket connect internally before surfacing one `.failure` up to
        // the app). That burst noise is unrelated to the app's own backoff
        // and, if measured raw, makes gap1/gap2 read as ~0s regardless of
        // whether the production backoff logic is correct — confirmed by
        // instrumenting the raw gap sequence directly, e.g. [9ms, 9ms, 9ms,
        // 1034ms, 7ms, 6ms, 2012ms, 8ms, 7ms]: three within-burst accepts,
        // then a genuine ~1s backoff-driven gap, two more within-burst
        // accepts, then a genuine ~2s gap, etc. Collapsing consecutive
        // accepts less than `attemptGapThreshold` apart into one logical
        // attempt (keeping the first timestamp of each cluster, i.e. the
        // moment that connection attempt actually started) recovers the
        // real attempt cadence. 0.6s sits with real margin below the
        // smallest real backoff delay (1s, i.e. Task.sleep(1s) — that floor
        // doesn't shrink under load, only the burst spread and the
        // observed real-delay overrun grow) while still comfortably
        // absorbing bursts observed to spread up to ~0.4s under this
        // sandbox's heavier contention.
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

        await vm.disconnect()

        let rawTimestamps = listener.acceptTimestamps()

        XCTAssertGreaterThanOrEqual(
            attempts.count, 3,
            "ChatThreadViewModel must keep retrying the WebSocket connection after each failure. " +
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
            // 1.1x (not the "true" 2x the 1s/2s schedule implies) — this
            // sandbox's own CPU contention measurably inflates real
            // scheduled delays (e.g. an intended ~1s wait observed taking
            // 1.7s), which compresses the *measured* ratio between
            // consecutive gaps even when the underlying exponential
            // backoff is working correctly. 1.1x still sits with real
            // margin above the pre-fix bug's signature (every delay
            // ~equal, ratio ~1.0), so it stays a meaningful regression guard
            // without chasing precision this environment can't reliably
            // deliver.
            XCTAssertGreaterThan(gap2, gap1 * 1.1,
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
