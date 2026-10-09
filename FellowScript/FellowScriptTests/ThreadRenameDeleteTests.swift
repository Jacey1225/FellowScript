// ThreadRenameDeleteTests.swift -- task 20261008-thread-rename-delete, testing
// step 4. Permissions (creator-only rename, creator-or-owner delete), title
// validation, the rename/delete view-model logic (list + cache consistency,
// throw-not-fabricate, preserve rows on failure, 404 handling) and the
// thread_deleted WebSocket frame / stale-thread handling in the open thread.

import XCTest
@testable import FellowScript

/// Seam for the rename / delete protocol methods on the shared test double.
enum RenameDeleteSeam {
    static var renameError: Error?
    static var renameResultTitle: String?   // nil -> echo the requested title
    static var deleteError: Error?
    static var log: [String] = []
    static func reset() { renameError = nil; renameResultTitle = nil; deleteError = nil; log = [] }
}

extension ThrowingTestDataService {
    func renameThread(userId: String, groupId: String, threadId: String, title: String) async throws -> FSThreadSummary {
        RenameDeleteSeam.log.append("rename:\(threadId):\(title)")
        if let e = RenameDeleteSeam.renameError { throw e }
        return FSThreadSummary(id: threadId, title: RenameDeleteSeam.renameResultTitle ?? title)
    }
    func deleteThread(userId: String, groupId: String, threadId: String) async throws {
        RenameDeleteSeam.log.append("delete:\(threadId)")
        if let e = RenameDeleteSeam.deleteError { throw e }
    }
}

// MARK: - Permissions + validation (pure policy)

final class ThreadRenameDeletePolicyTests: XCTestCase {
    private func t(by: String?) -> FSThreadSummary { FSThreadSummary(id: "t", createdBy: by) }

    func test_rename_isCreatorOnly_caseInsensitive_evenForTheGroupOwner() {
        XCTAssertTrue(FSThreadPolicy.canRename(t(by: "Alice"), username: "alice"))
        XCTAssertFalse(FSThreadPolicy.canRename(t(by: "alice"), username: "bob"), "another member cannot rename")
        // The owner is not special for rename (server rule is creator only).
        XCTAssertFalse(FSThreadPolicy.canRename(t(by: "alice"), username: "owner"))
    }

    func test_rename_failsClosed_whenCreatorOrUserUnknown() {
        XCTAssertFalse(FSThreadPolicy.canRename(t(by: nil), username: "alice"))
        XCTAssertFalse(FSThreadPolicy.canRename(t(by: ""), username: "alice"))
        XCTAssertFalse(FSThreadPolicy.canRename(t(by: "alice"), username: nil))
        XCTAssertFalse(FSThreadPolicy.canRename(t(by: "alice"), username: ""))
        XCTAssertFalse(FSThreadPolicy.canRename(t(by: nil), username: nil))
    }

    func test_delete_isCreatorOrOwner_only() {
        XCTAssertTrue(FSThreadPolicy.canDelete(t(by: "alice"), username: "alice", isOwner: false), "creator")
        XCTAssertTrue(FSThreadPolicy.canDelete(t(by: "alice"), username: "owner", isOwner: true), "group owner")
        XCTAssertFalse(FSThreadPolicy.canDelete(t(by: "alice"), username: "bob", isOwner: false), "plain member")
        XCTAssertFalse(FSThreadPolicy.canDelete(t(by: nil), username: "bob", isOwner: false), "unknown creator, not owner")
        XCTAssertTrue(FSThreadPolicy.canDelete(t(by: nil), username: nil, isOwner: true), "owner can delete even when creator is unknown")
    }

    func test_validTitle_trims_andEnforcesServerBounds() {
        XCTAssertEqual(FSThreadPolicy.validTitle("  Plan  "), "Plan")
        XCTAssertNil(FSThreadPolicy.validTitle(""))
        XCTAssertNil(FSThreadPolicy.validTitle("   \n "))
        XCTAssertNotNil(FSThreadPolicy.validTitle(String(repeating: "a", count: FSThreadPolicy.titleMaxLength)))
        XCTAssertNil(FSThreadPolicy.validTitle(String(repeating: "a", count: FSThreadPolicy.titleMaxLength + 1)))
        XCTAssertNil(FSThreadPolicy.validTitle("a\u{0}b"))
        XCTAssertEqual(FSThreadPolicy.titleMaxLength, 80, "must match api/config/chat.json threads.title_max_length")
    }

