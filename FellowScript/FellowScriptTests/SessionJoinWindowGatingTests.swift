// SessionJoinWindowGatingTests.swift — coverage for task
// 20260920-session-join-window-gating, step 4 (testing).
//
// Proves FSSession.isJoinWindowOpen(now:) against every branch of the binding
// contract at .claude/pipeline/20260920-session-join-window-gating/
// join-window-contract.md §6 (client-side mirror of the server's §2), using a
// fixed `now` passed explicitly rather than the live clock -- deterministic,
// no simulator-clock or timing flakiness. This is a pure function of its
// inputs (no view rendering, no environment), so it's tested directly rather
// than through ViewInspector, matching this target's existing convention for
// non-view logic (see FlexibleISO8601DateParsingRegressionTests.swift for the
// same style applied to parseFlexibleISO8601 itself, which this gating logic
// is built on).
//
// This is the client-side sibling of api/tests/test_session_join_window_gating.py's
// server-side boundary coverage -- same six scenarios, same reasoning, applied
// to FSSession.isJoinWindowOpen instead of DevotionManager.is_join_window_open.

import XCTest
@testable import FellowScript

final class SessionJoinWindowGatingTests: XCTestCase {

    private let iso = ISO8601DateFormatter()

    private func makeSession(timeStart: String, timeEnd: String = "") -> FSSession {
        FSSession(id: "session-1", title: "Study Session", time_start: timeStart, time_end: timeEnd)
    }

    func test_inWindow_timeStartPast_timeEndFuture_isOpen() {
        let now = Date()
        let session = makeSession(
            timeStart: iso.string(from: now.addingTimeInterval(-5 * 60)),
            timeEnd: iso.string(from: now.addingTimeInterval(60 * 60))
        )
        XCTAssertTrue(session.isJoinWindowOpen(now: now),
                      "a session that has started and not yet ended must be joinable")
    }

    func test_beforeWindow_timeStartWellInFuture_isClosed() {
        let now = Date()
        let session = makeSession(
            timeStart: iso.string(from: now.addingTimeInterval(2 * 60 * 60)),
            timeEnd: iso.string(from: now.addingTimeInterval(3 * 60 * 60))
        )
        XCTAssertFalse(session.isJoinWindowOpen(now: now),
                       "a session starting 2 hours from now (well beyond the grace period) must stay greyed out")
    }

    func test_withinGracePeriod_earlyJoinIsOpen() {
        // FSSession.joinGraceMinutes is hardcoded to 10 (join-window-contract.md
        // §6) -- 5 minutes early is comfortably inside that without coupling
        // this test to the exact constant value at the call site.
        let now = Date()
        let session = makeSession(
            timeStart: iso.string(from: now.addingTimeInterval(5 * 60)),
            timeEnd: iso.string(from: now.addingTimeInterval(60 * 60))
        )
        XCTAssertTrue(session.isJoinWindowOpen(now: now),
                      "joining 5 minutes before time_start must be allowed within the grace period")
    }

    func test_afterWindow_timeEndPast_isClosed() {
        let now = Date()
        let session = makeSession(
            timeStart: iso.string(from: now.addingTimeInterval(-2 * 60 * 60)),
            timeEnd: iso.string(from: now.addingTimeInterval(-60 * 60))
        )
        XCTAssertFalse(session.isJoinWindowOpen(now: now),
                       "a session whose time_end has already passed must be greyed out")
    }

    func test_missingTimeStart_failsClosed_neverAlwaysOpen() {
        let now = Date()
        let session = makeSession(timeStart: "", timeEnd: iso.string(from: now.addingTimeInterval(60 * 60)))
        XCTAssertFalse(session.isJoinWindowOpen(now: now),
                       "missing/unparseable time_start must fail closed, matching the server's decision -- " +
                       "never treated as always-open")
    }

    func test_malformedTimeStart_failsClosed() {
        let now = Date()
        let session = makeSession(timeStart: "not-a-real-date", timeEnd: "")
        XCTAssertFalse(session.isJoinWindowOpen(now: now),
                       "an unparseable (not just empty) time_start must also fail closed")
    }

    func test_missingTimeEnd_isOpenEndedOnceStarted_noSynthesizedDuration() {
        let now = Date()
        let session = makeSession(timeStart: iso.string(from: now.addingTimeInterval(-3 * 60 * 60)), timeEnd: "")
        XCTAssertTrue(session.isJoinWindowOpen(now: now),
                      "a started session with no time_end must stay open indefinitely, mirroring the " +
                      "server's §2.4 asymmetry -- no implicit duration is synthesized")
    }

    func test_malformedTimeEnd_isTreatedAsOpenEnded() {
        let now = Date()
        let session = makeSession(
            timeStart: iso.string(from: now.addingTimeInterval(-3 * 60 * 60)),
            timeEnd: "not-a-real-date"
        )
        XCTAssertTrue(session.isJoinWindowOpen(now: now),
                      "an unparseable (not just empty) time_end is the same open-ended case as a missing one")
    }
}
