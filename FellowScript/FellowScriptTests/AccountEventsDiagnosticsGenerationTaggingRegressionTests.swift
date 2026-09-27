// AccountEventsDiagnosticsGenerationTaggingRegressionTests.swift — testing-gate
// coverage for task 20260926-account-events-regression, step 3.
//
// Context: this task's backend and frontend gates each re-audited their own
// layer (live production DB/API endpoints and log evidence were NOT reachable
// from this sandboxed pipeline run — no SSH/CloudWatch credentials available)
// and found no reachable, fixable bug by source/language-contract reasoning
// alone. Backend step 1 confirmed the migration hook and both live endpoints
// are structurally sound. Frontend step 2 went further and conclusively
// REFUTED the build-45 commit's own claimed root-cause mechanism (a Swift
// `TaskGroup` "losing" a result under Release) as mechanically unreachable —
// see AccountEventsHeartbeatsTaskGroupIncompleteWalkRegressionTests.swift for
// that guard's own (still-passing, unweakened) coverage — and identified the
// far more mundane, mechanically-consistent explanation for build-45's own
// live-capture confusion: `RefreshDiagnostics.fetchOutcome`/`taskGroupOutcome`
// carried no round/generation id, so two overlapping `AccountViewModel.load()`
// rounds' interleaved Console.app lines were indistinguishable from one
// round's own sequence.
//
// THIS TASK'S ONE CONCRETE, VERIFIED CHANGE: `generation` was threaded through
// every diagnostic call site inside `load()` so the next live capture can
// attribute each line to its exact round. This file pins that change staying
// in place — NOT a claim that the user's underlying stuck-empty-state symptom
// is confirmed fixed. Per this task's own acceptance criteria and the
// testing-gate note carried into this step: a concrete, evidenced root cause
// for the live symptom itself could not be established without production
// log/device access unavailable in this sandbox, and this suite does not
// pretend otherwise. Genuine resolution requires a live capture using these
// now-generation-tagged diagnostics on the next real reproduction.
//
// WHY THIS FILE IS SOURCE-STRUCTURAL, NOT A RUNTIME REPRODUCTION: like
// AccountEventsHeartbeatsTaskGroupIncompleteWalkRegressionTests.swift, forcing
// two genuinely overlapping `load()` rounds to interleave their diagnostic
// emissions deterministically under XCTest is impractical (the race this
// fixes is a live Console.app attribution problem, not a unit-testable
// functional behavior) — RefreshDiagnostics writes to `os.Logger`/`print`
// with no return value or spy seam. Pinning the source contract (every call
// site supplies `generation:`, and the signatures make that structurally hard
// to omit going forward) is this codebase's own established convention for
// exactly this class of fix.

import XCTest
@testable import FellowScript

final class AccountEventsDiagnosticsGenerationTaggingRegressionTests: XCTestCase {

    private func accountViewModelSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Account/AccountViewModel.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func refreshDiagnosticsSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Services/RefreshDiagnostics.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// THE FIX: `taskGroupOutcome`'s `generation` parameter must be
    /// non-optional (no default) — this makes it a compile error for any
    /// call site (present or future) to silently omit it, unlike
    /// `fetchOutcome`'s `generation: Int? = nil` (which stays optional/
    /// defaulted for call sites outside `load()`'s own round concept, e.g.
    /// the unrelated `GET /subscriptions/user/{user_id}` diagnostics this
    /// task deliberately left untouched, per its own scope).
    func test_taskGroupOutcome_generationParameter_isRequired_notDefaulted() throws {
        let source = try refreshDiagnosticsSource()
        guard let sigRange = source.range(of: "static func taskGroupOutcome(") else {
            XCTFail("could not locate RefreshDiagnostics.taskGroupOutcome's signature")
            return
        }
        guard let closeParen = source[sigRange.upperBound...].range(of: ")") else {
            XCTFail("could not locate the end of taskGroupOutcome's parameter list")
            return
        }
        let signature = source[sigRange.upperBound..<closeParen.lowerBound]
        XCTAssertTrue(signature.contains("generation: Int"),
                      "THE FIX: taskGroupOutcome must declare a generation: Int parameter")
        XCTAssertFalse(signature.contains("generation: Int?") || signature.contains("generation: Int ="),
                       "THE FIX: taskGroupOutcome's generation parameter must be required (no `?`, no default) so a future call site cannot silently omit the round id that lets a live capture tell overlapping rounds apart")
    }

    /// `fetchOutcome` must still accept a generation id (optional, for
    /// backward-compatible call sites outside load()'s round concept).
    func test_fetchOutcome_acceptsGenerationParameter() throws {
        let source = try refreshDiagnosticsSource()
        guard let sigRange = source.range(of: "static func fetchOutcome(") else {
            XCTFail("could not locate RefreshDiagnostics.fetchOutcome's signature")
            return
        }
        guard let closeParen = source[sigRange.upperBound...].range(of: ") {") else {
            XCTFail("could not locate the end of fetchOutcome's parameter list")
            return
        }
        let signature = source[sigRange.upperBound..<closeParen.lowerBound]
        XCTAssertTrue(signature.contains("generation: Int?"),
                      "THE FIX: fetchOutcome must accept an optional generation id so load()'s round-scoped fetches can tag their diagnostic lines")
    }

