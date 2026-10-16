// Live-call transcript relay (task 20261013-session-call-live-transcript-summary).
//
// Chime delivers transcript events only to attendee clients. Exactly ONE
// client per call (the "relay", decided by the server and re-checked on every
// poll; clients cannot self-appoint) forwards FINAL text to
// POST /devotions/transcript/ingest so the summarize route can use it.
//
// No Amazon Chime SDK dependency: the SDK adapter lives in ChimeCallView.swift.
// Text is held in memory only: never persisted, never logged (only HTTP-level
// outcomes are), never shown in the UI.

import Foundation

enum TranscriptCopy {
    /// Consent banner shown to every participant while the main call is transcribed.
    static let consent = "This call is being transcribed to write the session summary. Only the summary is saved."
}

struct TranscriptSegment: Equatable {
    let speakerId: String?
    let text: String
}

/// One recognized result with the SDK types already stripped away.
struct TranscriptResultInput: Equatable {
    let isPartial: Bool
    let text: String
    let speakerId: String?
}

enum TranscriptSegments {
    static let maxSegmentChars = 1000   // server ingest_max_segment_chars

    /// Final results only; long text is split so every segment fits the server cap.
    static func from(_ results: [TranscriptResultInput], maxChars: Int = maxSegmentChars) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for r in results where !r.isPartial {
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let speaker = r.speakerId.flatMap { $0.isEmpty || $0.hasSuffix("#content") ? nil : $0 }
            var rest = Substring(text)
            while !rest.isEmpty {
                let chunk = rest.prefix(maxChars)
                out.append(TranscriptSegment(speakerId: speaker, text: String(chunk)))
                rest = rest.dropFirst(chunk.count)
            }
        }
        return out
    }
}

/// Chime TranscriptionStatus event kinds, SDK types stripped away.
enum TranscriptionStatusKind: Equatable {
    case started, stopped, failed, interrupted, resumed, unknown
}

/// Counters for one call's live transcription (task
/// 20261015-call-transcription-start-and-diagnostics). Counts and fixed class
/// strings only: no transcript text, no user or session ids, no server text.
struct TranscriptDiagnostics: Equatable {
    var joinActive = false          // join response said transcription is on
    var joinRelay = false           // join response designated this client the relay
    var sawRelay = false            // this client was the relay at some point
    var observerRegistered = false  // SDK accepted the transcript observer
    var eventsReceived = 0          // Transcript events delivered by the SDK
    var finalResults = 0            // non-partial results inside those events
    var eventsWhileNotRelay = 0     // events that arrived while not the relay
    var segmentsQueued = 0          // final segments buffered for ingest (relay only)
    var ingestAccepted = 0
    var ingestNotRelay = 0
    var ingestRetryLater = 0
    var ingestDropped = 0
    var statusStarted = 0
    var statusStopped = 0
    var statusFailed = 0
    var statusInterrupted = 0
    var statusResumed = 0
    var lastFailureClass = "none"

    /// Fixed reason classes; the SDK message itself is never recorded.
    static func reasonClass(_ message: String?) -> String {
        let m = (message ?? "").lowercased()
        if m.isEmpty { return "none" }
        if m.contains("access") || m.contains("denied") || m.contains("permission")
            || m.contains("unauthor") { return "access-denied" }
        if m.contains("language") { return "language" }
        if m.contains("limit") || m.contains("quota") || m.contains("throttl") { return "limit" }
        if m.contains("timeout") || m.contains("timed out") || m.contains("network")
            || m.contains("connect") { return "network" }
        return "other"
    }

    mutating func record(status: TranscriptionStatusKind, reason: String) {
        switch status {
        case .started:     statusStarted += 1
        case .stopped:     statusStopped += 1
        case .failed:      statusFailed += 1; lastFailureClass = reason
        case .interrupted: statusInterrupted += 1; lastFailureClass = reason
        case .resumed:     statusResumed += 1
        case .unknown:     break
        }
    }

    /// True when transcription was on for this call in any way we could see.
    var wasActive: Bool { joinActive || statusStarted > 0 || sawRelay }

    /// "We heard nothing usable": transcription never started, it failed, or this
    /// client was the relay and the server accepted no text.
    var transcriptionProducedNothing: Bool {
        if statusFailed > 0 { return true }
        if !joinActive && statusStarted == 0 { return true }
        return sawRelay && ingestAccepted == 0
    }

    func merged(with relay: TranscriptDiagnostics?) -> TranscriptDiagnostics {
        guard let relay else { return self }
        var out = self
        out.sawRelay = out.sawRelay || relay.sawRelay
        out.segmentsQueued += relay.segmentsQueued
        out.ingestAccepted += relay.ingestAccepted
        out.ingestNotRelay += relay.ingestNotRelay
        out.ingestRetryLater += relay.ingestRetryLater
        out.ingestDropped += relay.ingestDropped
        return out
    }

