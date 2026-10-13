// NotificationSettingsTests.swift -- testing gate for task
// 20261012-notification-settings (iOS). Covers the type table / capability
// gating, parsePushPreferences (throw-not-fabricate), NotificationPreferencesModel
// (server-confirmed values, revert on failed save), and the Account entry wiring.

import XCTest
@testable import FellowScript

@MainActor
final class NotificationSettingsTests: XCTestCase {

    private let allKeys = ["messages", "pins", "reactions", "announcements", "session_reminders",
                           "join_requests", "friend_highlight", "friend_activity", "reminders"]

    private func body(_ overrides: [String: Bool] = [:], drop: [String] = []) -> Data {
        var d = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, true) })
        for (k, v) in overrides { d[k] = v }
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

    func test_typeTable_hasNineKnownKeys_noEssentialTypes() {
        XCTAssertEqual(Set(NotificationPushType.all.map { $0.key }), Set(allKeys))
        XCTAssertEqual(NotificationPushType.all.count, 9)
        XCTAssertFalse(NotificationPushType.all.contains { $0.key == "ring" })
    }

    func test_visibleGroups_hidesFlaggedTypesWhenCapabilitiesOff() {
        let keys = NotificationPushType.visibleGroups(capabilities: .allOff).flatMap { $0.types.map { $0.key } }
        for k in ["pins", "reactions", "join_requests", "friend_highlight"] { XCTAssertFalse(keys.contains(k), k) }
        XCTAssertEqual(Set(keys), ["messages", "announcements", "session_reminders", "friend_activity", "reminders"])
    }

    func test_visibleGroups_showsFlaggedTypesWhenOn() {
        let caps = FSCapabilities(features: ["message_pins": true, "friend_highlight_push": true,
                                             "message_reaction_push": true, "join_request_push": true],
                                  exploreLink: nil, termsCurrent: true)
        let keys = NotificationPushType.visibleGroups(capabilities: caps).flatMap { $0.types.map { $0.key } }
        XCTAssertEqual(Set(keys), Set(allKeys))
    }

    // MARK: parse

    func test_parse_validMap() throws {
        let m = try NetworkService.parsePushPreferences(body(["pins": false]))
        XCTAssertEqual(m.count, 9)
        XCTAssertEqual(m["pins"], false)
        XCTAssertEqual(m["messages"], true)
    }

    func test_parse_failsOnMissingKeyNonBoolAndNonObject() {
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(body(drop: ["reminders"])))
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(Data(#"{"messages":"yes"}"#.utf8)))
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(Data("[true]".utf8)))
        XCTAssertThrowsError(try NetworkService.parsePushPreferences(Data()))
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
