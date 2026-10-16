// CallTranscriptionDiagnosticsRegressionTests.swift — testing gate for task
// 20261015-call-transcription-start-and-diagnostics (build 123 diagnostics).
//
// Covers: TranscriptionStatus handling classes, counters, fixed-string beacon
// body, relay-side ingest counters, the specific no-content-422 toast
// selection, deferred-retry error handling (now reports; cancellation silent),
// the paywall path staying first (pinned in source; runtime in CallControllerSummarizeDiagnosticsRegressionTests), and source pins for the observer/beacon
// wiring that lives behind `private`/SDK-only code in ChimeCallView.swift.

import XCTest
@testable import FellowScript

private final class DiagTranscriptService: TranscriptRelayServiceProtocol {
    var ingestResults: [TranscriptIngestResult] = []
    func transcriptRelayStatus(userId: String, sessionId: String) async -> TranscriptStatusResult { .unreachable }
    func transcriptIngest(userId: String, sessionId: String, segments: [TranscriptSegment]) async -> TranscriptIngestResult {
        ingestResults.isEmpty ? .accepted : ingestResults.removeFirst()
    }
    func transcriptLeave(userId: String, sessionId: String) async {}
}

private func fin(_ text: String) -> TranscriptResultInput {
    TranscriptResultInput(isPartial: false, text: text, speakerId: "u1")
}

// MARK: - Pure value logic

final class TranscriptDiagnosticsTests: XCTestCase {

    func test_reasonClass_mapsToFixedClasses_andDropsRawText() {
        XCTAssertEqual(TranscriptDiagnostics.reasonClass(nil), "none")
        XCTAssertEqual(TranscriptDiagnostics.reasonClass(""), "none")
        XCTAssertEqual(TranscriptDiagnostics.reasonClass("AccessDeniedException: not allowed"), "access-denied")
        XCTAssertEqual(TranscriptDiagnostics.reasonClass("Unsupported language code"), "language")
        XCTAssertEqual(TranscriptDiagnostics.reasonClass("Rate limit exceeded"), "limit")
        XCTAssertEqual(TranscriptDiagnostics.reasonClass("connection timed out"), "network")
        let raw = "Something about Pastor Bob's private prayer request"
        XCTAssertEqual(TranscriptDiagnostics.reasonClass(raw), "other")
        let allowed: Set<String> = ["none", "access-denied", "language", "limit", "network", "other"]
        XCTAssertTrue(allowed.contains(TranscriptDiagnostics.reasonClass(raw)))
    }

    func test_record_countsEachStatusKind_andKeepsFailureClass() {
        var d = TranscriptDiagnostics()
        d.record(status: .started, reason: "none")
        d.record(status: .started, reason: "none")
        d.record(status: .stopped, reason: "none")
        d.record(status: .failed, reason: "access-denied")
        d.record(status: .interrupted, reason: "network")
        d.record(status: .resumed, reason: "none")
        d.record(status: .unknown, reason: "other")
        XCTAssertEqual(d.statusStarted, 2)
        XCTAssertEqual(d.statusStopped, 1)
        XCTAssertEqual(d.statusFailed, 1)
        XCTAssertEqual(d.statusInterrupted, 1)
        XCTAssertEqual(d.statusResumed, 1)
        XCTAssertEqual(d.lastFailureClass, "network", "interrupted after failed overwrites with the latest class")
    }

    func test_wasActive() {
        XCTAssertFalse(TranscriptDiagnostics().wasActive, "no summary beacon for a call that never had transcription")
        var a = TranscriptDiagnostics(); a.joinActive = true
        XCTAssertTrue(a.wasActive)
        var b = TranscriptDiagnostics(); b.statusStarted = 1
        XCTAssertTrue(b.wasActive)
        var c = TranscriptDiagnostics(); c.sawRelay = true
        XCTAssertTrue(c.wasActive)
    }

    func test_transcriptionProducedNothing() {
        XCTAssertTrue(TranscriptDiagnostics().transcriptionProducedNothing, "never started")
        var failed = TranscriptDiagnostics(); failed.joinActive = true; failed.statusStarted = 1; failed.statusFailed = 1
        XCTAssertTrue(failed.transcriptionProducedNothing, "failed status")
        var relayNoText = TranscriptDiagnostics(); relayNoText.joinActive = true; relayNoText.sawRelay = true
        XCTAssertTrue(relayNoText.transcriptionProducedNothing, "was relay, server accepted nothing")
        var healthyRelay = relayNoText; healthyRelay.ingestAccepted = 3
        XCTAssertFalse(healthyRelay.transcriptionProducedNothing)
        var healthyNonRelay = TranscriptDiagnostics(); healthyNonRelay.joinActive = true; healthyNonRelay.statusStarted = 1
        XCTAssertFalse(healthyNonRelay.transcriptionProducedNothing, "non-relay attendee cannot judge; stays generic")
    }

