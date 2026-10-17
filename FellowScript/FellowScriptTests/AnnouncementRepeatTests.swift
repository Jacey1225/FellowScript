// AnnouncementRepeatTests.swift — task 20261016-announcement-recurring-reminder.
// Covers decoding back-compat, the wire change (omit / off / set + device tz),
// end-date rules, the member indicator text and warm error mapping.

import XCTest
@testable import FellowScript

@MainActor
final class AnnouncementRepeatTests: XCTestCase {

    private func decode(_ extra: String = "") throws -> FSGroupAnnouncement {
        let json = """
        {"id":"a1","group_id":"g1","creator_id":"u1","creator_username":"sam","title":"T","description":"D",
         "banner_url":null,"publish_at":"2026-10-20T15:00:00+00:00","created_at":"2026-10-16T15:00:00+00:00",
         "updated_at":"2026-10-16T15:00:00+00:00","published":true,"can_edit":true\(extra)}
        """
        return try JSONDecoder().decode(FSGroupAnnouncement.self, from: Data(json.utf8))
    }

    func testOldPayloadDecodesAsNoRepeat() throws {
        let a = try decode()
        XCTAssertNil(a.repeat_interval)
        XCTAssertNil(a.repeatIndicator)
        XCTAssertEqual(AnnouncementRepeatDraft(from: a), .off)
    }

    func testRepeatKeysDecodeAndPrefill() throws {
        let a = try decode(#","repeat_interval":"weekly","repeat_until":"2026-11-30T23:59:00+00:00","repeat_active":true,"repeat_tz":"America/New_York""#)
        let d = AnnouncementRepeatDraft(from: a)
        XCTAssertEqual(d.interval, .weekly)
        XCTAssertNotNil(d.until)
        XCTAssertTrue(a.repeatIndicator?.hasPrefix("Repeats weekly, until ") ?? false)
    }

    func testIndicatorVariants() throws {
        XCTAssertEqual(try decode(#","repeat_interval":"daily","repeat_auto_stops":true,"repeat_active":true"#).repeatIndicator,
                       "Repeats daily, ends automatically")
        XCTAssertEqual(try decode(#","repeat_interval":"monthly","repeat_active":false"#).repeatIndicator, "Repeat finished")
        XCTAssertEqual(try decode(#","repeat_interval":"hourly-ish","repeat_active":true"#).repeatIndicator, nil)
    }

    func testUnchangedSendsNoRepeatKeys() {
        var draft = FSAnnouncementDraft(title: "a", description: "b")
        draft.repeatChange = AnnouncementRepeatDraft.off.change(from: .off)
        let o = draft.jsonObject
        XCTAssertNil(o["repeat_interval"]); XCTAssertNil(o["repeat_tz"]); XCTAssertNil(o["repeat_until"])
    }

    func testSetAlwaysSendsDeviceTimeZoneAndExplicitNullUntil() {
        let change = AnnouncementRepeatDraft(interval: .weekly, until: nil).change(from: .off, timeZone: "America/Chicago")
        var o: [String: Any] = [:]
        change.merge(into: &o)
        XCTAssertEqual(o["repeat_interval"] as? String, "weekly")
        XCTAssertEqual(o["repeat_tz"] as? String, "America/Chicago")
        XCTAssertTrue(o["repeat_until"] is NSNull)
    }

    func testSetUsesDeviceZoneByDefault() {
        var o: [String: Any] = [:]
        AnnouncementRepeatDraft(interval: .daily, until: nil).change(from: .off).merge(into: &o)
        XCTAssertEqual(o["repeat_tz"] as? String, TimeZone.current.identifier)
    }

    func testTurningOffSendsExplicitNullOnly() {
        let orig = AnnouncementRepeatDraft(interval: .daily, until: nil)
        var o: [String: Any] = [:]
        AnnouncementRepeatDraft.off.change(from: orig).merge(into: &o)
        XCTAssertTrue(o["repeat_interval"] is NSNull)
        XCTAssertNil(o["repeat_tz"])
    }

    func testEndDateMustBeAfterFirstPost() {
        let now = Date()
        let soon = AnnouncementRepeatDraft(interval: .daily, until: now.addingTimeInterval(1800))
        XCTAssertNotNil(soon.blockingError(base: now, now: now))
        let later = AnnouncementRepeatDraft(interval: .daily, until: now.addingTimeInterval(3 * 86_400))
        XCTAssertNil(later.blockingError(base: now, now: now))
        XCTAssertNil(AnnouncementRepeatDraft(interval: .daily, until: nil).blockingError(base: now, now: now))
    }

    func testEndOfDayStaysInsideHorizon() {
        let now = Date()
        let far = AnnouncementRepeatDraft.endOfDay(now.addingTimeInterval(900 * 86_400), now: now)
        XCTAssertLessThan(far, now.addingTimeInterval(365 * 86_400))
    }

    func testWarmErrors() {
        func m(_ s: String) -> String? { AnnouncementRepeatError.message(for: AppError.networkError(s)) }
        XCTAssertTrue(m("Repeating reminders are not available")?.contains("aren't available yet") ?? false)
        XCTAssertTrue(m("A group can have at most 3 repeating announcements")?.contains("3 repeating") ?? false)
        XCTAssertTrue(m("This announcement has reached its reminder limit")?.contains("all the reminders") ?? false)
        XCTAssertNotNil(m("repeat_tz must be an IANA timezone name"))
        XCTAssertNotNil(m("repeat_until is too soon for even one reminder"))
        XCTAssertNotNil(m("Not allowed to edit this announcement"))
        XCTAssertNil(m("Server error 500"))
        XCTAssertNil(AnnouncementRepeatError.message(for: URLError(.notConnectedToInternet)))
    }

    func testEditingOtherFieldsWithExistingRepeatSendsNoRepeatKeys() throws {
        let a = try decode(#","repeat_interval":"weekly","repeat_active":true,"repeat_tz":"America/New_York""#)
        let orig = AnnouncementRepeatDraft(from: a)
        var draft = FSAnnouncementDraft(title: "new title", description: "b")
        draft.repeatChange = orig.change(from: orig)
        let o = draft.jsonObject
        XCTAssertNil(o["repeat_interval"]); XCTAssertNil(o["repeat_tz"]); XCTAssertNil(o["repeat_until"])
    }

    func testMemberIndicatorExposesOnlyCadenceAndEndDate() throws {
        let t = try decode(#","repeat_interval":"weekly","repeat_until":"2026-11-30T23:59:00+00:00","repeat_active":true,"repeat_tz":"America/New_York""#).repeatIndicator ?? ""
        XCTAssertFalse(t.contains("America/New_York"))
        XCTAssertTrue(t.hasPrefix("Repeats weekly, until "))
    }

    func testOffDraftStillEncodesTitleAndDescription() {
        var draft = FSAnnouncementDraft(title: "a", description: "b")
        draft.repeatChange = AnnouncementRepeatDraft.off.change(from: .off)
        XCTAssertEqual(draft.jsonObject["title"] as? String, "a")
        XCTAssertEqual(draft.jsonObject["description"] as? String, "b")
    }
}
