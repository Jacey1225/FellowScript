// ActivityCalendarMathTests.swift -- task 20261114-activity-calendar, step 8.
// Pure date and week math for the Home card and month screen.

import XCTest
@testable import FellowScript

final class ActivityCalendarMathTests: XCTestCase {
    private typealias M = ActivityCalendarMath
    private var sundayStart: Bool { M.cal.firstWeekday == 1 }
    private var mondayStart: Bool { M.cal.firstWeekday == 2 }

    func test_daysInMonth_28_29_30_31() {
        XCTAssertEqual(M.daysIn(year: 2026, month: 2), 28)
        XCTAssertEqual(M.daysIn(year: 2028, month: 2), 29)
        XCTAssertEqual(M.daysIn(year: 2100, month: 2), 28)
        XCTAssertEqual(M.daysIn(year: 2000, month: 2), 29)
        for m in [4, 6, 9, 11] { XCTAssertEqual(M.daysIn(year: 2026, month: m), 30, "month \(m)") }
        for m in [1, 3, 5, 7, 8, 10, 12] { XCTAssertEqual(M.daysIn(year: 2026, month: m), 31, "month \(m)") }
    }

    func test_leadingBlanks_inRangeAndMatchesKnownWeekdays() {
        for m in 1...12 { let b = M.leadingBlanks(year: 2026, month: m); XCTAssertTrue((0..<7).contains(b)) }
        // 2026-11-01 is a Sunday, 2026-10-01 a Thursday.
        if sundayStart {
            XCTAssertEqual(M.leadingBlanks(year: 2026, month: 11), 0)
            XCTAssertEqual(M.leadingBlanks(year: 2026, month: 10), 4)
        } else if mondayStart {
            XCTAssertEqual(M.leadingBlanks(year: 2026, month: 11), 6)
            XCTAssertEqual(M.leadingBlanks(year: 2026, month: 10), 3)
        }
    }

    func test_gridCellCountNeverOverflowsSixWeeks() {
        for y in [2026, 2027, 2028] { for m in 1...12 {
            let cells = M.leadingBlanks(year: y, month: m) + M.daysIn(year: y, month: m)
            XCTAssertLessThanOrEqual(cells, 42)
        } }
    }

    func test_week_hasSevenConsecutiveDaysStartingOnFirstWeekday_andContainsDay() {
        let d = CalDay(y: 2026, m: 11, d: 14)
        let w = M.week(containing: d)
        XCTAssertEqual(w.count, 7)
        XCTAssertTrue(w.contains(d))
        XCTAssertEqual(M.cal.component(.weekday, from: M.date(w[0])), M.cal.firstWeekday)
        for i in 1..<7 { XCTAssertEqual(M.cal.dateComponents([.day], from: M.date(w[i-1]), to: M.date(w[i])).day, 1) }
        if sundayStart { XCTAssertEqual(w.first, CalDay(y: 2026, m: 11, d: 8)); XCTAssertEqual(w.last, CalDay(y: 2026, m: 11, d: 14)) }
        if mondayStart { XCTAssertEqual(w.first, CalDay(y: 2026, m: 11, d: 9)); XCTAssertEqual(w.last, CalDay(y: 2026, m: 11, d: 15)) }
    }

    func test_week_straddlesYearBoundary() {
        let w = M.week(containing: CalDay(y: 2026, m: 12, d: 31)) // Thursday
        XCTAssertEqual(w.count, 7)
        XCTAssertTrue(w.contains(CalDay(y: 2026, m: 12, d: 31)))
        XCTAssertEqual(w.last!.y, 2027); XCTAssertEqual(w.last!.m, 1)
        XCTAssertEqual(w.first!.m, 12)
        if sundayStart { XCTAssertEqual(w.first, CalDay(y: 2026, m: 12, d: 27)); XCTAssertEqual(w.last, CalDay(y: 2027, m: 1, d: 2)) }
    }

    func test_week_straddlesMonthEndWith30And31DayMonths() {
        // Nov (30 days) -> Dec, Oct (31) -> Nov
        let nov30 = M.week(containing: CalDay(y: 2026, m: 11, d: 30))
        XCTAssertTrue(nov30.contains(CalDay(y: 2026, m: 11, d: 30)))
        XCTAssertTrue(nov30.contains(CalDay(y: 2026, m: 12, d: 1)))
        let oct31 = M.week(containing: CalDay(y: 2026, m: 10, d: 31)) // Saturday
        XCTAssertTrue(oct31.contains(CalDay(y: 2026, m: 10, d: 31)))
        if sundayStart { XCTAssertEqual(oct31.last, CalDay(y: 2026, m: 10, d: 31)) }
        if mondayStart { XCTAssertEqual(oct31.last, CalDay(y: 2026, m: 11, d: 1)) }
        // Leap day
        XCTAssertTrue(M.week(containing: CalDay(y: 2028, m: 2, d: 29)).contains(CalDay(y: 2028, m: 2, d: 29)))
        let feb28 = M.week(containing: CalDay(y: 2026, m: 2, d: 28))
        XCTAssertFalse(feb28.contains(CalDay(y: 2026, m: 2, d: 29)))
    }

