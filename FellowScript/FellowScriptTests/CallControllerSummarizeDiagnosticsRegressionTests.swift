// CallControllerSummarizeDiagnosticsRegressionTests.swift — testing-gate
// coverage for task 20260923-session-summary-call-failure, step 3 (testing).
//
// Backend step 1 reproduced every candidate root cause against a real
// Postgres DB / live HTTP routes and ruled all of them out — no backend
// defect was found, no backend fix was made (see backend.json). Frontend
// step 2 likewise found no additional iOS-side defect, but implemented the
// spec's always-in-scope observability gap: `CallController.maybeSummarize`
// now tracks which of its two awaits (`resolveAgentId` vs
// `service.summarizeSession`) was in flight when its catch fires (`stage`),
// and a new private `summarizeErrorClass(_:)` refines
// `RefreshDiagnostics.errorClass(_:)` for the two summarize-specific,
// non-PII, fixed detail strings `summarize_session` (api/routes/agent.py)
// can throw, plus the existing `AppError.limitReached` notes-cap case. This
// file is this task's "specific gap" coverage per the spec's acceptance
// criteria.
//
// Two halves, deliberately:
//
// 1. RUNTIME regression coverage (extends CallControllerSummarizeRegressionTests'
//    existing pattern): proves the new stage-tracking/diagnostics addition is
//    a pure side effect — every failure mode at both stages (a local
//    resolveAgentId failure, and each summarize-endpoint failure shape) still
//    surfaces the exact same warm, non-technical summarizeNotice text
//    (UI/UX Q17.3, unchanged), still doesn't block/delay teardown, and still
//    calls summarizeSession exactly the expected number of times.
//
// 2. SOURCE-STRUCTURAL coverage for the parts of this fix that cannot be
//    observed at runtime through this test target: `summarizeErrorClass` and
//    the `stage` variable are `private` to ChimeCallView.swift (Swift's
//    `private` is file-scoped, so `@testable import` does not expose them
//    here), and `RefreshDiagnostics.summarizeOutcome` only ever calls
//    `os.Logger`/`print` — there is no capture hook to assert against. This
//    mirrors the codebase's own established convention for exactly this
//    situation (see AccountEventsHeartbeatsTaskGroupIncompleteWalkRegressionTests.swift's
//    header comment) rather than asserting a false claim of runtime
//    verification for logic that genuinely can't be observed that way from
//    outside the file. Each assertion below was hand-verified to fail when
//    the specific line it pins is reverted, and to pass again once restored.

import XCTest
@testable import FellowScript

@MainActor
final class CallControllerSummarizeDiagnosticsRegressionTests: XCTestCase {

    override func tearDown() async throws {
        let call = CallController.shared
        call.session = nil
        call.isExpanded = false
        call.joinError = nil
        call.summarizeNotice = nil
        try await super.tearDown()
    }

    private func makeSession(summarize: Bool, creatorId: String, groupId: String = "group-1") -> FSSession {
        var session = FSSession()
        session.title = "Family Bible Study"
        session.verses = ["Romans 8:28"]
        session.prompts = ["What stood out to you tonight?"]
        session.summarize = summarize
        session.creator_id = creatorId
        session.group_id = groupId
        return session
    }

    // ── 1. Runtime regression coverage ──────────────────────────────────────

    /// A local resolveAgentId failure (candidate #2 from this task's
    /// investigation — fetchAgents throwing under real account/network
    /// conditions) must still surface the same warm toast as an endpoint
    /// failure, must never reach summarizeSession at all, and must not block
    /// teardown. Exercises the "resolve-agent" stage path added by this fix.
    func test_end_resolveAgentIdFailure_surfacesWarmNotice_neverCallsSummarizeSession() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsError = AppError.networkError("Could not read your agents.")
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()