    /// THE FIX's actual coverage: every one of load()'s own fetchOutcome call
    /// sites (the 7 concurrent top-level fetches' success+failure branches,
    /// plus the per-agent heartbeats walk's success+failure branches) must
    /// pass `generation: generation` — not merely be permitted to. A single
    /// missed call site would silently reintroduce the exact cross-round
    /// misattribution ambiguity frontend step 2 diagnosed as build-45's real
    /// confusion, for that one endpoint only.
    func test_load_everyFetchOutcomeCallSite_passesGeneration() throws {
        let source = try accountViewModelSource()
        guard let loadStart = source.range(of: "func load(service: DataServiceProtocol, user: FSUser) async {"),
              let taskGroupOutcomeCall = source.range(of: "RefreshDiagnostics.taskGroupOutcome(") else {
            XCTFail("could not locate load()'s body or its taskGroupOutcome call")
            return
        }
        // Scope the search to load()'s own body, ending just after the
        // taskGroupOutcome summary call (the last diagnostic emission tied to
        // this round's concurrent-fetch phase) — this deliberately excludes
        // the unrelated GET /subscriptions/user/{user_id} fetchOutcome calls
        // elsewhere in this file (a different method, outside load()'s own
        // generation concept, per this task's explicit scope).
        let body = source[loadStart.upperBound..<taskGroupOutcomeCall.upperBound]

        let fetchOutcomeCallCount = body.components(separatedBy: "RefreshDiagnostics.fetchOutcome(").count - 1
        XCTAssertEqual(fetchOutcomeCallCount, 16,
                       "expected exactly 16 fetchOutcome call sites inside load() (7 concurrent fetches + heartbeats walk, success+failure branches each) — if this count changed, update this test to also verify the new/removed call site(s) still carry generation:")

        // Every individual call-site block (from "RefreshDiagnostics.fetchOutcome("
        // to its own closing ")") must contain "generation: generation" —
        // walk each occurrence rather than checking the whole body at once,
        // so a single call site missing the parameter can't hide behind
        // others that do have it.
        var searchRange = body.startIndex..<body.endIndex
        var checkedCallSites = 0
        while let callStart = body.range(of: "RefreshDiagnostics.fetchOutcome(", range: searchRange) {
            // Each call spans to its matching top-level close-paren; these
            // calls never nest parens more than one level deep beyond the
            // call itself in this file, so scanning to the next occurrence of
            // "generation: generation)" or the next call site (whichever
            // comes first) reliably delimits one call's own argument list for
            // this specific, known call-site shape.
            let nextCallStart = body.range(of: "RefreshDiagnostics.fetchOutcome(", range: callStart.upperBound..<body.endIndex)
            let callEnd = nextCallStart?.lowerBound ?? body.endIndex
            let callSite = body[callStart.lowerBound..<callEnd]
            XCTAssertTrue(callSite.contains("generation: generation"),
                          "THE FIX: every fetchOutcome call site inside load() must pass generation: generation — found one that doesn't: \(callSite.prefix(120))")
            checkedCallSites += 1
            searchRange = callEnd..<body.endIndex
        }
        XCTAssertEqual(checkedCallSites, fetchOutcomeCallCount, "sanity: the walk above must have actually visited every call site counted")
    }

    /// The heartbeats walk's own round summary must also carry the round id
    /// — this is the line whose absence of a generation id is what let
    /// build-45's diagnostic pass misattribute a different round's
    /// `tasksAdded`/`resultsConsumed` counters to this one.
    func test_load_taskGroupOutcomeCall_passesGeneration() throws {
        let source = try accountViewModelSource()
        guard let callRange = source.range(of: "RefreshDiagnostics.taskGroupOutcome(") else {
            XCTFail("could not locate load()'s taskGroupOutcome call")
            return
        }
        guard let closeParen = source[callRange.upperBound...].range(of: ")\n") else {
            XCTFail("could not locate the end of the taskGroupOutcome call")
            return
        }
        let call = source[callRange.lowerBound..<closeParen.lowerBound]
        XCTAssertTrue(call.contains("generation: generation"),
                      "THE FIX: load()'s taskGroupOutcome call must pass generation: generation")
    }

    /// Documents, rather than silently assumes, that this task did NOT touch
    /// the build-45 `heartbeatsResultsConsumed < heartbeatsTasksAdded` guard's
    /// own behavior — it stays in place as a harmless fail-closed fallback
    /// (per frontend step 2's summary), only its surrounding comments were
    /// corrected. AccountEventsHeartbeatsTaskGroupIncompleteWalkRegressionTests
    /// already pins the guard's mechanics; this just guards against this
    /// task's own diagnostic-only change accidentally having deleted it.
    func test_load_incompleteWalkFallbackGuard_stillPresent_unweakenedByThisTask() throws {
        let source = try accountViewModelSource()
        XCTAssertTrue(source.contains("if heartbeatsResultsConsumed < heartbeatsTasksAdded {"),
                      "this task's diagnostic-only change must not have removed the pre-existing fail-closed fallback guard")
    }
}