    /// Fixed-format beacon body: ints, 0/1 flags and fixed class names only.
    var summaryString: String {
        func b(_ v: Bool) -> Int { v ? 1 : 0 }
        return "joinActive=\(b(joinActive)) joinRelay=\(b(joinRelay)) sawRelay=\(b(sawRelay)) "
            + "observer=\(b(observerRegistered)) events=\(eventsReceived) finalResults=\(finalResults) "
            + "eventsNotRelay=\(eventsWhileNotRelay) queued=\(segmentsQueued) "
            + "ingestOk=\(ingestAccepted) ingestNotRelay=\(ingestNotRelay) "
            + "ingestRetry=\(ingestRetryLater) ingestDropped=\(ingestDropped) "
            + "stStarted=\(statusStarted) stStopped=\(statusStopped) stFailed=\(statusFailed) "
            + "stInterrupted=\(statusInterrupted) stResumed=\(statusResumed) failure=\(lastFailureClass)"
    }
}

enum SummarizeNoticeCopy {
    static let generic = "We couldn't put together your session summary this time — check back in your notes in a bit."
    static let notHeard = "We couldn't hear enough of the call to write a summary."

    /// The specific message only for the no-content 422 when transcription never
    /// ran, failed, or the relay got no text accepted; everything else stays generic.
    static func text(errorClass: String, diagnostics: TranscriptDiagnostics) -> String {
        if errorClass == "no-summarizable-content-422", diagnostics.transcriptionProducedNothing {
            return notHeard
        }
        return generic
    }
}

/// Transcription fields every join response carries. Missing means off (fail closed).
struct TranscriptJoinState: Equatable {
    let active: Bool
    let relay: Bool
    let pollSeconds: Int

    static let off = TranscriptJoinState(active: false, relay: false, pollSeconds: 0)

    init(active: Bool, relay: Bool, pollSeconds: Int) {
        self.active = active; self.relay = active && relay; self.pollSeconds = max(0, pollSeconds)
    }

    /// nil when the response carries no transcription fields (e.g. a discussion
    /// room's meeting): no banner, no relay.
    init?(_ response: ChimeJoinResponse) {
        guard let active = response.transcription_active else { return nil }
        self.init(active: active, relay: response.transcript_relay ?? false,
                  pollSeconds: response.transcript_poll_seconds ?? 0)
    }
}

struct TranscriptRelayStatus: Decodable, Equatable {
    let transcription_active: Bool
    let transcript_relay: Bool
    let poll_seconds: Int?
}

enum TranscriptStatusResult: Equatable {
    case ok(TranscriptRelayStatus)
    case featureOff        // 404: flag off server-side
    case unreachable       // network / 5xx / undecodable: keep last known state
}

enum TranscriptIngestResult: Equatable {
    case accepted
    case notRelay          // 403 / 404 / 409: not (or no longer) the relay, or transcription ended
    case retryLater        // 429 / 5xx / network
    case dropped           // 413 / 422: the server will never accept this batch
}

protocol TranscriptRelayServiceProtocol {
    func transcriptRelayStatus(userId: String, sessionId: String) async -> TranscriptStatusResult
    func transcriptIngest(userId: String, sessionId: String, segments: [TranscriptSegment]) async -> TranscriptIngestResult
    func transcriptLeave(userId: String, sessionId: String) async
}

@MainActor
final class TranscriptRelay {
    static let maxSegmentsPerRequest = 40   // server ingest_max_segments
    static let maxBuffered = 400
    static let stopFlushTimeout: TimeInterval = 3

    private let service: TranscriptRelayServiceProtocol
    private let userId: String
    private let sessionId: String
    private let flushInterval: TimeInterval
    private var pollInterval: TimeInterval

    private(set) var isActive = false
    private(set) var isRelay = false
    /// Relay-side counters (queued segments, ingest outcomes); merged into the call summary.
    private(set) var diagnostics = TranscriptDiagnostics()
    private var stopped = false
    private var inflight = false
    private var buffer: [TranscriptSegment] = []
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    /// (active, relay) changes; always called on the main actor.
    var onStatus: ((Bool, Bool) -> Void)?

    init(service: TranscriptRelayServiceProtocol, userId: String, sessionId: String,
         initial: TranscriptJoinState, pollInterval: TimeInterval = 15, flushInterval: TimeInterval = 3) {
        self.service = service; self.userId = userId; self.sessionId = sessionId
        self.flushInterval = flushInterval
        self.pollInterval = initial.pollSeconds > 0 ? TimeInterval(initial.pollSeconds) : pollInterval
        self.initial = initial
    }
    private let initial: TranscriptJoinState