    func test_merged_addsRelayCounters_keepsObserverFields() {
        var base = TranscriptDiagnostics()
        base.observerRegistered = true; base.eventsReceived = 7; base.joinActive = true
        var relay = TranscriptDiagnostics()
        relay.sawRelay = true; relay.segmentsQueued = 5; relay.ingestAccepted = 2
        relay.ingestNotRelay = 1; relay.ingestRetryLater = 3; relay.ingestDropped = 4
        let m = base.merged(with: relay)
        XCTAssertTrue(m.observerRegistered); XCTAssertEqual(m.eventsReceived, 7); XCTAssertTrue(m.joinActive)
        XCTAssertTrue(m.sawRelay)
        XCTAssertEqual([m.segmentsQueued, m.ingestAccepted, m.ingestNotRelay, m.ingestRetryLater, m.ingestDropped], [5, 2, 1, 3, 4])
        XCTAssertEqual(base.merged(with: nil), base)
    }

    func test_summaryString_isFixedFormat_countsAndClassesOnly() {
        var d = TranscriptDiagnostics()
        d.joinActive = true; d.observerRegistered = true; d.eventsReceived = 12; d.finalResults = 9
        d.segmentsQueued = 9; d.ingestAccepted = 4; d.statusStarted = 1; d.statusFailed = 1; d.lastFailureClass = "access-denied"
        let s = d.summaryString
        XCTAssertEqual(s, "joinActive=1 joinRelay=0 sawRelay=0 observer=1 events=12 finalResults=9 eventsNotRelay=0 "
            + "queued=9 ingestOk=4 ingestNotRelay=0 ingestRetry=0 ingestDropped=0 stStarted=1 stStopped=0 stFailed=1 "
            + "stInterrupted=0 stResumed=0 failure=access-denied")
        // Every token is key=<int or fixed word>; nothing free-form.
        for token in s.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.count, 2, "token \(token)")
            XCTAssertTrue(Int(parts[1]) != nil || ["none", "access-denied", "language", "limit", "network", "other"].contains(parts[1]),
                          "token \(token) must be an integer or a fixed class")
        }
    }
}

// MARK: - Toast selection

final class SummarizeNoticeCopyTests: XCTestCase {
    private let r422 = "no-summarizable-content-422"

    func test_noContent422_andTranscriptionNeverStarted_showsSpecificToast() {
        XCTAssertEqual(SummarizeNoticeCopy.text(errorClass: r422, diagnostics: TranscriptDiagnostics()),
                       "We couldn't hear enough of the call to write a summary.")
    }

    func test_noContent422_andTranscriptionFailed_showsSpecificToast() {
        var d = TranscriptDiagnostics(); d.joinActive = true; d.statusStarted = 1; d.statusFailed = 1
        XCTAssertEqual(SummarizeNoticeCopy.text(errorClass: r422, diagnostics: d), SummarizeNoticeCopy.notHeard)
    }

    func test_noContent422_relayAcceptedNothing_showsSpecificToast() {
        var d = TranscriptDiagnostics(); d.joinActive = true; d.statusStarted = 1; d.sawRelay = true
        XCTAssertEqual(SummarizeNoticeCopy.text(errorClass: r422, diagnostics: d), SummarizeNoticeCopy.notHeard)
    }

    func test_noContent422_butTranscriptionHealthy_staysGeneric() {
        var d = TranscriptDiagnostics(); d.joinActive = true; d.statusStarted = 1
        XCTAssertEqual(SummarizeNoticeCopy.text(errorClass: r422, diagnostics: d), SummarizeNoticeCopy.generic)
        d.sawRelay = true; d.ingestAccepted = 2
        XCTAssertEqual(SummarizeNoticeCopy.text(errorClass: r422, diagnostics: d), SummarizeNoticeCopy.generic)
    }

