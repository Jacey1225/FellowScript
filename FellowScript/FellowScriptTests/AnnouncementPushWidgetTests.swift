// AnnouncementPushWidgetTests.swift — testing gate for task
// 20260929-announcement-push-widget. Covers:
//   * widget view model: latest fetch decode, dismiss (per device, keyed by id,
//     newer id reappears), throw-not-fabricate + preserve-cache-on-failed-refresh
//   * push tap: AppDelegate `action == "announcement"` branch (source-pinned,
//     same technique as ChatPushDeepLinkTapTests), identifiers only
//   * AppState.openAnnouncement: opens the group chat and records the pending
//     viewer open; empty announcement id falls back to the chat only

import XCTest
@testable import FellowScript

@MainActor
final class AnnouncementPushWidgetTests: XCTestCase {

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
    }

    private func makeVM() -> GroupAnnouncementWidgetViewModel {
        GroupAnnouncementWidgetViewModel(service: NetworkService.shared,
                                         groupId: "g-\(UUID().uuidString)", userId: "u-\(UUID().uuidString)")
    }

    private func itemJSON(_ id: String, published: Bool = true) -> String {
        """
        {"id":"\(id)","group_id":"g","creator_id":"u","creator_username":"ann","title":"T\(id)",
         "description":"D\(id)","banner_url":null,"publish_at":"2026-01-01T00:00:00.123456+00:00",
         "created_at":"2026-01-01T00:00:00+00:00","updated_at":"2026-01-01T00:00:00+00:00",
         "published":\(published),"can_edit":true}
        """
    }

    private func latest(_ item: String?) -> Data {
        "{\"announcement\":\(item ?? "null")}".data(using: .utf8)!
    }

    private func signedIn(userId: String = "user-me") -> AppState {
        let s = AppState(service: MockDataService.shared)
        s.currentUser = FSUser(user_id: userId, username: "me", email: "me@example.com")
        s.isAuthenticated = true
        return s
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: widget view model

    func test_load_decodesLatest_andIsVisible() async {
        StubURLProtocol.stubBody = latest(itemJSON("a"))
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.visibleItem?.id, "a")
        XCTAssertTrue(StubURLProtocol.requestLog.contains { $0.method == "GET" && $0.path.hasSuffix("/announcements/latest") })
    }

    func test_load_nullAnnouncement_showsNothing() async {
        StubURLProtocol.stubBody = latest(nil)
        let vm = makeVM()
        await vm.load()
        XCTAssertNil(vm.visibleItem)
    }

    func test_unpublishedItem_isNotVisible() async {
        StubURLProtocol.stubBody = latest(itemJSON("a", published: false))
        let vm = makeVM()
        await vm.load()
        XCTAssertNil(vm.visibleItem)
    }

    func test_dismiss_hidesItem_persistsPerDevice_andNewerIdReappears() async {
        StubURLProtocol.stubBody = latest(itemJSON("a"))
        let vm = makeVM()
        await vm.load()
        vm.dismiss()
        XCTAssertNil(vm.visibleItem)

        // Same user+group, fresh VM: still dismissed for id "a".
        let vm2 = GroupAnnouncementWidgetViewModel(service: NetworkService.shared, groupId: vm.groupId, userId: vm.userId)
        await vm2.load()
        XCTAssertNil(vm2.visibleItem, "dismissal persists on this device")

        StubURLProtocol.stubBody = latest(itemJSON("b"))
        await vm2.load()
        XCTAssertEqual(vm2.visibleItem?.id, "b", "a newer announcement id reappears after dismissal")
        UserDefaults.standard.removeObject(forKey: "fs.announcementDismissed.\(vm.userId).\(vm.groupId)")
    }

    func test_failedFirstLoad_showsNothing_neverFabricates() async {
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail":"boom"}"#.data(using: .utf8)!
        let vm = makeVM()
        await vm.load()
        XCTAssertNil(vm.item)
        XCTAssertNil(vm.visibleItem)
    }

    func test_failedRefresh_preservesPreviouslyShownItem() async {
        StubURLProtocol.stubBody = latest(itemJSON("a"))
        let vm = makeVM()
        await vm.load()
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail":"boom"}"#.data(using: .utf8)!
        await vm.load()
        XCTAssertEqual(vm.visibleItem?.id, "a", "a failed refresh keeps the shown widget")

        // Cache-first for a fresh VM with the same ids while the refresh fails.
        let vm2 = GroupAnnouncementWidgetViewModel(service: NetworkService.shared, groupId: vm.groupId, userId: vm.userId)
        await vm2.load()
        XCTAssertEqual(vm2.visibleItem?.id, "a")
    }

    func test_fetchById_returnsNilWhenGone() async {
        StubURLProtocol.stubStatusCode = 404
        StubURLProtocol.stubBody = #"{"detail":"Announcement not found"}"#.data(using: .utf8)!
        let vm = makeVM()
        let gone = await vm.fetch(id: "missing")
        XCTAssertNil(gone)
    }

    func test_fetchById_returnsItem() async {
        StubURLProtocol.stubBody = itemJSON("z").data(using: .utf8)!
        let vm = makeVM()
        let got = await vm.fetch(id: "z")
        XCTAssertEqual(got?.id, "z")
    }

    // MARK: AppState.openAnnouncement

    func test_openAnnouncement_opensGroupChat_andRecordsPendingOpen() {
        let s = signedIn()
        s.openAnnouncement(groupId: "g1", announcementId: "a1")
        XCTAssertEqual(s.pendingChatContact?.id, "g1")
        XCTAssertEqual(s.pendingChatContact?.type, .group)
        XCTAssertEqual(s.pendingAnnouncementOpen, PendingAnnouncementOpen(groupId: "g1", announcementId: "a1"))
    }

    func test_openAnnouncement_emptyAnnouncementId_fallsBackToChatOnly() {
        let s = signedIn()
        s.openAnnouncement(groupId: "g1", announcementId: "")
        XCTAssertEqual(s.pendingChatContact?.id, "g1")
        XCTAssertNil(s.pendingAnnouncementOpen)
    }

    func test_openAnnouncement_emptyGroupId_doesNothing() {
        let s = signedIn()
        s.openAnnouncement(groupId: "", announcementId: "a1")
        XCTAssertNil(s.pendingChatContact)
        XCTAssertNil(s.pendingAnnouncementOpen)
    }

    // MARK: AppDelegate push-tap dispatch (source-pinned)

    private func didReceiveBody() throws -> String {
        let source = try readSource("FellowScript/FellowScriptApp.swift")
        guard let start = source.range(of: "func userNotificationCenter(_ center: UNUserNotificationCenter,\n                                didReceive response:") else {
            XCTFail("didReceive response: handler not found"); return ""
        }
        let end = source.range(of: "\n}", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        return String(source[start.upperBound..<end])
    }

    func test_appDelegate_announcementBranch_postsAnnouncementPushTapped_withIdentifiersOnly() throws {
        let body = try didReceiveBody()
        guard let r = body.range(of: "action == \"announcement\"") else { XCTFail("announcement branch missing"); return }
        let after = String(body[r.upperBound...])
        let end = after.range(of: "} else if")?.lowerBound ?? after.endIndex
        let branch = String(after[..<end])
        XCTAssertTrue(branch.contains(".announcementPushTapped"))
        XCTAssertTrue(branch.contains("AnnouncementPushTarget"))
        XCTAssertTrue(branch.contains("announcement_id"))
        XCTAssertFalse(branch.contains(".sessionPushTapped"), "must not be routed as a plain session push")
    }

    func test_appDelegate_branchOrdering_ringThenAnnouncementThenMessage() throws {
        let body = try didReceiveBody()
        guard let ring = body.range(of: "action == \"ring\""),
              let ann = body.range(of: "action == \"announcement\""),
              let msg = body.range(of: "action == \"message\""),
              let dev = body.range(of: "data[\"devotion_id\"] != nil") else {
            XCTFail("expected branches missing"); return
        }
        XCTAssertTrue(ring.lowerBound < ann.lowerBound)
        XCTAssertTrue(ann.lowerBound < msg.lowerBound)
        XCTAssertTrue(msg.lowerBound < dev.lowerBound, "pre-existing message/session branches remain intact")
    }

    func test_announcementPushTapped_roundTripsThroughNotificationCenter() {
        let exp = expectation(description: "observer")
        var received: AnnouncementPushTarget?
        let token = NotificationCenter.default.addObserver(forName: .announcementPushTapped, object: nil, queue: .main) { n in
            received = n.object as? AnnouncementPushTarget
            exp.fulfill()
        }
        NotificationCenter.default.post(name: .announcementPushTapped,
                                        object: AnnouncementPushTarget(groupId: "g1", announcementId: "a1"))
        wait(for: [exp], timeout: 2)
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(received?.groupId, "g1")
        XCTAssertEqual(received?.announcementId, "a1")
    }

    // MARK: widget placement (groups only)

    func test_chatThreadView_insertsWidgetForGroupsOnly() throws {
        let src = try readSource("FellowScript/Chat/ChatThreadView.swift")
        guard let r = src.range(of: "GroupAnnouncementWidgetView(") else { XCTFail("widget not inserted"); return }
        let before = String(src[..<r.lowerBound].suffix(250))
        XCTAssertTrue(before.contains(".group"), "widget must be guarded by a group-type check, not shown in DMs")
    }
}
