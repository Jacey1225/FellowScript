// TranscriptRelayTests.swift — task 20261013-session-call-live-transcript-summary
// (testing gate). Covers the SDK-free pieces: segment extraction, join-state
// parsing (consent/relay signals, fail closed), ChimeJoinResponse decoding of
// the new optional fields, and the TranscriptRelay controller semantics
// (relay-only buffering, batching, requeue, role loss, stop ordering).

import XCTest
@testable import FellowScript

private final class MockTranscriptService: TranscriptRelayServiceProtocol {
    var statusResults: [TranscriptStatusResult] = []
    var ingestResults: [TranscriptIngestResult] = []
    private(set) var statusCalls = 0
    private(set) var ingestBatches: [[TranscriptSegment]] = []
    private(set) var events: [String] = []
    var ingestDelayNanos: UInt64 = 0

    func transcriptRelayStatus(userId: String, sessionId: String) async -> TranscriptStatusResult {
        statusCalls += 1; events.append("status")
        return statusResults.isEmpty ? .unreachable : statusResults.removeFirst()
    }
    func transcriptIngest(userId: String, sessionId: String, segments: [TranscriptSegment]) async -> TranscriptIngestResult {
        events.append("ingest")
        ingestBatches.append(segments)
        if ingestDelayNanos > 0 { try? await Task.sleep(nanoseconds: ingestDelayNanos) }
        return ingestResults.isEmpty ? .accepted : ingestResults.removeFirst()
    }
    func transcriptLeave(userId: String, sessionId: String) async { events.append("leave") }
}

private func fin(_ text: String, _ speaker: String? = "u1") -> TranscriptResultInput {
    TranscriptResultInput(isPartial: false, text: text, speakerId: speaker)
}

final class TranscriptSegmentsTests: XCTestCase {
    func test_keepsFinalOnly_withSpeaker() {
        let out = TranscriptSegments.from([
            TranscriptResultInput(isPartial: true, text: "partial", speakerId: "u1"),
            fin("hello there", "u1"),
        ])
        XCTAssertEqual(out, [TranscriptSegment(speakerId: "u1", text: "hello there")])
    }

    func test_dropsBlank_andContentShareSpeaker() {
        XCTAssertTrue(TranscriptSegments.from([fin("   ")]).isEmpty)
        XCTAssertEqual(TranscriptSegments.from([fin("x", "u1#content")]), [TranscriptSegment(speakerId: nil, text: "x")])
        XCTAssertEqual(TranscriptSegments.from([fin("x", "")]), [TranscriptSegment(speakerId: nil, text: "x")])
    }

    func test_splitsLongTextToServerCap() {
        let out = TranscriptSegments.from([fin(String(repeating: "a", count: 2500))])
        XCTAssertEqual(out.map { $0.text.count }, [1000, 1000, 500])
        XCTAssertTrue(out.allSatisfy { $0.speakerId == "u1" })
    }

    func test_consentCopy_statesTranscriptionAndSummaryOnly() {
        XCTAssertTrue(TranscriptCopy.consent.lowercased().contains("transcribed"))
        XCTAssertTrue(TranscriptCopy.consent.contains("Only the summary is saved"))
    }
}

final class TranscriptJoinStateTests: XCTestCase {
    private func decode(_ json: String) throws -> ChimeJoinResponse {
        try JSONDecoder().decode(ChimeJoinResponse.self, from: Data(json.utf8))
    }
    private let base = """
    "Meeting": {"MeetingId": "m1", "MediaRegion": "us-east-1", "MediaPlacement": {"AudioHostUrl": "a", "AudioFallbackUrl": "b", "SignalingUrl": "c", "TurnControlUrl": "d", "EventIngestionUrl": "e"}},
    "Attendee": {"AttendeeId": "at1", "ExternalUserId": "u1", "JoinToken": "t"}
    """

