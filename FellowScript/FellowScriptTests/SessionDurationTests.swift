// SessionDurationTests.swift — coverage for task
// 20260809-chat-schedule-migrate-fellowscript, step 5 (testing).
//
// Covers the "duration -> time_end computation" acceptance criterion: the
// SessionCreatorSheet scheduling flow (ChatThreadView.swift) has no backend
// duration field on FSSession (only time_start/time_end strings), so the
// segmented 15/30/45/60-minute control's selection must be converted to a
// time_end string client-side before calling createSession/updateSession.
//
// That formula was originally inlined directly in SessionCreatorSheet's
// private scheduleSession() method (untestable without hosting the view and
// its private @State). This gate extracted the exact same formula, unchanged,
// into SessionDuration.timeEndISOString(from:) (SegmentedDurationControl.swift)
// so the production formula itself — not a re-implementation of it — is
// covered here.

import XCTest
@testable import FellowScript

final class SessionDurationTests: XCTestCase {

    // MARK: - Case shape (guards against silent drift in the 4 offered options)

    func testAllCasesAreThe15_30_45_60MinuteOptionsInOrder() {
        XCTAssertEqual(SessionDuration.allCases.map(\.rawValue), [15, 30, 45, 60])
    }

    func testLabelsRenderAsMinuteSuffixedStrings() {
        XCTAssertEqual(SessionDuration.fifteen.label, "15m")
        XCTAssertEqual(SessionDuration.thirty.label, "30m")
        XCTAssertEqual(SessionDuration.fortyFive.label, "45m")
        XCTAssertEqual(SessionDuration.sixty.label, "60m")
    }

    // MARK: - time_end computation (the acceptance-criterion-named logic)

    /// Fixed reference start time so assertions are exact and reproducible.
    private var referenceStart: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 9
        c.hour = 18; c.minute = 0; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private func parse(_ iso: String) -> Date {
        let df = ISO8601DateFormatter()
        return df.date(from: iso)!
    }

    func testFifteenMinuteDurationAdvancesTimeEndBy15Minutes() {
        let end = SessionDuration.fifteen.timeEndISOString(from: referenceStart)
        XCTAssertEqual(parse(end).timeIntervalSince(referenceStart), 15 * 60, accuracy: 0.001)
    }

    func testThirtyMinuteDurationAdvancesTimeEndBy30Minutes() {
        let end = SessionDuration.thirty.timeEndISOString(from: referenceStart)
        XCTAssertEqual(parse(end).timeIntervalSince(referenceStart), 30 * 60, accuracy: 0.001)
    }

    func testFortyFiveMinuteDurationAdvancesTimeEndBy45Minutes() {
        let end = SessionDuration.fortyFive.timeEndISOString(from: referenceStart)
        XCTAssertEqual(parse(end).timeIntervalSince(referenceStart), 45 * 60, accuracy: 0.001)
    }

    func testSixtyMinuteDurationAdvancesTimeEndBy60Minutes() {
        let end = SessionDuration.sixty.timeEndISOString(from: referenceStart)
        XCTAssertEqual(parse(end).timeIntervalSince(referenceStart), 60 * 60, accuracy: 0.001)
    }

    func testTimeEndStringIsValidISO8601AndParseableRoundTrip() {
        // Regression guard: SessionCreatorSheet's onSave hands this string
        // straight to FSSession.time_end, which the rest of the app (and the
        // real backend) expects to be able to parse as ISO8601 — a malformed
        // or non-ISO8601 string here would silently corrupt session display
        // everywhere FSSession.formattedStart/formattedEnd is used.
        let end = SessionDuration.thirty.timeEndISOString(from: referenceStart)
        let df = ISO8601DateFormatter()
        XCTAssertNotNil(df.date(from: end), "time_end must be a valid ISO8601 string, got: \(end)")
    }

    func testCrossesMidnightCorrectly() {
        // A session starting at 23:50 with a 30-minute duration must roll
        // over to the next day, not wrap/clamp within the same day.
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 9
        c.hour = 23; c.minute = 50; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let lateStart = cal.date(from: c)!

        let end = parse(SessionDuration.thirty.timeEndISOString(from: lateStart))
        let endComponents = cal.dateComponents([.day, .hour, .minute], from: end)
        XCTAssertEqual(endComponents.day, 10)
        XCTAssertEqual(endComponents.hour, 0)
        XCTAssertEqual(endComponents.minute, 20)
    }
}