    func test_shift_acrossYearBoundariesAndLargeDeltas() {
        XCTAssertTrue(M.shift(year: 2026, month: 1, by: -1) == (2025, 12))
        XCTAssertTrue(M.shift(year: 2026, month: 12, by: 1) == (2027, 1))
        XCTAssertTrue(M.shift(year: 2026, month: 11, by: -36) == (2023, 11))
        XCTAssertTrue(M.shift(year: 2026, month: 11, by: 0) == (2026, 11))
        XCTAssertTrue(M.shift(year: 2026, month: 3, by: -3) == (2025, 12))
    }

    func test_today_usesUserTimezone_notDeviceOrUTC() {
        // 2026-11-14 07:30 UTC
        let t1 = Date(timeIntervalSince1970: 1_794_641_400)
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(c.dateComponents([.day, .hour], from: t1).day, 14)
        XCTAssertEqual(M.today(timeZoneId: "UTC", now: t1), CalDay(y: 2026, m: 11, d: 14))
        XCTAssertEqual(M.today(timeZoneId: "America/Los_Angeles", now: t1), CalDay(y: 2026, m: 11, d: 13))
        XCTAssertEqual(M.today(timeZoneId: "Pacific/Pago_Pago", now: t1), CalDay(y: 2026, m: 11, d: 13))
        XCTAssertEqual(M.today(timeZoneId: "Pacific/Kiritimati", now: t1), CalDay(y: 2026, m: 11, d: 14))
    }

    func test_today_yearAndMonthRolloverByTimezone() {
        // 2026-12-31 23:30 UTC -> already 2027-01-01 in Tokyo, still Dec 31 in LA
        let t = Date(timeIntervalSince1970: 1_798_759_800)
        XCTAssertEqual(M.today(timeZoneId: "Asia/Tokyo", now: t), CalDay(y: 2027, m: 1, d: 1))
        XCTAssertEqual(M.today(timeZoneId: "America/Los_Angeles", now: t), CalDay(y: 2026, m: 12, d: 31))
    }

    func test_today_invalidOrNilTimezoneFallsBackWithoutCrash() {
        let now = Date()
        XCTAssertEqual(M.today(timeZoneId: nil, now: now), M.today(timeZoneId: "Not/AZone", now: now))
    }

    func test_calDay_ordering_andKeyFormat() {
        XCTAssertTrue(CalDay(y: 2026, m: 11, d: 30) < CalDay(y: 2026, m: 12, d: 1))
        XCTAssertTrue(CalDay(y: 2026, m: 12, d: 31) < CalDay(y: 2027, m: 1, d: 1))
        XCTAssertEqual(CalDay(y: 2026, m: 3, d: 5).key, "2026-03-05")
        XCTAssertEqual(M.day(M.date(CalDay(y: 2028, m: 2, d: 29))), CalDay(y: 2028, m: 2, d: 29))
    }

    func test_dayKeyMatchesStoreKeys() {
        let m = FSActivityMonth(year: 2026, month: 10, timezone: "UTC", days: ["2026-10-31": [.chat, .note, .bible]])
        XCTAssertEqual(m.kinds(on: CalDay(y: 2026, m: 10, d: 31).key), [.chat, .note, .bible])
    }

    func test_weekdayInitials_sevenEntries() { XCTAssertEqual(M.weekdayInitials().count, 7) }

    func test_dayLabel_listsKindsInPlainWords_andMarksToday() {
        let l = M.dayLabel(CalDay(y: 2026, m: 10, d: 31), kinds: [.chat, .note, .bible], isToday: true)
        XCTAssertTrue(l.hasPrefix("Today, "))
        XCTAssertTrue(l.contains("31"))
        XCTAssertTrue(l.lowercased().contains("bible reading") && l.contains("note") && l.lowercased().contains("chat"))
        XCTAssertTrue(M.dayLabel(CalDay(y: 2026, m: 10, d: 30), kinds: [], isToday: false).hasSuffix("No activity."))
    }

    func test_browseWindowIs36Months_andBibleNoteHiddenUntilDateExists() {
        XCTAssertEqual(M.browseBackMonths, 36)
        XCTAssertNil(M.bibleRecordedFrom)
    }

    func test_monthName_omitsYearWhenAsked() {
        XCTAssertFalse(M.monthName(year: 2026, month: 11, includeYear: false).contains("2026"))
        XCTAssertTrue(M.monthName(year: 2025, month: 11, includeYear: true).contains("2025"))
    }
}