    func test_responseWithoutFields_decodes_andMeansOff() throws {
        let r = try decode("{ \(base) }")
        XCTAssertNil(r.transcription_active)
        XCTAssertNil(TranscriptJoinState(r), "a room's meeting / older server: no banner, no relay")
    }

    func test_responseWithFields_decodes() throws {
        let r = try decode("{ \(base), \"transcription_active\": true, \"transcript_relay\": true, \"transcript_poll_seconds\": 15 }")
        let s = try XCTUnwrap(TranscriptJoinState(r))
        XCTAssertEqual(s, TranscriptJoinState(active: true, relay: true, pollSeconds: 15))
    }

    func test_relayNeverTrueWhenInactive() throws {
        XCTAssertFalse(TranscriptJoinState(active: false, relay: true, pollSeconds: 15).relay)
        let r = try decode("{ \(base), \"transcription_active\": false, \"transcript_relay\": true, \"transcript_poll_seconds\": 15 }")
        XCTAssertEqual(TranscriptJoinState(r)?.relay, false)
    }

    func test_negativePollClampedToZero() {
        XCTAssertEqual(TranscriptJoinState(active: true, relay: false, pollSeconds: -4).pollSeconds, 0)
    }
}

@MainActor
final class TranscriptRelayControllerTests: XCTestCase {
    private func make(_ svc: MockTranscriptService, active: Bool = true, relay: Bool = true,
                      poll: TimeInterval = 60, flush: TimeInterval = 0.05) -> TranscriptRelay {
        TranscriptRelay(service: svc, userId: "u1", sessionId: "s1",
                        initial: TranscriptJoinState(active: active, relay: relay, pollSeconds: 0),
                        pollInterval: poll, flushInterval: flush)
    }
    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    func test_nonRelay_neverBuffersOrIngests() async {
        let svc = MockTranscriptService()
        let r = make(svc, relay: false)
        r.start()
        r.handle([fin("secret words")])
        XCTAssertEqual(r.bufferedCount, 0)
        await wait(0.3)
        XCTAssertTrue(svc.ingestBatches.isEmpty)
        await r.stop()
    }

    func test_relay_batchesAndSends() async {
        let svc = MockTranscriptService()
        let r = make(svc)
        r.start()
        r.handle([fin("one", "u1")]); r.handle([fin("two", "u2")])
        await wait(0.4)
        XCTAssertEqual(svc.ingestBatches.count, 1)
        XCTAssertEqual(svc.ingestBatches.first?.map(\.text), ["one", "two"])
        XCTAssertEqual(r.bufferedCount, 0)
        await r.stop()
    }

    func test_atMost40SegmentsPerRequest() async {
        let svc = MockTranscriptService()
        let r = make(svc)
        r.start()
        for i in 0..<100 { r.handle([fin("s\(i)")]) }
        await wait(0.2)
        XCTAssertEqual(svc.ingestBatches.first?.count, 40)
        await r.stop()
    }

    func test_retryLater_requeuesWithoutLoss() async {
        let svc = MockTranscriptService()
        svc.ingestResults = [.retryLater, .accepted]
        let r = make(svc)
        r.start()
        r.handle([fin("keep me")])
        await wait(0.6)
        XCTAssertEqual(svc.ingestBatches.count, 2)
        XCTAssertEqual(svc.ingestBatches[1].map(\.text), ["keep me"])
        XCTAssertEqual(r.bufferedCount, 0)
        await r.stop()
    }

    func test_notRelay_dropsRoleAndRechecksStatusImmediately() async {
        let svc = MockTranscriptService()
        svc.ingestResults = [.notRelay]
        svc.statusResults = [.ok(TranscriptRelayStatus(transcription_active: true, transcript_relay: false, poll_seconds: 15))]
        let r = make(svc)
        var changes: [(Bool, Bool)] = []
        r.onStatus = { changes.append(($0, $1)) }
        r.start()
        r.handle([fin("x")])
        await wait(0.5)
        XCTAssertFalse(r.isRelay)
        XCTAssertEqual(r.bufferedCount, 0)
        XCTAssertGreaterThanOrEqual(svc.statusCalls, 1, "status re-check does not wait for the 60 s poll")
        r.handle([fin("after")])
        XCTAssertEqual(r.bufferedCount, 0)
        XCTAssertTrue(changes.contains(where: { $0.0 == true && $0.1 == false }))
        await r.stop()
    }