    func test_otherErrorClasses_alwaysGeneric_evenWhenTranscriptionNeverRan() {
        for cls in ["llm-generation-502", "not-group-member-403", "notes-cap-403", "AppError.networkError", "URLError"] {
            XCTAssertEqual(SummarizeNoticeCopy.text(errorClass: cls, diagnostics: TranscriptDiagnostics()),
                           SummarizeNoticeCopy.generic, cls)
        }
    }

    func test_genericCopy_isUnchanged() {
        XCTAssertEqual(SummarizeNoticeCopy.generic,
                       "We couldn't put together your session summary this time — check back in your notes in a bit.")
    }
}

// MARK: - Relay-side ingest counters

@MainActor
final class TranscriptRelayDiagnosticsCounterTests: XCTestCase {
    private func make(_ svc: DiagTranscriptService, relay: Bool = true) -> TranscriptRelay {
        TranscriptRelay(service: svc, userId: "u1", sessionId: "s1",
                        initial: TranscriptJoinState(active: true, relay: relay, pollSeconds: 0),
                        pollInterval: 60, flushInterval: 0.05)
    }
    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    func test_relayAtStart_setsSawRelay_andCountsQueuedAndAccepted() async {
        let svc = DiagTranscriptService()
        let r = make(svc)
        r.start()
        XCTAssertTrue(r.diagnostics.sawRelay)
        r.handle([fin("one"), fin("two")])
        XCTAssertEqual(r.diagnostics.segmentsQueued, 2)
        await wait(0.4)
        XCTAssertEqual(r.diagnostics.ingestAccepted, 1)
        await r.stop()
    }

    func test_nonRelay_neverSawRelay_andQueuesNothing() async {
        let svc = DiagTranscriptService()
        let r = make(svc, relay: false)
        r.start()
        r.handle([fin("not mine")])
        XCTAssertFalse(r.diagnostics.sawRelay)
        XCTAssertEqual(r.diagnostics.segmentsQueued, 0)
        await r.stop()
    }

    func test_ingestOutcomes_eachIncrementOwnCounter() async {
        let svc = DiagTranscriptService()
        svc.ingestResults = [.retryLater, .dropped, .accepted, .notRelay]
        let r = make(svc)
        r.start()
        for i in 0..<4 { r.handle([fin("s\(i)")]); await wait(0.35) }
        let d = r.diagnostics
        XCTAssertEqual(d.ingestRetryLater, 1)
        XCTAssertEqual(d.ingestDropped, 1)
        XCTAssertGreaterThanOrEqual(d.ingestAccepted, 1)
        XCTAssertEqual(d.ingestNotRelay, 1)
        await r.stop()
    }
}

// MARK: - CallController toast + retry-error handling

@MainActor
final class CallControllerTranscriptionToastTests: XCTestCase {
    private let noContent = AppError.networkError("This session doesn't have any content to summarize.")

    override func tearDown() async throws {
        let call = CallController.shared
        call.session = nil; call.isExpanded = false; call.joinError = nil; call.summarizeNotice = nil
        try await super.tearDown()
    }

