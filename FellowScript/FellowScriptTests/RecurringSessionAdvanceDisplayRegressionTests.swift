// RecurringSessionAdvanceDisplayRegressionTests.swift — coverage for task
// 20260921-recurring-session-next-occurrence (testing gate, step 4).
//
// backend step 1 added `_advance_recurring_sessions` (api/backend/
// interactions/scheduler.py), which rolls a `recurring = TRUE` session's
// `time_start`/`time_end` forward by exactly one week once its current
// occurrence ends. frontend step 3 confirmed (and documented in-source,
// ChatThreadView.swift ~984-1024) that `upcomingSessions`/`pastSessions`
// need NO client-side change to pick these advanced rows up: both are
// plain computed properties re-evaluated from `vm.sessions` on every
// render, filtering/sorting on each session's live `time_start` via
// `parseFlexibleISO8601`, rather than a value memoized once at fetch time.
//
// `upcomingSessions`/`pastSessions` are private computed properties of
// ChatThreadView, which (per this suite's own established precedent — see
// ChatSessionsSubmenuRegressionTests) can't be hosted directly in a unit
// test without a live EnvironmentObject/WebSocket round trip. So, matching
// that same file's two-pronged approach:
//
//   1. Source-pin the exact filter/comparator expressions (already pinned
//      once by ChatSessionsSubmenuRegressionTests' own
//      `test_source_sessionsSorting_...` — re-asserted here scoped to this
//      task's own acceptance criterion, so a regression that broke this
//      task specifically fails a test that names this task) AND confirm
//      the properties recompute from `vm.sessions` directly rather than
//      from any cached/memoized field.
//   2. Drive the REAL, shared `parseFlexibleISO8601` function (the actual
//      predicate `upcomingSessions`/`pastSessions` use) with a fixture that
//      simulates exactly what the backend advance job does: the SAME
//      session's `time_start`, before vs. after a one-week advance —
//      proving the live predicate correctly moves a session from "past" to
//      "upcoming" once advanced, without needing to host the View.

import XCTest
@testable import FellowScript

final class RecurringSessionAdvanceDisplayRegressionTests: XCTestCase {

    // MARK: - Source-pinning: live recomputation from vm.sessions, no memoized cache