    func test_dropped_isNotRetried() async {
        let svc = MockTranscriptService()
        svc.ingestResults = [.dropped]
        let r = make(svc)
        r.start()
        r.handle([fin("x")])
        await wait(0.5)
        XCTAssertEqual(svc.ingestBatches.count, 1)
        XCTAssertEqual(r.bufferedCount, 0)
        await r.stop()
    }

    func test_pollPromotesToRelay_andBannerFlagFlipsAfterJoin() async {
        let svc = MockTranscriptService()
        svc.statusResults = [.ok(TranscriptRelayStatus(transcription_active: true, transcript_relay: true, poll_seconds: 1))]
        let r = make(svc, active: false, relay: false, poll: 0.05)
        var last: (Bool, Bool)?
        r.onStatus = { last = ($0, $1) }
        r.start()
        await wait(0.4)
        XCTAssertEqual(last?.0, true)
        XCTAssertEqual(last?.1, true)
        r.handle([fin("mine now")])
        XCTAssertEqual(r.bufferedCount, 1)
        await r.stop()
    }

    func test_featureOff404_clearsStateAndStopsPolling() async {
        let svc = MockTranscriptService()
        svc.statusResults = [.featureOff]
        let r = make(svc, poll: 0.05)
        r.start()
        await wait(0.5)
        XCTAssertFalse(r.isActive); XCTAssertFalse(r.isRelay)
        XCTAssertEqual(svc.statusCalls, 1, "no more polls once the server says the feature is off")
        await r.stop()
    }

    func test_stopWithFlush_sendsTailBeforeLeave_thenIgnoresEvents() async {
        let svc = MockTranscriptService()
        let r = make(svc, flush: 30)   // flush timer would never fire on its own
        r.start()
        r.handle([fin("tail words")])
        await r.stop(flushRemaining: true)
        XCTAssertEqual(svc.events.filter { $0 != "status" }, ["ingest", "leave"])
        r.handle([fin("late")])
        XCTAssertEqual(r.bufferedCount, 0)
    }

    func test_stopOnNeverActiveClient_doesNotSendLeave() async {
        let svc = MockTranscriptService()
        let r = make(svc, active: false, relay: false)
        r.start()
        await r.stop()
        XCTAssertFalse(svc.events.contains("leave"))
    }

    func test_stopFlush_isBoundedWhenServerHangs() async {
        let svc = MockTranscriptService()
        svc.ingestDelayNanos = 20_000_000_000
        let r = make(svc, flush: 30)
        r.start()
        r.handle([fin("x")])
        var finishedAt: TimeInterval?
        let began = Date()
        let stopTask = Task { @MainActor in
            await r.stop(flushRemaining: true)
            finishedAt = Date().timeIntervalSince(began)
        }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let boundedWithin6s = finishedAt != nil
        stopTask.cancel()
        XCTAssertTrue(boundedWithin6s, "stop(flushRemaining:) must not wait on a hung server beyond ~3 s (finishedAt=\(String(describing: finishedAt)))")
    }

    func test_bufferIsBounded() async {
        let svc = MockTranscriptService()
        svc.ingestDelayNanos = 5_000_000_000
        let r = make(svc, flush: 30)
        r.start()
        for i in 0..<600 { r.handle([fin("s\(i)")]) }
        XCTAssertLessThanOrEqual(r.bufferedCount, TranscriptRelay.maxBuffered)
        await r.stop()
    }
}