    func test_titleMaxLength_matchesServerConfig() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cfg = root.appendingPathComponent("api/config/chat.json")
        guard FileManager.default.fileExists(atPath: cfg.path) else { throw XCTSkip("api/config/chat.json not reachable from the test bundle path") }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: cfg)) as? [String: Any]
        let threads = json?["threads"] as? [String: Any]
        XCTAssertEqual(threads?["title_max_length"] as? Int, FSThreadPolicy.titleMaxLength)
    }

    func test_changeNotification_roundTrips() {
        let exp = expectation(description: "posted")
        let want = FSThreadChange(groupId: "g", threadId: "t", kind: .renamed("New"))
        let token = NotificationCenter.default.addObserver(forName: FSThreadChange.notification, object: nil, queue: nil) { n in
            if FSThreadChange.from(n) == want { exp.fulfill() }
        }
        want.post()
        wait(for: [exp], timeout: 2)
        NotificationCenter.default.removeObserver(token)
    }
}

// MARK: - Group threads list view model

@MainActor
final class GroupThreadsRenameDeleteViewModelTests: XCTestCase {
    override func setUp() { ThreadsSeam.reset(); RenameDeleteSeam.reset() }

    private func g() -> String { "g-\(UUID().uuidString)" }
    private func loadedVM(_ s: ThrowingTestDataService, group: String, ids: [String] = ["a", "b", "c"]) async -> GroupThreadsViewModel {
        ThreadsSeam.threadsPages = [FSThreadsPage(threads: ids.map { FSThreadSummary(id: $0, title: "T-\($0)", createdBy: "me") },
                                                  hasMore: false, cursorTimestamp: nil, cursorId: nil)]
        let vm = GroupThreadsViewModel(service: s, groupId: group, userId: "u")
        await vm.load()
        return vm
    }
    private func eventually(_ what: String, timeout: TimeInterval = 3, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; try? await Task.sleep(nanoseconds: 25_000_000) }
        XCTFail("timed out waiting: \(what)")
    }

    func test_delete_callsService_thenRemovesTheRow_andPersistsTheCache() async throws {
        let s = ThrowingTestDataService(); let group = g()
        let vm = await loadedVM(s, group: group)
        try await vm.delete(FSThreadSummary(id: "b"))
        XCTAssertTrue(RenameDeleteSeam.log.contains("delete:b"))
        await eventually("row b removed") { vm.threads.map(\.id) == ["a", "c"] }
        // The persisted cache must not bring the deleted thread back when the next refresh fails.
        ThreadsSeam.threadsError = FSThreadsError.failed("down")
        let vm2 = GroupThreadsViewModel(service: s, groupId: group, userId: "u")
        await vm2.load()
        XCTAssertTrue(vm2.loadFailed)
        XCTAssertEqual(vm2.threads.map(\.id), ["a", "c"], "cache was updated with the delete (no resurrection on failed refresh)")
    }

    func test_delete_failure_throws_andLeavesRowsUntouched() async {
        let s = ThrowingTestDataService(); let group = g()
        let vm = await loadedVM(s, group: group)
        RenameDeleteSeam.deleteError = FSThreadsError.failed("Couldn't delete that thread. Please try again.")
        do { try await vm.delete(FSThreadSummary(id: "a")); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? FSThreadsError, .failed("Couldn't delete that thread. Please try again.")) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.threads.map(\.id), ["a", "b", "c"], "throw-not-fabricate: nothing removed on failure")
    }

    func test_delete_404_throwsNotFound_butDropsTheStaleRow() async {
        let s = ThrowingTestDataService(); let group = g()
        let vm = await loadedVM(s, group: group)
        RenameDeleteSeam.deleteError = FSThreadsError.notFound
        do { try await vm.delete(FSThreadSummary(id: "c")); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? FSThreadsError, .notFound) }
        await eventually("stale row c dropped") { vm.threads.map(\.id) == ["a", "b"] }
    }

    func test_rename_trimsAndSends_thenUpdatesRowTitle() async throws {
        let s = ThrowingTestDataService(); let group = g()
        let vm = await loadedVM(s, group: group)
        try await vm.rename(FSThreadSummary(id: "a"), to: "  New name  ")
        XCTAssertTrue(RenameDeleteSeam.log.contains("rename:a:New name"), "trimmed title is what is sent")
        await eventually("title updated") { vm.threads.first(where: { $0.id == "a" })?.title == "New name" }
        XCTAssertEqual(vm.threads.map(\.id), ["a", "b", "c"], "order unchanged")
    }

    func test_rename_usesTheServerReturnedTitle() async throws {
        let s = ThrowingTestDataService(); let group = g()
        let vm = await loadedVM(s, group: group)
        RenameDeleteSeam.renameResultTitle = "Server normalised"
        try await vm.rename(FSThreadSummary(id: "a"), to: "x   y")
        await eventually("server title applied") { vm.threads.first(where: { $0.id == "a" })?.title == "Server normalised" }
    }

    func test_rename_invalidTitle_throwsLocally_andNeverCallsTheService() async {
        let s = ThrowingTestDataService(); let group = g()
        let vm = await loadedVM(s, group: group)
        for bad in ["", "   ", String(repeating: "x", count: 81)] {
            do { try await vm.rename(FSThreadSummary(id: "a"), to: bad); XCTFail("must throw for \(bad.count) chars") }
            catch { XCTAssertTrue(error is FSThreadsError) }
        }
        XCTAssertFalse(RenameDeleteSeam.log.contains { $0.hasPrefix("rename:") }, "validation happens before any request")
        XCTAssertEqual(vm.threads.first?.title, "T-a")
    }

    func test_rename_failure_throws_andKeepsTheOldTitle() async {
        let s = ThrowingTestDataService(); let group = g()
        let vm = await loadedVM(s, group: group)
        RenameDeleteSeam.renameError = FSThreadsError.notFound
        do { try await vm.rename(FSThreadSummary(id: "a"), to: "Fine"); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? FSThreadsError, .notFound) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.threads.first?.title, "T-a")
    }

    func test_changeForAnotherGroup_isIgnored_andRepeatedDeleteIsIdempotent() async {
        let s = ThrowingTestDataService(); let group = g()
        let vm = await loadedVM(s, group: group)
        await vm.apply(FSThreadChange(groupId: "some-other-group", threadId: "a", kind: .deleted))
        XCTAssertEqual(vm.threads.map(\.id), ["a", "b", "c"])
        await vm.apply(FSThreadChange(groupId: group.uppercased(), threadId: "a", kind: .deleted))
        await vm.apply(FSThreadChange(groupId: group, threadId: "a", kind: .deleted))
        XCTAssertEqual(vm.threads.map(\.id), ["b", "c"], "group match is case-insensitive; a repeat is a no-op")
        await vm.apply(FSThreadChange(groupId: group, threadId: "zzz", kind: .renamed("x")))
        XCTAssertEqual(vm.threads.map(\.title), ["T-b", "T-c"], "rename of an unknown thread changes nothing")
    }

    func test_twoListsForTheSameGroup_staySynchronised() async throws {
        // The group-list dropdown and the info section each own a VM for the same group.
        let s = ThrowingTestDataService(); let group = g()
        let infoSection = await loadedVM(s, group: group)
        let dropdown = await loadedVM(s, group: group)
        try await infoSection.rename(FSThreadSummary(id: "a"), to: "Renamed")
        await eventually("dropdown sees rename") { dropdown.threads.first?.title == "Renamed" }
        try await infoSection.delete(FSThreadSummary(id: "b"))
        await eventually("dropdown sees delete") { dropdown.threads.map(\.id) == ["a", "c"] }
        await eventually("info section sees delete") { infoSection.threads.map(\.id) == ["a", "c"] }
    }
}