    private func chatThreadViewSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // repo-relative project root
            .appendingPathComponent("FellowScript/Chat/ChatThreadView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Isolates just `upcomingSessions`/`pastSessions`, the same region
    /// frontend step 3 annotated with this task's own reasoning.
    private func sessionBucketingSource() throws -> String {
        let source = try chatThreadViewSource()
        guard let start = source.range(of: "private var upcomingSessions: [FSSession] {"),
              let end = source.range(of: "private var sessionsMenuOverlay: some View {",
                                      range: start.upperBound..<source.endIndex) else {
            XCTFail("expected to find ChatThreadView's upcomingSessions/pastSessions properties in the shipped source")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func test_source_upcomingAndPastSessions_recomputeLiveFromVmSessions_notMemoized() throws {
        let bucketing = try sessionBucketingSource()
        // Both properties must start their body by reading `vm.sessions`
        // directly (a live source of truth re-fetched from the backend),
        // never a private @State/@StateObject-cached derived array that
        // could go stale after a backend-side advance until some other
        // explicit invalidation step ran.
        XCTAssertTrue(bucketing.contains("return vm.sessions"),
                      "upcomingSessions/pastSessions must read directly off vm.sessions on every access, "
                      + "not a value cached once at fetch time — otherwise a backend-advanced session's "
                      + "new time_start would never be picked up without an extra invalidation step")
        XCTAssertFalse(bucketing.contains("@State private var upcomingSessions"),
                       "upcomingSessions must not become a @State-cached value — that would stop it "
                       + "from reflecting a session time_start that changed via a background scheduler job")
        XCTAssertFalse(bucketing.contains("@State private var pastSessions"),
                       "pastSessions must not become a @State-cached value, for the same reason")
    }

    func test_source_upcomingSessions_filtersOnLiveTimeStartNotAStoredBucketFlag() throws {
        let bucketing = try sessionBucketingSource()
        // Pins the actual predicate (matches ChatSessionsSubmenuRegressionTests'
        // own pinning of the same expressions) — re-asserted here under this
        // task's name so a regression to *this* acceptance criterion
        // specifically shows up under this task's own test file.
        XCTAssertTrue(bucketing.contains(#".filter { (parseFlexibleISO8601($0.time_start) ?? .distantPast) >= now }"#),
                      "upcomingSessions must filter live off each session's own time_start compared against 'now' "
                      + "at render time — not a server-computed/stored 'is upcoming' boolean that a recurring "
                      + "advance would need to separately flip")
        XCTAssertTrue(bucketing.contains(#".filter { (parseFlexibleISO8601($0.time_start) ?? .distantPast) < now }"#),
                      "pastSessions must filter the same way, in the opposite direction")
    }

    // MARK: - Fixture: the real parseFlexibleISO8601 predicate correctly re-buckets
    // a session across exactly the transformation the backend advance job performs
    // (time_start moved forward by one week).

    func test_advancedRecurringSession_movesFromPastBucketToUpcomingBucket() {
        // A recurring session whose occurrence just ended: time_start a
        // couple of hours ago — safely past
        // SESSION_RECURRING_ADVANCE_GRACE_SECONDS (1 hour, scheduler.py),
        // exactly the shape `_advance_recurring_sessions` treats as a
        // candidate once past its grace period. (Deliberately NOT "7+ days
        // ago" — that would already be a stale, never-advanced occurrence
        // from the week before, not the one the job is about to roll
        // forward; the realistic input is "recently ended.")
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let originalStart = now.addingTimeInterval(-2 * 3600) // 2 hours ago
        let originalStartString = iso.string(from: originalStart)

        // What the backend advance job produces: the same session's
        // time_start rolled forward by exactly one calendar week (the UTC
        // case — the local-wall-clock/DST nuance is covered on the backend
        // side by test_recurring_session_advance.py; this fixture only
        // needs to prove the CLIENT'S bucketing predicate reacts correctly
        // to whatever new time_start value the backend writes). Landing
        // ~7 days in the future, since the original occurrence was only a
        // couple of hours in the past.
        let advancedStart = originalStart.addingTimeInterval(7 * 24 * 3600)
        let advancedStartString = iso.string(from: advancedStart)

        guard let parsedOriginal = parseFlexibleISO8601(originalStartString),
              let parsedAdvanced = parseFlexibleISO8601(advancedStartString) else {
            XCTFail("parseFlexibleISO8601 must successfully parse both the pre- and post-advance time_start strings")
            return
        }

        // Before the advance: this is exactly upcomingSessions'/pastSessions'
        // own predicate, applied directly to the real parsing function.
        XCTAssertFalse(parsedOriginal >= now,
                       "the session's original (unadvanced) time_start must NOT satisfy the 'upcoming' predicate — "
                       + "it's in the past, which is exactly the stale state this task fixes")
        XCTAssertTrue(parsedOriginal < now,
                      "the session's original (unadvanced) time_start must satisfy the 'past' predicate")

        // After the advance: the SAME predicate, applied to the new value,
        // must now bucket it as upcoming — proving the live re-derivation
        // (not a separate client-side recurrence computation) is what makes
        // the advanced occurrence show up correctly.
        XCTAssertTrue(parsedAdvanced >= now,
                      "the advanced time_start must satisfy the 'upcoming' predicate, reflecting the rolled-forward occurrence")
        XCTAssertFalse(parsedAdvanced < now,
                       "the advanced time_start must NOT satisfy the 'past' predicate any more")
    }

    func test_advancedRecurringSession_stillWithinGracePeriod_remainsInPastBucketUntilAdvanced() {
        // Mirrors the backend's own grace-period boundary
        // (SESSION_RECURRING_ADVANCE_GRACE_SECONDS = 3600s): a session whose
        // time_start/time_end are only minutes past "now" hasn't been
        // advanced by the backend job yet, so the client must correctly
        // keep showing it as past/just-ended, not upcoming — there is no
        // client-side grace-period logic of its own to get this wrong,
        // which this fixture confirms by construction.
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let recentlyEndedStart = now.addingTimeInterval(-300) // 5 minutes ago, well within grace
        let recentlyEndedString = iso.string(from: recentlyEndedStart)

        guard let parsed = parseFlexibleISO8601(recentlyEndedString) else {
            XCTFail("parseFlexibleISO8601 must successfully parse a recent time_start string")
            return
        }
        XCTAssertTrue(parsed < now, "a session within the backend's own advance grace period must still read as 'past' client-side")
    }
}