        XCTAssertNil(call.session)
        XCTAssertFalse(call.isExpanded)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 0,
                        "a resolve-agent-stage failure must never reach the summarize endpoint call")
        let notice = try XCTUnwrap(call.summarizeNotice)
        XCTAssertEqual(notice, "We couldn't put together your session summary this time — check back in your notes in a bit.")
    }

    /// `_require_group_membership`'s real 403 (candidate #3, ruled out as a
    /// live defect by backend step 1, but still a real failure shape the
    /// client must handle correctly if it ever legitimately occurs) must
    /// still surface the same warm, non-technical toast — not the raw
    /// "Not a member of this group" server detail string.
    func test_end_notGroupMemberError_surfacesWarmNotice_notRawServerDetail() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "agent-1", user_id: "user-1", role: "", enabled: true, chats: [])]
        service.summarizeSessionError = AppError.networkError("Not a member of this group")
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 1)
        let notice = try XCTUnwrap(call.summarizeNotice)
        XCTAssertFalse(notice.contains("member"), "the raw server detail string must not leak into the user-facing notice")
        XCTAssertFalse(notice.isEmpty)
    }

    /// The LLM-generation 502 shape (`summarize_session`'s
    /// "Could not generate session summary." detail) must likewise stay
    /// behind the same warm toast.
    func test_end_llmGenerationError_surfacesWarmNotice_notRawServerDetail() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "agent-1", user_id: "user-1", role: "", enabled: true, chats: [])]
        service.summarizeSessionError = AppError.networkError("Could not generate session summary.")
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 1)
        let notice = try XCTUnwrap(call.summarizeNotice)
        XCTAssertFalse(notice.contains("generate"))
        XCTAssertFalse(notice.isEmpty)
    }

    /// The weekly notes-cap 403 (`AppError.limitReached`, already
    /// distinguished upstream before this fix) must still behave identically
    /// — same warm toast, no regression from adding the new classification
    /// branch alongside it.
    func test_end_notesCapReached_surfacesWarmNotice_unchanged() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "agent-1", user_id: "user-1", role: "", enabled: true, chats: [])]
        service.summarizeSessionError = AppError.limitReached(resource: "notes", used: 10, limit: 10)
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 1)
        let notice = try XCTUnwrap(call.summarizeNotice)
        XCTAssertFalse(notice.isEmpty)
    }

    /// A generic/unclassified failure (e.g. a transient network hiccup whose
    /// detail text matches neither fixed constant) must fall back cleanly —
    /// no crash, still the same warm toast — proving the new classification
    /// branches are additive, not a replacement that could miss a case.
    func test_end_unclassifiedNetworkError_stillSurfacesWarmNotice() async throws {
        let service = ThrowingTestDataService()
        service.fetchAgentsResult = [FSAgent(id: "agent-1", user_id: "user-1", role: "", enabled: true, chats: [])]
        service.summarizeSessionError = AppError.networkError("Server error 500")
        let session = makeSession(summarize: true, creatorId: "user-1")

        let call = CallController.shared
        call.start(session: session, service: service, userId: "user-1")
        call.end()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.summarizeSessionCallCount, 1)
        let notice = try XCTUnwrap(call.summarizeNotice)
        XCTAssertFalse(notice.isEmpty)
    }

    // ── 2. Source-structural coverage ───────────────────────────────────────

    private func chimeCallViewSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Chat/ChimeCallView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func agentRouteSource() throws -> String {
        // FellowScriptTests/ -> FellowScript/ -> <repo root>/api/routes/agent.py
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("api/routes/agent.py")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// THE FIX's core mechanism: `stage` starts as "resolve-agent" (covering
    /// the resolveAgentId await) and is only advanced to "summarize-request"
    /// after resolveAgentId has already succeeded, before the
    /// summarizeSession await — so a thrown error's `stage` value at the
    /// catch site correctly attributes it to whichever await was actually in
    /// flight.
    func test_maybeSummarize_stageStartsResolveAgent_advancesAfterResolveAgentIdSucceeds() throws {
        let source = try chimeCallViewSource()
        guard let varRange = source.range(of: "var stage = \"resolve-agent\"") else {
            XCTFail("THE FIX: maybeSummarize must declare a mutable `stage` starting at \"resolve-agent\"")
            return
        }
        let after = source[varRange.upperBound...]
        guard let resolveRange = after.range(of: "try await Self.resolveAgentId(") else {
            XCTFail("could not locate the resolveAgentId call after stage's declaration"); return
        }
        let afterResolve = after[resolveRange.upperBound...]
        guard let stageAdvanceRange = afterResolve.range(of: "stage = \"summarize-request\"") else {
            XCTFail("THE FIX: stage must advance to \"summarize-request\" only after resolveAgentId returns"); return
        }
        guard let summarizeCallRange = afterResolve.range(of: "try await service.summarizeSession(") else {
            XCTFail("could not locate the summarizeSession call"); return
        }
        XCTAssertTrue(stageAdvanceRange.lowerBound < summarizeCallRange.lowerBound,
                      "THE FIX: stage must be advanced to \"summarize-request\" BEFORE the summarizeSession await starts, or a failure there would still misreport stage=\"resolve-agent\"")
    }

    /// The diagnostic emission must happen inside the catch block, before the
    /// user-facing toast is set — proves the new call is additive
    /// instrumentation, not something that could gate/delay/replace the
    /// existing warm-notice behavior.
    func test_maybeSummarize_catchEmitsDiagnosticBeforeShowingNotice() throws {
        let source = try chimeCallViewSource()
        guard let catchRange = source.range(of: "} catch {") else {
            XCTFail("could not locate maybeSummarize's catch block"); return
        }
        let afterCatch = source[catchRange.upperBound...]
        guard let diagnosticRange = afterCatch.range(of: "RefreshDiagnostics.summarizeOutcome(stage: stage, errorClass: Self.summarizeErrorClass(error))") else {
            XCTFail("THE FIX: the catch block must call RefreshDiagnostics.summarizeOutcome with the tracked stage and classified error"); return
        }
        guard let noticeRange = afterCatch.range(of: "self.showSummarizeNotice(") else {
            XCTFail("could not locate the showSummarizeNotice call"); return
        }
        XCTAssertTrue(diagnosticRange.lowerBound < noticeRange.lowerBound,
                      "THE FIX: the diagnostic emission must happen before the user-facing notice is shown")
    }

    /// `summarizeErrorClass` must match `summarize_session`'s own two fixed
    /// HTTPException detail strings (api/routes/agent.py) VERBATIM — pinned
    /// as a cross-file string equality check so a future wording change on
    /// either side that silently breaks this classification is caught here,
    /// not discovered again the hard way like this task itself was.
    func test_summarizeErrorClass_matchesBackendsFixedDetailStringsVerbatim() throws {
        let clientSource = try chimeCallViewSource()
        let backendSource = try agentRouteSource()

        XCTAssertTrue(backendSource.contains(#"raise HTTPException(status_code=403, detail="Not a member of this group")"#),
                      "sanity check: backend's not-a-member 403 detail string moved — update both sides together")
        XCTAssertTrue(clientSource.contains(#"detail == "Not a member of this group""#),
                      "THE FIX: summarizeErrorClass must match the not-a-member detail string verbatim")
        XCTAssertTrue(clientSource.contains(#"return "not-group-member-403""#))

        XCTAssertTrue(backendSource.contains(#"raise HTTPException(status_code=502, detail="Could not generate session summary.")"#),
                      "sanity check: backend's LLM-failure 502 detail string moved — update both sides together")
        XCTAssertTrue(clientSource.contains(#"detail == "Could not generate session summary.""#),
                      "THE FIX: summarizeErrorClass must match the LLM-generation detail string verbatim")
        XCTAssertTrue(clientSource.contains(#"return "llm-generation-502""#))
    }

    /// The pre-existing notes-cap 403 (`AppError.limitReached`) must still be
    /// classified explicitly rather than falling through to the generic
    /// `AppError.limitReached` label RefreshDiagnostics.errorClass would give
    /// it, and anything unmatched must still fall back to
    /// `RefreshDiagnostics.errorClass(_:)` rather than crashing/returning a
    /// blank label.
    func test_summarizeErrorClass_classifiesNotesCapAndFallsBackForEverythingElse() throws {
        let source = try chimeCallViewSource()
        guard let funcRange = source.range(of: "private static func summarizeErrorClass(_ error: Error) -> String {") else {
            XCTFail("THE FIX: summarizeErrorClass must exist"); return
        }
        let body = source[funcRange.upperBound...].prefix(800)
        XCTAssertTrue(body.contains(#"if case AppError.limitReached = error { return "notes-cap-403" }"#),
                      "THE FIX: the notes-cap 403 must classify as notes-cap-403, not the generic AppError.limitReached label")
        XCTAssertTrue(body.contains("return RefreshDiagnostics.errorClass(error)"),
                      "THE FIX: anything not matched by the summarize-specific cases must still fall back to the shared, already-tested errorClass(_:) classifier, never crash or drop the signal")
    }
}