    private func service() -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.fetchAgentsResult = [FSAgent(id: "agent-1", user_id: "user-1", role: "", enabled: true, chats: [])]
        return s
    }

    private func session() -> FSSession {
        var s = FSSession()
        s.title = "Family Bible Study"; s.summarize = true; s.creator_id = "user-1"; s.group_id = "group-1"
        return s
    }

    /// Transcription never ran for this call + the no-content 422 -> specific toast.
    func test_end_noContent422_transcriptionNeverRan_showsSpecificToast() async throws {
        let svc = service()
        svc.summarizeSessionError = noContent
        let call = CallController.shared
        call.start(session: session(), service: svc, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(call.summarizeNotice, "We couldn't hear enough of the call to write a summary.")
    }

    /// Any other failure keeps the existing warm toast.
    func test_end_llm502_keepsGenericToast() async throws {
        let svc = service()
        svc.summarizeSessionError = AppError.networkError("Could not generate session summary.")
        let call = CallController.shared
        call.start(session: session(), service: svc, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(call.summarizeNotice, SummarizeNoticeCopy.generic)
    }

    /// Build 122 swallowed errors from the deferred retry (the missing 22:13 beacon).
    /// A non-cancellation error on the retry now reaches the shared failure handler
    /// and shows the toast. Real time: the retry delay is a private ~50 s constant.
    func test_end_deferredRetryThatFails422_nowReportsAndShowsToast() async throws {
        let svc = service()
        svc.summarizeDeferralScript = [true]
        svc.summarizeSessionErrorScript = [nil, noContent]
        let call = CallController.shared
        call.start(session: session(), service: svc, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(svc.summarizeDeferralCallTimes.count, 1)
        XCTAssertNil(call.summarizeNotice, "first (deferred) answer is silent")
        try await Task.sleep(nanoseconds: 53_000_000_000)
        XCTAssertEqual(svc.summarizeDeferralCallTimes.count, 2)
        XCTAssertEqual(call.summarizeNotice, SummarizeNoticeCopy.notHeard, "retry failure is no longer swallowed")
    }

    /// Cancellation on the retry stays silent (no toast).
    func test_end_deferredRetryCancelled_staysSilent() async throws {
        let svc = service()
        svc.summarizeDeferralScript = [true]
        svc.summarizeSessionErrorScript = [nil, CancellationError()]
        let call = CallController.shared
        call.start(session: session(), service: svc, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 54_000_000_000)
        XCTAssertEqual(svc.summarizeDeferralCallTimes.count, 2)
        XCTAssertNil(call.summarizeNotice, "cancellation is not reported")
    }
}

// MARK: - Source pins (SDK-only / private wiring)

final class TranscriptionDiagnosticsSourcePinTests: XCTestCase {
    private func source(_ rel: String) throws -> String {
        // #filePath: <repo>/FellowScript/FellowScriptTests/<this file>
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript").appendingPathComponent(rel)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_observer_handlesTranscriptionStatus_beforeTranscript_andDropsRawMessage() throws {
        let s = try source("Chat/ChimeCallView.swift")
        let status = try XCTUnwrap(s.range(of: "transcriptEvent as? TranscriptionStatus"))
        let transcript = try XCTUnwrap(s.range(of: "transcriptEvent as? Transcript else"))
        XCTAssertLessThan(status.lowerBound, transcript.lowerBound)
        XCTAssertTrue(s.contains("TranscriptDiagnostics.reasonClass(status.message)"))
        XCTAssertTrue(s.contains("recordTranscriptEvent(inputs)"))
        XCTAssertTrue(s.contains("maxStatusBeaconsPerCall = 4"))
    }

    func test_beacons_useFixedStrings_noMessageOrIds() throws {
        let s = try source("Chat/ChimeCallView.swift")
        XCTAssertTrue(s.contains("reportTranscriptionDiagnostic(stage: \"call-end\", summary: summary)"))
        XCTAssertTrue(s.contains("\"status=\\(name) reason=\\(reason)\""))
        XCTAssertFalse(s.contains("status.message)\")"), "raw SDK message must never be interpolated into a beacon/log")
        let n = try source("Services/NetworkService.swift")
        let body = try XCTUnwrap(n.range(of: "func reportTranscriptionDiagnostic"))
        let tail = String(n[body.lowerBound...].prefix(700))
        XCTAssertTrue(tail.contains("\"kind\": \"summarize\""))
        XCTAssertTrue(tail.contains("\"endpoint\": \"call transcription\""))
        XCTAssertFalse(tail.contains("sessionId")); XCTAssertFalse(tail.contains("userId"))
    }

    func test_summarizeRetryCatch_isNoLongerEmpty_andCancellationIsFiltered() throws {
        let s = try source("Chat/ChimeCallView.swift")
        XCTAssertFalse(s.contains("} catch { }"), "the swallow-all catch that hid the 22:13 failure must not return")
        let retry = try XCTUnwrap(s.range(of: "stage = \"summarize-retry\""))
        let tail = String(s[retry.lowerBound...].prefix(300))
        XCTAssertTrue(tail.contains("RefreshDiagnostics.isCancellation(error)"))
        XCTAssertTrue(tail.contains("handleSummarizeFailure"))
    }

    func test_paywallRunsBeforeDiagnosticsAndToast() throws {
        let s = try source("Chat/ChimeCallView.swift")
        let fn = try XCTUnwrap(s.range(of: "private func handleSummarizeFailure"))
        let body = String(s[fn.lowerBound...].prefix(1200))
        let paywall = try XCTUnwrap(body.range(of: "UpgradePromptCenter.shared.present(for: error)"))
        let diag = try XCTUnwrap(body.range(of: "RefreshDiagnostics.summarizeOutcome"))
        let toast = try XCTUnwrap(body.range(of: "showSummarizeNotice"))
        XCTAssertLessThan(paywall.lowerBound, diag.lowerBound)
        XCTAssertLessThan(diag.lowerBound, toast.lowerBound)
    }
}