// MARK: - Open thread view model: thread_deleted frame, stale thread, rename sync

@MainActor
final class ChatThreadDeletedHandlingTests: XCTestCase {
    override func setUp() { ThreadsSeam.reset(); RenameDeleteSeam.reset() }

    private let group = FSContact(id: "group-1", name: "G", type: .group, toUsers: ["me", "x"])
    private func service(ws: String = "ws://127.0.0.1:1") -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.wsBaseOverride = ws
        s.historyResult = .paged(FSMessagePage(messages: [FSMessage(id: "m1", text: "hi", mine: false, sender: "alice", timestamp: "2026-10-01T10:00:00Z")],
                                               hasMore: false, cursor: nil))
        return s
    }
    private func caps() -> FSCapabilities {
        FSCapabilities(features: ["threads": true, "message_delete": true, "chat_pagination": true], exploreLink: nil, termsCurrent: true)
    }
    private func eventually(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("timed out waiting: \(what)")
    }

    func test_threadDeletedFrame_leavesTheOpenThread_withANonAlarmingNotice_andBroadcasts() async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = service(ws: "ws://127.0.0.1:\(port)"); let user = "ws-\(UUID().uuidString)"
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: group, userId: user, capabilities: caps())
        try await server.waitForConnection()
        ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [], hasMore: false, cursor: nil)
        await vm.openThread(FSThreadSummary(id: "t1", title: "Plan"), service: s, contact: group, userId: user)
        XCTAssertTrue(vm.isThreadOpen)

        var broadcast: [FSThreadChange] = []
        let token = NotificationCenter.default.addObserver(forName: FSThreadChange.notification, object: nil, queue: .main) { n in
            if let c = FSThreadChange.from(n) { broadcast.append(c) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Another thread and another group: ignored.
        try server.sendFrame(["type": "thread_deleted", "thread_id": "other", "group_id": "group-1"])
        try server.sendFrame(["type": "thread_deleted", "thread_id": "t1", "group_id": "not-this-group"])
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(vm.isThreadOpen, "frames for another thread / group must not close the viewed thread")
        XCTAssertNil(vm.threadGoneNotice)

        try server.sendFrame(["type": "thread_deleted", "thread_id": "T1", "group_id": "GROUP-1"])
        await eventually("thread closed") { !vm.isThreadOpen }
        XCTAssertEqual(vm.threadGoneNotice, "That thread was deleted.")
        XCTAssertEqual(vm.messages.map(\.id), ["m1"], "main chat restored from the stash")
        XCTAssertTrue(broadcast.contains(FSThreadChange(groupId: "group-1", threadId: "t1", kind: .deleted)) ||
                      broadcast.contains(FSThreadChange(groupId: "group-1", threadId: "T1", kind: .deleted)),
                      "lists are told: \(broadcast)")
        vm.disconnect()
    }

    func test_openingAStaleThread_404_dropsItGracefully_notAnErrorState() async {
        let s = service(); let user = "stale-\(UUID().uuidString)"
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: group, userId: user, capabilities: caps())
        ThreadsSeam.threadMessagesError = FSThreadsError.notFound
        var told = false
        let token = NotificationCenter.default.addObserver(forName: FSThreadChange.notification, object: nil, queue: nil) { n in
            if let c = FSThreadChange.from(n), c.kind == .deleted, c.threadId == "gone" { told = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await vm.openThread(FSThreadSummary(id: "gone", title: "Old"), service: s, contact: group, userId: user)
        XCTAssertFalse(vm.isThreadOpen, "a deleted thread (stale pendingThreadOpen / deep link) is left")
        XCTAssertEqual(vm.threadGoneNotice, "That thread was deleted.")
        XCTAssertFalse(vm.threadLoadFailed, "not a retryable error state")
        XCTAssertTrue(told, "cached lists are told to drop it")
        vm.disconnect()
    }

    func test_otherLoadFailure_stillShowsTheRetryableErrorState() async {
        let s = service(); let user = "fail-\(UUID().uuidString)"
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: group, userId: user, capabilities: caps())
        ThreadsSeam.threadMessagesError = FSThreadsError.failed("down")
        await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: group, userId: user)
        XCTAssertTrue(vm.isThreadOpen)
        XCTAssertTrue(vm.threadLoadFailed)
        XCTAssertNil(vm.threadGoneNotice)
        vm.disconnect()
    }

    func test_renameElsewhere_updatesTheOpenThreadHeader_onlyForThatThread() async {
        let s = service(); let user = "rn-\(UUID().uuidString)"
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: group, userId: user, capabilities: caps())
        ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [], hasMore: false, cursor: nil)
        await vm.openThread(FSThreadSummary(id: "t1", title: "Old"), service: s, contact: group, userId: user)
        vm.applyThreadRename(threadId: "other", title: "Nope")
        XCTAssertEqual(vm.activeThread?.title, "Old")
        vm.applyThreadRename(threadId: "t1", title: "New")
        XCTAssertEqual(vm.activeThread?.title, "New")
        vm.disconnect()
    }
}