    var bufferedCount: Int { buffer.count }

    func start() {
        stopped = false
        setStatus(active: initial.active, relay: initial.relay)
        schedulePoll(after: pollInterval)
    }

    /// Called for every transcript event on every client; only the relay buffers.
    func handle(_ results: [TranscriptResultInput]) {
        guard !stopped, isRelay else { return }
        let segs = TranscriptSegments.from(results)
        if segs.isEmpty { return }
        buffer.append(contentsOf: segs)
        diagnostics.segmentsQueued += segs.count
        if buffer.count > Self.maxBuffered { buffer.removeFirst(buffer.count - Self.maxBuffered) }
        scheduleFlush(after: flushInterval)
    }

    /// Optionally sends what is still buffered (bounded wait) so the summary
    /// sees the end of the call, then says goodbye so the role can move on.
    func stop(flushRemaining: Bool = false) async {
        if stopped { return }
        if flushRemaining, isRelay, !buffer.isEmpty {
            await drainWithinDeadline()
        }
        let wasActive = isActive || isRelay
        stopped = true
        pollTask?.cancel(); flushTask?.cancel()
        pollTask = nil; flushTask = nil
        buffer = []
        isActive = false; isRelay = false
        if wasActive { await service.transcriptLeave(userId: userId, sessionId: sessionId) }
    }

    // MARK: - Internals

    /// Drains the buffer but never waits past `stopFlushTimeout`, even when an
    /// ingest request hangs: the drain runs in its own task and is raced against
    /// a deadline task. Whichever finishes first resumes the caller; the loser is
    /// cancelled and not awaited.
    private func drainWithinDeadline() async {
        let timeout = Self.stopFlushTimeout
        let deadline = Date().addingTimeInterval(timeout)
        var drain: Task<Void, Never>?
        var timer: Task<Void, Never>?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            let finish: @MainActor () -> Void = {
                if resumed { return }
                resumed = true
                cont.resume()
            }
            drain = Task { @MainActor [weak self] in
                guard let self else { finish(); return }
                var passes = 0
                while self.isRelay, !self.buffer.isEmpty, passes < 5, Date() < deadline, !Task.isCancelled {
                    if self.inflight { try? await Task.sleep(nanoseconds: 20_000_000); continue }
                    passes += 1
                    await self.flush()
                }
                finish()
            }
            timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                finish()
            }
        }
        drain?.cancel(); timer?.cancel()
    }

    private func setStatus(active: Bool, relay: Bool) {
        let newRelay = active && relay
        let changed = active != isActive || newRelay != isRelay
        isActive = active; isRelay = newRelay
        if newRelay { diagnostics.sawRelay = true }
        if !isRelay { buffer = [] }
        if changed { onStatus?(isActive, isRelay) }
    }

    private func schedulePoll(after seconds: TimeInterval) {
        if stopped { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.poll()
        }
    }

    private func poll() async {
        if stopped { return }
        let result = await service.transcriptRelayStatus(userId: userId, sessionId: sessionId)
        if stopped { return }
        switch result {
        case .featureOff:
            setStatus(active: false, relay: false)   // flag off: stop polling for this call
            return
        case .ok(let status):
            if let secs = status.poll_seconds, secs > 0 { pollInterval = TimeInterval(secs) }
            setStatus(active: status.transcription_active, relay: status.transcript_relay)
        case .unreachable:
            break
        }
        schedulePoll(after: pollInterval)
    }

    private func scheduleFlush(after seconds: TimeInterval) {
        if stopped || flushTask != nil || !isRelay || buffer.isEmpty { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.runScheduledFlush()
        }
    }

    private func runScheduledFlush() async {
        flushTask = nil
        await flush()
    }

    private func flush() async {
        if stopped || inflight || !isRelay || buffer.isEmpty { return }
        inflight = true
        let batch = Array(buffer.prefix(Self.maxSegmentsPerRequest))
        buffer.removeFirst(batch.count)
        let result = await service.transcriptIngest(userId: userId, sessionId: sessionId, segments: batch)
        inflight = false
        if stopped { return }   // stop() gave up waiting on this request
        var retryDelay = flushInterval
        switch result {
        case .accepted:
            diagnostics.ingestAccepted += 1
        case .dropped:
            diagnostics.ingestDropped += 1
        case .notRelay:
            diagnostics.ingestNotRelay += 1
            // Re-check the role right away instead of waiting for the next tick.
            setStatus(active: isActive, relay: false)
            schedulePoll(after: 0)
        case .retryLater:
            diagnostics.ingestRetryLater += 1
            buffer = Array((batch + buffer).suffix(Self.maxBuffered))
            retryDelay = flushInterval * 2
        }
        scheduleFlush(after: retryDelay)
    }
}
