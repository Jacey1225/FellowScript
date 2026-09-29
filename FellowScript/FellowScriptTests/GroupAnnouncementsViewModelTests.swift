// GroupAnnouncementsViewModelTests.swift — testing gate for task
// 20260929-group-announcements. Exercises the real GroupAnnouncementsViewModel
// through the real NetworkService against StubURLProtocol (same harness as
// NotesLoadFailureHardeningTests). Proves the conventions the task calls out:
//   * throw-not-fabricate: a failed first load surfaces loadError, never an
//     empty "loaded" list
//   * preserve-cache-on-failed-refresh: a failed refresh keeps cached items
//   * free-limit 403 -> AppError.limitReached and gate.allowed == false
//   * non-member 403 -> removedFromGroup
//   * delete undo grace: Undo never hits the network; commit does; a server
//     rejection restores the row and sets a notice
//   * draft JSON: banner unchanged/removed/uploaded, publish_at semantics

import XCTest
@testable import FellowScript

@MainActor
final class GroupAnnouncementsViewModelTests: XCTestCase {

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

    // Unique ids per test so the real DiskCache never leaks between tests.
    private func makeVM() -> GroupAnnouncementsViewModel {
        GroupAnnouncementsViewModel(service: NetworkService.shared,
                                    groupId: "g-\(UUID().uuidString)", userId: "u-\(UUID().uuidString)")
    }

    private func item(_ id: String, published: Bool = true) -> String {
        """
        {"id":"\(id)","group_id":"g","creator_id":"u","creator_username":"ann","title":"T\(id)",
         "description":"D\(id)","banner_url":null,"publish_at":"2026-01-01T00:00:00.123456+00:00",
         "created_at":"2026-01-01T00:00:00+00:00","updated_at":"2026-01-01T00:00:00+00:00",
         "published":\(published),"can_edit":true}
        """
    }

    private func page(_ items: [String], gate: String = "null") -> Data {
        """
        {"announcements":[\(items.joined(separator: ","))],"truncated":false,"gate":\(gate)}
        """.data(using: .utf8)!
    }

