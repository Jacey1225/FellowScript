// NotificationSettingsTests.swift -- testing gate for task
// 20261012-notification-settings (iOS). Covers the type table / capability
// gating, parsePushPreferences (throw-not-fabricate), NotificationPreferencesModel
// (server-confirmed values, revert on failed save), and the Account entry wiring.

import XCTest
@testable import FellowScript

@MainActor
final class NotificationSettingsTests: XCTestCase {

    private let listedKeys = ["messages", "pins", "reactions", "announcements", "announcement_reminder",
                              "session_reminders", "friend_highlight", "friend_activity", "reminders"]
    private let reminderKeys = ["prayer_reminder", "check_in_reminder", "deep_question_reminder"]
    private var allKeys: [String] { listedKeys + reminderKeys }
    private let defaultTimes = ["prayer_reminder_time": "08:00",
                                "check_in_reminder_time": "12:30",
                                "deep_question_reminder_time": "19:15"]

    /// Server body: 12 toggles (reminders default false) plus the three *_time keys.
    private func body(_ overrides: [String: Bool] = [:], drop: [String] = [],
                      times: [String: String]? = nil) -> Data {
        var d: [String: Any] = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, !reminderKeys.contains($0)) })
        for (k, v) in overrides { d[k] = v }
        for (k, v) in (times ?? defaultTimes) { d[k] = v }
        for k in drop { d.removeValue(forKey: k) }
        return try! JSONSerialization.data(withJSONObject: d)
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }
    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data()
    }

    private func makeModel(userId: String = "u1") -> NotificationPreferencesModel {
        NotificationPreferencesModel(service: NetworkService.shared, userId: userId)
    }
    private func puts() -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.method == "PUT" }
    }

    // MARK: type table + capability gating

    func test_typeTable_listedKeys_noEssentialTypes_noJoinRequests() {
        XCTAssertEqual(Set(NotificationPushType.all.map { $0.key }), Set(listedKeys))
        XCTAssertEqual(NotificationPushType.all.count, 9)
        XCTAssertFalse(NotificationPushType.all.contains { $0.key == "ring" })
        XCTAssertFalse(NotificationPushType.allKeys.contains { $0.key == "join_requests" },
                       "join_requests is an always-on push now and must not be a toggle")
        XCTAssertEqual(Set(NotificationPushType.allKeys.map { $0.key }), Set(allKeys))
        XCTAssertEqual(NotificationPushType.allKeys.count, 12)
    }

    func test_visibleGroups_hidesFlaggedTypesWhenCapabilitiesOff() {
        let keys = NotificationPushType.visibleGroups(capabilities: .allOff).flatMap { $0.types.map { $0.key } }
        for k in ["pins", "reactions", "friend_highlight"] { XCTAssertFalse(keys.contains(k), k) }
        XCTAssertEqual(Set(keys), ["messages", "announcements", "announcement_reminder", "session_reminders", "friend_activity", "reminders"])
    }

    func test_visibleGroups_showsFlaggedTypesWhenOn() {
        let caps = FSCapabilities(features: ["message_pins": true, "friend_highlight_push": true,
                                             "message_reaction_push": true],
                                  exploreLink: nil, termsCurrent: true)
        let keys = NotificationPushType.visibleGroups(capabilities: caps).flatMap { $0.types.map { $0.key } }
        XCTAssertEqual(Set(keys), Set(listedKeys))
    }

    // MARK: parse

    func test_parse_validMap() throws {
        let m = try NetworkService.parsePushPreferences(body(["pins": false]))
        XCTAssertEqual(m.count, 12)
        XCTAssertNil(m["join_requests"])
        XCTAssertEqual(m["pins"], false)
        XCTAssertEqual(m["messages"], true)
    }

    func test_parse_failsOnMissingKeyNonBoolAndNonObject() {
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(body(drop: ["reminders"])))
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(body(drop: ["announcement_reminder"])))
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(body(drop: ["prayer_reminder"])))
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(Data(#"{"messages":"yes"}"#.utf8)))
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(Data("[true]".utf8)))
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(Data()))
    }

    func test_parse_ignoresStaleJoinRequestsKey() throws {
        var d = try JSONSerialization.jsonObject(with: body()) as! [String: Any]
        d["join_requests"] = true
        let m = try NetworkService.parsePushPreferences(try JSONSerialization.data(withJSONObject: d))
        XCTAssertNil(m["join_requests"])
        XCTAssertEqual(m.count, 12)
    }

    // MARK: snapshot (toggles + times) and defaults

    func test_snapshot_defaults_remindersOffAnnouncementReminderOn_andTimes() throws {
        let s = try NetworkService.parsePushPreferenceSnapshot(body())
        for k in reminderKeys { XCTAssertEqual(s.toggles[k], false, k) }
        XCTAssertEqual(s.toggles["announcement_reminder"], true)
        XCTAssertEqual(s.times, defaultTimes)
    }

    func test_snapshot_missingOrMalformedTime_throws() {
        for k in PushReminderKeys.timeKeys {
            XCTAssertThrowsError(try NetworkService.parsePushPreferenceSnapshot(body(drop: [k])), k)
        }
        for bad in ["8:00", "24:00", "12:60", "ab:cd", "12:3", "1200", "", "12:30:00", "-1:00"] {
            let t = ["prayer_reminder_time": bad, "check_in_reminder_time": "12:30", "deep_question_reminder_time": "19:15"]
            XCTAssertThrowsError(try NetworkService.parsePushPreferenceSnapshot(body(times: t)), bad)
        }
        let nonString = try! JSONSerialization.data(withJSONObject:
            Dictionary(uniqueKeysWithValues: allKeys.map { ($0, true) }).merging(
                ["prayer_reminder_time": 800, "check_in_reminder_time": "12:30", "deep_question_reminder_time": "19:15"]) { $1 })
        XCTAssertThrowsError(try NetworkService.parsePushPreferenceSnapshot(nonString))
    }

    func test_timeHelpers_validateFormatAndRoundTrip() {
        XCTAssertTrue(PushReminderKeys.isValidTime("00:00"))
        XCTAssertTrue(PushReminderKeys.isValidTime("23:59"))
        XCTAssertFalse(PushReminderKeys.isValidTime("7:05"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let d = PushReminderKeys.date(from: "07:05", calendar: cal)!
        XCTAssertEqual(PushReminderKeys.format(d, calendar: cal), "07:05")
        XCTAssertNil(PushReminderKeys.date(from: "99:99", calendar: cal))
        XCTAssertEqual(PushReminderKeys.timeKey["prayer_reminder"], "prayer_reminder_time")
        XCTAssertEqual(Set(PushReminderKeys.timeKey.values), Set(PushReminderKeys.timeKeys))
    }

    // MARK: model

    func test_model_loadReflectsServerValues() async {
        StubURLProtocol.stubBody = body(["messages": false])
        let m = makeModel()
        await m.load()
        XCTAssertTrue(m.loaded)
        XCTAssertEqual(m.prefs["messages"], false)
        XCTAssertNil(m.errorMessage)
        XCTAssertTrue(StubURLProtocol.requestLog.contains { $0.method == "GET" && $0.path.hasSuffix("/notification/u1/push-preferences") })
    }

    func test_model_loadFailure_doesNotFabricateOrSave() async {
        StubURLProtocol.stubStatusCode = 500
        let m = makeModel()
        await m.load()
        XCTAssertFalse(m.loaded)
        XCTAssertTrue(m.prefs.isEmpty)
        XCTAssertNotNil(m.errorMessage)
        await m.set("messages", false)
        XCTAssertTrue(puts().isEmpty)
    }

    func test_model_loadReflectsRemindersDefaultsAndTimes() async {
        StubURLProtocol.stubBody = body()
        let m = makeModel()
        await m.load()
        XCTAssertEqual(m.prefs["prayer_reminder"], false)
        XCTAssertEqual(m.prefs["announcement_reminder"], true)
        XCTAssertEqual(m.times["check_in_reminder_time"], "12:30")
    }

    func test_model_failedRefresh_preservesLastConfirmedState() async {
        StubURLProtocol.stubBody = body(["messages": false, "prayer_reminder": true])
        let m = makeModel()
        await m.load()
        XCTAssertTrue(m.loaded)
        StubURLProtocol.stubStatusCode = 500
        await m.load()
        XCTAssertTrue(m.loaded, "a failed refresh must not drop the loaded state")
        XCTAssertEqual(m.prefs["messages"], false)
        XCTAssertEqual(m.prefs["prayer_reminder"], true)
        XCTAssertEqual(m.times, defaultTimes)
        XCTAssertTrue(m.loadFailed)
        XCTAssertEqual(m.errorMessage, "Couldn't refresh your settings. Showing what we last loaded.")
        // Recovery clears the banner.
        StubURLProtocol.stubStatusCode = 200
        await m.load()
        XCTAssertFalse(m.loadFailed)
        XCTAssertNil(m.errorMessage)
    }

    func test_model_malformedRefresh_preservesCache() async {
        StubURLProtocol.stubBody = body()
        let m = makeModel()
        await m.load()
        StubURLProtocol.stubBody = body(drop: ["deep_question_reminder_time"])
        await m.load()
        XCTAssertEqual(m.times, defaultTimes)
        XCTAssertTrue(m.loadFailed)
    }

    func test_model_setReminderToggle_sendsSingleKey_neverJoinRequests() async {
        StubURLProtocol.stubBody = body()
        let m = makeModel()
        await m.load()
        StubURLProtocol.stubBody = body(["prayer_reminder": true])
        await m.set("prayer_reminder", true)
        XCTAssertEqual(puts().count, 1)
        XCTAssertEqual(puts().first?.bodyJSON as? [String: Bool], ["prayer_reminder": true])
        XCTAssertEqual(m.prefs["prayer_reminder"], true)
        XCTAssertFalse(StubURLProtocol.requestLog.contains { ($0.bodyJSON ?? [:]).keys.contains("join_requests") })
    }

    func test_model_setTime_savesStringAndAdoptsServerValue() async {
        StubURLProtocol.stubBody = body()
        let m = makeModel()
        await m.load()
        var t = defaultTimes; t["prayer_reminder_time"] = "06:45"
        StubURLProtocol.stubBody = body(times: t)
        await m.setTime("prayer_reminder_time", "06:45")
        XCTAssertEqual(puts().first?.bodyJSON as? [String: String], ["prayer_reminder_time": "06:45"])
        XCTAssertEqual(m.times["prayer_reminder_time"], "06:45")
        XCTAssertNil(m.errorMessage)
    }

    func test_model_setTime_failureKeepsConfirmed_invalidOrUnchangedIsNoOp() async {
        StubURLProtocol.stubBody = body()
        let m = makeModel()
        await m.load()
        await m.setTime("prayer_reminder_time", "08:00")   // unchanged
        await m.setTime("prayer_reminder_time", "8:0")     // invalid
        XCTAssertTrue(puts().isEmpty)
        StubURLProtocol.stubStatusCode = 500
        await m.setTime("prayer_reminder_time", "09:00")
        XCTAssertEqual(m.times["prayer_reminder_time"], "08:00")
        XCTAssertEqual(m.errorMessage, "Couldn't save. Please try again.")
        XCTAssertNil(m.savingKey)
    }

    func test_model_malformedBody_isLoadFailure() async {
        StubURLProtocol.stubBody = Data(#"{"messages":true}"#.utf8)
        let m = makeModel()
        await m.load()
        XCTAssertFalse(m.loaded)
        XCTAssertNotNil(m.errorMessage)
    }

    func test_model_setSuccess_sendsSingleKeyAndAdoptsServerMap() async {
        StubURLProtocol.stubBody = body()
        let m = makeModel()
        await m.load()
        StubURLProtocol.stubBody = body(["pins": false])
        await m.set("pins", false)
        XCTAssertEqual(puts().count, 1)
        XCTAssertEqual(puts().first?.bodyJSON as? [String: Bool], ["pins": false])
        XCTAssertEqual(m.prefs["pins"], false)
        XCTAssertNil(m.errorMessage)
        XCTAssertNil(m.savingKey)
    }

    func test_model_setFailure_keepsConfirmedValueAndShowsError() async {
        StubURLProtocol.stubBody = body()
        let m = makeModel()
        await m.load()
        StubURLProtocol.stubStatusCode = 500
        await m.set("messages", false)
        XCTAssertEqual(m.prefs["messages"], true)
        XCTAssertNotNil(m.errorMessage)
        XCTAssertNil(m.savingKey)
    }

    func test_model_noOpWhenUnchangedOrEmptyUser() async {
        StubURLProtocol.stubBody = body()
        let m = makeModel()
        await m.load()
        await m.set("messages", true)
        XCTAssertTrue(puts().isEmpty)
        StubURLProtocol.resetRequestLog()
        let empty = makeModel(userId: "")
        await empty.load()
        XCTAssertFalse(empty.loaded)
        XCTAssertTrue(StubURLProtocol.requestLog.isEmpty)
    }

    // MARK: Account wiring (source-pinned)

    func test_accountView_pushesNotificationSettingsFromEntryRow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let acct = try String(contentsOf: root.appendingPathComponent("FellowScript/Account/AccountView.swift"), encoding: .utf8)
        XCTAssertTrue(acct.contains("notificationsSection"))
        XCTAssertTrue(acct.contains("NotificationSettingsView("))
        let misc = try String(contentsOf: root.appendingPathComponent("FellowScript/Account/AccountView+Misc.swift"), encoding: .utf8)
        XCTAssertTrue(misc.contains("showNotificationSettings = true"))
    }
}