    private func requests(_ method: String) -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.method == method && $0.path.contains("/announcements") }
    }

    // MARK: load

    func test_load_decodesPage_andSplitsScheduledFromPublished() async {
        StubURLProtocol.stubBody = page([item("a"), item("b", published: false)])
        let vm = makeVM()
        await vm.load()
        XCTAssertTrue(vm.loaded)
        XCTAssertEqual(vm.publishedItems.map(\.id), ["a"])
        XCTAssertEqual(vm.scheduledItems.map(\.id), ["b"])
        XCTAssertNil(vm.loadError)
        XCTAssertFalse(vm.refreshFailed)
    }

    func test_load_failureWithNoCache_setsLoadError_andNeverFabricatesEmptyLoadedState() async {
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail":"boom"}"#.data(using: .utf8)!
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.loadError, "Couldn't load announcements.")
        XCTAssertFalse(vm.loaded, "a failed first load must not look like an empty, loaded list")
        XCTAssertTrue(vm.items.isEmpty)
    }

    func test_load_failedRefresh_preservesCachedItems_andFlagsRefreshFailed() async {
        StubURLProtocol.stubBody = page([item("a")])
        let vm = makeVM()
        await vm.load()

        // Fresh VM, same ids: cache-first, then the refresh fails.
        let vm2 = GroupAnnouncementsViewModel(service: NetworkService.shared, groupId: vm.groupId, userId: vm.userId)
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail":"boom"}"#.data(using: .utf8)!
        await vm2.load()
        XCTAssertEqual(vm2.items.map(\.id), ["a"], "cached list must survive a failed refresh")
        XCTAssertTrue(vm2.refreshFailed)
        XCTAssertNil(vm2.loadError)
    }

    func test_load_notAMember403_marksRemovedFromGroup() async {
        StubURLProtocol.stubStatusCode = 403
        StubURLProtocol.stubBody = #"{"detail":"Not a member of this group"}"#.data(using: .utf8)!
        let vm = makeVM()
        await vm.load()
        XCTAssertTrue(vm.removedFromGroup)
    }

    func test_load_gateNotAllowed_setsLimitReached() async {
        StubURLProtocol.stubBody = page([item("a")], gate: #"{"allowed":false,"unlimited":false,"used":1,"limit":1,"remaining":0}"#)
        let vm = makeVM()
        await vm.load()
        XCTAssertTrue(vm.limitReached)
    }

    // MARK: save

    func test_save_create_postsDraft_andInsertsAtTop() async throws {
        StubURLProtocol.stubBody = page([item("a")])
        let vm = makeVM()
        await vm.load()
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubBody = item("new").data(using: .utf8)!
        let saved = try await vm.save(FSAnnouncementDraft(title: "Hi", description: "There", publishAt: nil), editing: nil)
        XCTAssertEqual(saved.id, "new")
        XCTAssertEqual(vm.items.first?.id, "new")
        let posts = requests("POST")
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.bodyJSON?["title"] as? String, "Hi")
        XCTAssertTrue(posts.first?.bodyJSON?["publish_at"] is NSNull, "publish now sends explicit null publish_at")
        XCTAssertNil(posts.first?.bodyJSON?["banner_key"], "unchanged banner sends no banner_key")
    }

    func test_save_freeLimit403_throwsLimitReached_andUpdatesGate_withoutAddingItem() async {
        StubURLProtocol.stubBody = page([item("a")])
        let vm = makeVM()
        await vm.load()
        StubURLProtocol.stubStatusCode = 403
        StubURLProtocol.stubBody = #"{"detail":{"resource":"announcements","used":1,"limit":1,"allowed":false}}"#.data(using: .utf8)!
        do {
            _ = try await vm.save(FSAnnouncementDraft(title: "x", description: "y"), editing: nil)
            XCTFail("expected limitReached to be thrown")
        } catch AppError.limitReached(let resource, let used, let limit) {
            XCTAssertEqual(resource, "announcements")
            XCTAssertEqual(used, 1)
            XCTAssertEqual(limit, 1)
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertTrue(vm.limitReached)
        XCTAssertEqual(vm.items.map(\.id), ["a"], "nothing fabricated on a rejected create")
    }

    func test_save_update_usesPUT_andReplacesItemInPlace() async throws {
        StubURLProtocol.stubBody = page([item("a")])
        let vm = makeVM()
        await vm.load()
        let existing = vm.items[0]
        StubURLProtocol.resetRequestLog()
        var changed = item("a"); changed = changed.replacingOccurrences(of: "\"Ta\"", with: "\"Edited\"")
        StubURLProtocol.stubBody = changed.data(using: .utf8)!
        var draft = FSAnnouncementDraft(title: "Edited", description: "Da")
        draft.includePublishAt = false
        let saved = try await vm.save(draft, editing: existing)
        XCTAssertEqual(saved.title, "Edited")
        XCTAssertEqual(vm.items.first?.title, "Edited")
        XCTAssertEqual(requests("PUT").count, 1)
        XCTAssertNil(requests("PUT").first?.bodyJSON?["publish_at"], "published items never send publish_at")
    }

    // MARK: delete with undo grace

    func test_startDelete_hidesRow_andUndoNeverCallsServer() async {
        StubURLProtocol.stubBody = page([item("a")])
        let vm = makeVM()
        await vm.load()
        StubURLProtocol.resetRequestLog()
        vm.startDelete(vm.items[0])
        XCTAssertTrue(vm.visibleItems.isEmpty)
        XCTAssertEqual(vm.undoItem?.id, "a")
        vm.undoDelete()
        XCTAssertEqual(vm.visibleItems.map(\.id), ["a"])
        XCTAssertNil(vm.undoItem)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(requests("DELETE").isEmpty, "Undo inside the grace window must not delete server-side")
    }

    func test_commitPendingDeletes_sendsDELETE_andRemovesItem() async {
        StubURLProtocol.stubBody = page([item("a")])
        let vm = makeVM()
        await vm.load()
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubBody = Data()
        vm.startDelete(vm.items[0])
        vm.commitPendingDeletes()   // what closing the view or starting another delete does
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(requests("DELETE").count, 1)
        XCTAssertTrue(requests("DELETE").first?.path.hasSuffix("/announcements/a") ?? false)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertNil(vm.undoItem)
    }

    func test_failedDelete_restoresRow_andSetsNotice() async {
        StubURLProtocol.stubBody = page([item("a")])
        let vm = makeVM()
        await vm.load()
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail":"boom"}"#.data(using: .utf8)!
        vm.startDelete(vm.items[0])
        vm.commitPendingDeletes()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.visibleItems.map(\.id), ["a"], "server rejection must restore the row, not fake success")
        XCTAssertEqual(vm.notice, "That announcement couldn't be deleted. Please try again.")
    }

    // MARK: draft JSON + dates

    func test_draft_bannerStatesAndPublishAt() {
        var d = FSAnnouncementDraft(title: "t", description: "d")
        XCTAssertNil(d.jsonObject["banner_key"])
        XCTAssertTrue(d.jsonObject["publish_at"] is NSNull)
        d.banner = .removed
        XCTAssertTrue(d.jsonObject["banner_key"] is NSNull)
        d.banner = .uploaded("group-announcements/g/k")
        XCTAssertEqual(d.jsonObject["banner_key"] as? String, "group-announcements/g/k")
        d.includePublishAt = false
        XCTAssertNil(d.jsonObject["publish_at"])
        d.includePublishAt = true
        d.publishAt = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(d.jsonObject["publish_at"] as? String, "1970-01-01T00:00:00+00:00")
    }

    func test_dates_parseServerMicrosecondIsoformat() {
        XCTAssertNotNil(FSAnnouncementDates.parse("2026-01-01T00:00:00.123456+00:00"))
        XCTAssertNotNil(FSAnnouncementDates.parse("2026-01-01T00:00:00+00:00"))
        XCTAssertNil(FSAnnouncementDates.parse("garbage"))
    }
}
