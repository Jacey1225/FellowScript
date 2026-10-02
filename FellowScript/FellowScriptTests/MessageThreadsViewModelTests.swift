// MessageThreadsViewModelTests.swift -- task 20261001-message-threads,
// testing step 11. Pure policy + view-model behaviour for iOS threads and
// message delete: menu-item matrix, single-socket mode switching (stash /
// restore, main-chat frames while a thread is open), 'Original message
// deleted' header state, optimistic delete rollback + undo window, thread ack
// and terms_reaccept_required handling (real local WebSocket), the group-info
// registry order and threads capability gate, the threads list view model,
// and push routing.
// Not asserted (known limits): live root-deleted header only for threads
// created this session; collapse-on-scroll and tap-root-to-jump are not built;
// the 10 s toast timer itself is view code (the window comes from the server).

import XCTest
@testable import FellowScript

/// Seam for the threads protocol methods on the shared test double. Static so
/// no stored property is needed on ThrowingTestDataService.
enum ThreadsSeam {
    static var threadPages: [String: FSMessagePage] = [:]      // threadId -> page
    static var threadMessagesError: Error?
    static var threadsPages: [FSThreadsPage] = []              // consumed in order
    static var threadsError: Error?
    static var createResult: FSThreadSummary?
    static var createError: Error?
    static var deleteResult = FSMessageDeleteResult(id: "", undoSeconds: 10)
    static var deleteError: Error?
    static var restoreError: Error?
    static var log: [String] = []
    static func reset() {
        threadPages = [:]; threadMessagesError = nil; threadsPages = []; threadsError = nil
        createResult = nil; createError = nil
        deleteResult = FSMessageDeleteResult(id: "", undoSeconds: 10); deleteError = nil; restoreError = nil
        log = []
    }
}

extension ThrowingTestDataService {
    func fetchThreads(userId: String, groupId: String, limit: Int, cursorTimestamp: String?, cursorId: String?) async throws -> FSThreadsPage {
        ThreadsSeam.log.append("list:\(cursorId ?? "-")")
        if let e = ThreadsSeam.threadsError { throw e }
        if ThreadsSeam.threadsPages.isEmpty { return FSThreadsPage(threads: [], hasMore: false, cursorTimestamp: nil, cursorId: nil) }
        return ThreadsSeam.threadsPages.removeFirst()
    }
    func createThread(userId: String, groupId: String, messageId: String) async throws -> FSThreadSummary {
        ThreadsSeam.log.append("create:\(messageId)")
        if let e = ThreadsSeam.createError { throw e }
        return ThreadsSeam.createResult ?? FSThreadSummary(id: "t-new", rootMessageId: messageId)
    }
    func fetchThreadMessages(userId: String, groupId: String, threadId: String, limit: Int, cursor: FSMessageCursor?) async throws -> FSMessagePage {
        ThreadsSeam.log.append("msgs:\(threadId)")
        if let e = ThreadsSeam.threadMessagesError { throw e }
        return ThreadsSeam.threadPages[threadId] ?? FSMessagePage(messages: [], hasMore: false, cursor: nil)
    }
    func deleteGroupMessage(userId: String, groupId: String, messageId: String) async throws -> FSMessageDeleteResult {
        ThreadsSeam.log.append("delete:\(messageId)")
        if let e = ThreadsSeam.deleteError { throw e }
        return FSMessageDeleteResult(id: messageId, undoSeconds: ThreadsSeam.deleteResult.undoSeconds)
    }
    func restoreGroupMessage(userId: String, groupId: String, messageId: String) async throws {
        ThreadsSeam.log.append("restore:\(messageId)")
        if let e = ThreadsSeam.restoreError { throw e }
    }
}

// MARK: - Menu item matrix (pure policy)

final class MessageThreadsActionPolicyTests: XCTestCase {

    private func msg(mine: Bool, text: String = "hello", kind: String? = nil, url: String? = nil, meta: FSAttachmentMeta? = nil) -> FSMessage {
        FSMessage(id: "m", text: text, mine: mine, sender: mine ? "" : "alice", timestamp: "2026-10-01T10:00:00Z",
                  attachmentKind: kind, attachmentURL: url, attachmentMeta: meta)
    }
    private func ctx(group: Bool = true, thread: Bool = false, threads: Bool = true, del: Bool = true,
                     settled: Bool = true, sender: String? = "u-alice") -> FSMessageActionContext {
        FSMessageActionContext(isGroup: group, inThread: thread, threadsEnabled: threads, messageDeleteEnabled: del,
                               isSettled: settled, senderUserId: sender)
    }

    func test_threadMessages_areCopyOnly_forOwnAndOthers_evenWithEveryFlagOn() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx(thread: true)), [.copy])
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: false), in: ctx(thread: true)), [.copy])
    }

    func test_mainChat_ownMessage_startThreadCopyDelete_inOrder() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx()), [.startThread, .copy, .delete])
    }

    func test_mainChat_ownMessage_respectsEachFlagIndependently() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx(threads: false)), [.copy, .delete])
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx(del: false)), [.startThread, .copy])
    }

    func test_mainChat_othersMessage_copyStartThreadReportBlock_neverDelete() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: false), in: ctx()), [.copy, .startThread, .report, .block])
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(mine: false), in: ctx(del: true)).contains(.delete))
    }

    func test_othersMessage_reportBlockHidden_whenSenderIdCannotBeResolved() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: false), in: ctx(sender: nil)), [.copy, .startThread])
    }

    func test_flagsFalseOrMissing_noStartThreadAndNoDelete_anywhere() {
        for mine in [true, false] {
            let a = FSMessageActionPolicy.actions(for: msg(mine: mine), in: ctx(threads: false, del: false))
            XCTAssertFalse(a.contains(.startThread), "mine=\(mine)")
            XCTAssertFalse(a.contains(.delete), "mine=\(mine)")
        }
        // Missing flag == capabilities.isEnabled false (fail closed).
        let missing = FSCapabilities.allOff
        XCTAssertFalse(missing.isEnabled("threads"))
        XCTAssertFalse(missing.isEnabled("message_delete"))
        let c = ctx(threads: missing.isEnabled("threads"), del: missing.isEnabled("message_delete"))
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: c), [.copy])
    }

    func test_dm_isCopyOnly() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx(group: false)), [.copy])
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: false), in: ctx(group: false)), [.copy])
    }

    func test_unsettledMessage_offersNoThreadDeleteReportBlock() {
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: true), in: ctx(settled: false)), [.copy])
        XCTAssertEqual(FSMessageActionPolicy.actions(for: msg(mine: false), in: ctx(settled: false)), [.copy])
    }

    func test_copy_omittedForImageVideoFile_gifCopiesUrl_textOnlyEmptyHasNothing() {
        XCTAssertNil(msg(mine: true, text: "cap", kind: "image", url: "https://x/i.png").copyableText)
        XCTAssertNil(msg(mine: true, kind: "video", url: "https://x/v.mp4").copyableText)
        XCTAssertNil(msg(mine: true, kind: "file", url: "https://x/f.pdf").copyableText)
        XCTAssertEqual(msg(mine: true, kind: "gif", url: "https://x/g.gif").copyableText, "https://x/g.gif")
        XCTAssertNil(msg(mine: true, text: "").copyableText)
        XCTAssertFalse(FSMessageActionPolicy.actions(for: msg(mine: true, kind: "image", url: "u"), in: ctx()).contains(.copy))
    }

    func test_actionKind_titles_andDestructiveFlags() {
        XCTAssertEqual(FSMessageActionKind.startThread.title, "Start thread")
        XCTAssertEqual(FSMessageActionKind.copy.title, "Copy")
        XCTAssertEqual(FSMessageActionKind.delete.title, "Delete")
        XCTAssertTrue(FSMessageActionKind.delete.isDestructive)
        XCTAssertTrue(FSMessageActionKind.block.isDestructive)
        XCTAssertFalse(FSMessageActionKind.copy.isDestructive)
    }

    // MARK: pure helpers

    func test_insertRestored_placesByTimeOrdersAndDedups() {
        func m(_ id: String, _ ts: String) -> FSMessage { FSMessage(id: id, text: id, mine: false, sender: "a", timestamp: ts) }
        let list = [m("a", "2026-10-01T10:00:00Z"), m("c", "2026-10-01T10:02:00Z")]
        XCTAssertEqual(fsInsertRestored(list, m("b", "2026-10-01T10:01:00Z")).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(fsInsertRestored(list, m("z", "2026-10-01T11:00:00Z")).map(\.id), ["a", "c", "z"])
        XCTAssertEqual(fsInsertRestored(list, m("a", "2026-10-01T10:00:00Z")).map(\.id), ["a", "c"], "no duplicate")
        XCTAssertEqual(fsInsertRestored(list, m("bad", "garbage")).map(\.id), ["a", "c", "bad"], "unparseable goes last")
    }

    func test_relativeTime() {
        let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
        XCTAssertEqual(FSMessageActionPolicy.relativeTime("2026-10-01T11:59:50Z", now: now), "just now")
        XCTAssertEqual(FSMessageActionPolicy.relativeTime("2026-10-01T11:55:00Z", now: now), "5m ago")
        XCTAssertEqual(FSMessageActionPolicy.relativeTime("2026-10-01T09:00:00Z", now: now), "3h ago")
        XCTAssertEqual(FSMessageActionPolicy.relativeTime("2026-09-29T12:00:00Z", now: now), "2d ago")
        XCTAssertEqual(FSMessageActionPolicy.relativeTime("nonsense", now: now), "")
    }

    func test_threadSummary_decodesAndRoundTripsCoding() throws {
        let s = try JSONDecoder().decode(FSThreadSummary.self, from: Data(#"{"id":"t","title":"","reply_count":2}"#.utf8))
        XCTAssertEqual(s.title, "Thread", "empty title falls back")
        XCTAssertEqual(s.replyCount, 2)
        XCTAssertThrowsError(try JSONDecoder().decode(FSThreadSummary.self, from: Data(#"{"title":"x"}"#.utf8)), "id is required")
    }
}

// MARK: - View model: single socket mode switching, delete/undo, header

@MainActor
final class MessageThreadsViewModelTests: XCTestCase {

    override func setUp() { ThreadsSeam.reset() }

    private func m(_ id: String, _ ts: String = "2026-10-01T10:00:00Z", mine: Bool = false, text: String? = nil) -> FSMessage {
        FSMessage(id: id, text: text ?? "t-\(id)", mine: mine, sender: mine ? "" : "alice", timestamp: ts)
    }
    private func uid(_ l: String) -> String { "\(l)-\(UUID().uuidString)" }
    private let group = FSContact(id: "group-1", name: "G", type: .group, toUsers: ["me", "x"])
    private func caps(_ threads: Bool = true, del: Bool = true) -> FSCapabilities {
        FSCapabilities(features: ["threads": threads, "message_delete": del, "chat_pagination": true], exploreLink: nil, termsCurrent: true)
    }
    private func service(ws: String = "ws://127.0.0.1:1") -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.wsBaseOverride = ws
        s.historyResult = .paged(FSMessagePage(messages: [m("m1"), m("m2", "2026-10-01T10:01:00Z", mine: true)], hasMore: true,
                                               cursor: FSMessageCursor(timestamp: "ts", seq: 1, id: "m1")))
        return s
    }
    private func loaded(_ s: ThrowingTestDataService, user: String) async -> ChatThreadViewModel {
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: group, userId: user, capabilities: caps())
        return vm
    }
    private func eventually(_ what: String = "", timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("timed out waiting: \(what)")
    }

    // MARK: stash / restore

    func test_openThread_stashesMainChat_loadsThreadRows_andBackRestoresExactly() async {
        let s = service(); let user = uid("stash")
        let vm = await loaded(s, user: user)
        let before = vm.messages.map(\.id)
        XCTAssertTrue(vm.hasMoreOlder)
        ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [m("r1"), m("r2")], hasMore: false, cursor: nil)

        await vm.openThread(FSThreadSummary(id: "t1", title: "Plan"), service: s, contact: group, userId: user)
        XCTAssertTrue(vm.isThreadOpen)
        XCTAssertEqual(vm.activeThread?.title, "Plan")
        XCTAssertEqual(vm.messages.map(\.id), ["r1", "r2"])
        XCTAssertFalse(vm.hasMoreOlder, "thread paging replaces the main chat's paging state")
        XCTAssertTrue(vm.pagingEnabled)

        vm.closeThread()
        XCTAssertFalse(vm.isThreadOpen)
        XCTAssertEqual(vm.messages.map(\.id), before)
        XCTAssertTrue(vm.hasMoreOlder, "main-chat paging state restored")
        vm.disconnect()
    }

    func test_openThread_noopOnDM_andReopenSameThreadDoesNotRefetch() async {
        let s = service(); let user = uid("noop")
        let vm = await loaded(s, user: user)
        await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: FSContact(id: "f", name: "F", type: .friend), userId: user)
        XCTAssertFalse(vm.isThreadOpen, "threads are groups only")
        await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: group, userId: user)
        await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: group, userId: user)
        XCTAssertEqual(ThreadsSeam.log.filter { $0 == "msgs:t1" }.count, 1)
        vm.disconnect()
    }

    func test_threadLoadFailure_flagsRetry_neverFabricates_andRetrySucceeds() async {
        let s = service(); let user = uid("fail")
        let vm = await loaded(s, user: user)
        ThreadsSeam.threadMessagesError = FSThreadsError.failed("down")
        await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: group, userId: user)
        XCTAssertTrue(vm.threadLoadFailed)
        XCTAssertTrue(vm.messages.isEmpty)
        ThreadsSeam.threadMessagesError = nil
        ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [m("r1")], hasMore: false, cursor: nil)
        await vm.loadThreadFirstPage(service: s, contact: group, userId: user)
        XCTAssertFalse(vm.threadLoadFailed)
        XCTAssertEqual(vm.messages.map(\.id), ["r1"])
        vm.closeThread()
        XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2"], "main chat intact after a failed thread load")
        vm.disconnect()
    }

    func test_openThreadById_findsRowAcrossPages_elseOpensWithFallbackTitle() async {
        let s = service(); let user = uid("byid")
        let vm = await loaded(s, user: user)
        ThreadsSeam.threadsPages = [
            FSThreadsPage(threads: [FSThreadSummary(id: "a")], hasMore: true, cursorTimestamp: "ts", cursorId: "a"),
            FSThreadsPage(threads: [FSThreadSummary(id: "T9", title: "Found")], hasMore: false, cursorTimestamp: nil, cursorId: nil)]
        await vm.openThread(id: "t9", service: s, contact: group, userId: user)
        XCTAssertEqual(vm.activeThread?.title, "Found", "id match is case-insensitive and pages are walked")
        vm.closeThread()
        ThreadsSeam.threadsError = FSThreadsError.failed("x")
        await vm.openThread(id: "zzz", service: s, contact: group, userId: user)
        XCTAssertEqual(vm.activeThread?.id, "zzz")
        XCTAssertEqual(vm.activeThread?.title, "Thread")
        vm.disconnect()
    }

    func test_startThread_createsOnMessageThenOpensIt_andThrowsTypedErrors() async throws {
        let s = service(); let user = uid("start")
        let vm = await loaded(s, user: user)
        ThreadsSeam.createResult = FSThreadSummary(id: "tn", title: "Root", rootPreview: "t-m1", rootMessageId: "m1")
        try await vm.startThread(from: m("m1"), service: s, contact: group, userId: user)
        XCTAssertEqual(vm.activeThread?.id, "tn")
        XCTAssertEqual(vm.activeThread?.rootMessageId, "m1")
        vm.closeThread()

        for err in [FSThreadsError.termsReacceptRequired, .threadLimit, .notFound] {
            ThreadsSeam.createError = err
            do { try await vm.startThread(from: m("m1"), service: s, contact: group, userId: user); XCTFail() }
            catch { XCTAssertEqual(error as? FSThreadsError, err) }
            XCTAssertFalse(vm.isThreadOpen, "a failed create must not open a thread")
        }
        vm.disconnect()
    }

    // MARK: live frames over the ONE socket (real local WebSocket)

    private func withServer(_ body: (ChatGroupSelfEchoDedupRegressionTests.WSTestServer, ThrowingTestDataService, ChatThreadViewModel, String) async throws -> Void) async throws {
        let server = try ChatGroupSelfEchoDedupRegressionTests.WSTestServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = service(ws: "ws://127.0.0.1:\(port)"); let user = uid("ws")
        let vm = await loaded(s, user: user)
        try await server.waitForConnection()
        try await body(server, s, vm, user)
        vm.disconnect()
    }

    func test_mainChatFrame_whileThreadOpen_goesToStash_andAppearsOnBack() async throws {
        try await withServer { server, s, vm, user in
            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [self.m("r1")], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: self.group, userId: user)
            try server.sendFrame(["from_user": "someone", "text": "main while away", "id": "main-x", "timestamp": "2026-10-01T10:05:00Z"])
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertEqual(vm.messages.map(\.id), ["r1"], "main frame must not leak into the open thread")
            // duplicate delivery is deduped in the stash too
            try server.sendFrame(["from_user": "someone", "text": "main while away", "id": "main-x", "timestamp": "2026-10-01T10:05:00Z"])
            try await Task.sleep(nanoseconds: 400_000_000)
            vm.closeThread()
            XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2", "main-x"])
        }
    }

    func test_threadFrame_appendsOnlyToTheOpenThread_dedups_andBumpsReplyCount() async throws {
        try await withServer { server, s, vm, user in
            // not open yet: ignored, never lands in the main chat
            try server.sendFrame(["type": "thread_message", "thread_id": "t1", "id": "x0", "sender": "bob", "body": "early", "created_at": "2026-10-01T10:06:00Z"])
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2"])

            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [self.m("r1")], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1", replyCount: 1), service: s, contact: self.group, userId: user)
            let frame: [String: Any] = ["type": "thread_message", "thread_id": "t1", "id": "x1", "sender": "bob", "body": "live", "created_at": "2026-10-01T10:07:00Z"]
            try server.sendFrame(frame)
            await self.eventually("thread frame") { vm.messages.map(\.id) == ["r1", "x1"] }
            try server.sendFrame(frame)
            try server.sendFrame(["type": "thread_message", "thread_id": "OTHER", "id": "x2", "sender": "bob", "body": "elsewhere", "created_at": "2026-10-01T10:08:00Z"])
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertEqual(vm.messages.map(\.id), ["r1", "x1"], "dedup by id; other threads ignored")
            XCTAssertEqual(vm.activeThread?.replyCount, 2)
            vm.closeThread()
            XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2"], "thread frames never reach the main chat")
        }
    }

    func test_rootDeletedHeader_togglesOnMessageDeletedAndRestoredFrames() async throws {
        try await withServer { server, s, vm, user in
            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1", rootPreview: "t-m2", rootMessageId: "m2"), service: s, contact: self.group, userId: user)
            XCTAssertEqual(vm.activeThread?.rootDeleted, false)
            // wrong group: ignored
            try server.sendFrame(["type": "message_deleted", "id": "m2", "group_id": "other-group"])
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(vm.activeThread?.rootDeleted, false)

            try server.sendFrame(["type": "message_deleted", "id": "m2", "group_id": "GROUP-1"])
            await self.eventually("root deleted") { vm.activeThread?.rootDeleted == true }

            try server.sendFrame(["type": "message_restored", "id": "m2", "group_id": "group-1", "sender": "me",
                                  "body": "t-m2", "created_at": "2026-10-01T10:01:00Z"])
            await self.eventually("root restored") { vm.activeThread?.rootDeleted == false }
            XCTAssertEqual(vm.activeThread?.rootPreview, "t-m2")
        }
    }

    func test_messageDeletedFrame_removesFromMainList_andFromStashWhileThreadOpen() async throws {
        try await withServer { server, s, vm, user in
            try server.sendFrame(["type": "message_deleted", "id": "m1", "group_id": "group-1"])
            await self.eventually("main removal") { vm.messages.map(\.id) == ["m2"] }
            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [self.m("r1")], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: self.group, userId: user)
            try server.sendFrame(["type": "message_deleted", "id": "m2", "group_id": "group-1"])
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertEqual(vm.messages.map(\.id), ["r1"])
            vm.closeThread()
            XCTAssertTrue(vm.messages.isEmpty, "deleted while the thread was open: gone from the restored main list")
            try server.sendFrame(["type": "message_restored", "id": "m2", "group_id": "group-1", "sender": "me", "body": "t-m2", "created_at": "2026-10-01T10:01:00Z"])
            await self.eventually("restore re-inserts") { vm.messages.map(\.id) == ["m2"] }
        }
    }

    func test_threadSend_ack_reconcilesOnlyOpenThread_inPlace() async throws {
        try await withServer { server, s, vm, user in
            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [self.m("r1")], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: self.group, userId: user)
            vm.sendMessage(text: "reply", attachment: nil, contact: self.group, userId: user)
            let local = vm.messages.last!.id
            XCTAssertEqual(vm.messages.count, 2)
            // ack for a different thread must not touch it
            try server.sendFrame(["type": "ack", "client_ref": local, "id": "wrong", "thread_id": "OTHER"])
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(vm.messages.last?.id, local)
            try server.sendFrame(["type": "ack", "client_ref": local, "id": "srv-r2", "thread_id": "t1", "timestamp": "2026-10-01T12:00:00+00:00"])
            await self.eventually("thread ack") { vm.messages.last?.id == "srv-r2" }
            XCTAssertEqual(vm.messages.count, 2)
            XCTAssertEqual(vm.messages.last?.text, "reply")
            XCTAssertTrue(vm.isSettled(vm.messages.last!))
        }
    }

    func test_mainChatAck_whileThreadOpen_reconcilesTheStash() async throws {
        try await withServer { server, s, vm, user in
            vm.sendMessage(text: "from main", attachment: nil, contact: self.group, userId: user)
            let local = vm.messages.last!.id
            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: self.group, userId: user)
            try server.sendFrame(["type": "ack", "client_ref": local, "id": "srv-main", "timestamp": "2026-10-01T12:00:00+00:00"])
            try await Task.sleep(nanoseconds: 700_000_000)
            vm.closeThread()
            XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2", "srv-main"])
            XCTAssertTrue(vm.isSettled(vm.messages.last!), "pending set cleaned in the stash")
        }
    }

    func test_termsReaccept_errorFrame_pullsBubbleBack_returnsDraft_andRaisesGateSignal() async throws {
        try await withServer { server, s, vm, user in
            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [self.m("r1")], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: self.group, userId: user)
            vm.sendMessage(text: "my reply", attachment: nil, contact: self.group, userId: user)
            XCTAssertEqual(vm.messages.count, 2)
            XCTAssertEqual(vm.termsGateSignal, 0)
            try server.sendFrame(["type": "error", "reason": "terms_reaccept_required"])
            await self.eventually("terms gate") { vm.termsGateSignal == 1 }
            XCTAssertEqual(vm.restoredDraft, "my reply")
            XCTAssertEqual(vm.messages.map(\.id), ["r1"], "optimistic bubble removed")
            XCTAssertTrue(vm.failedMessageIds.isEmpty)
        }
    }

    func test_otherErrorFrame_marksBubbleFailed_notDraftRestored() async throws {
        try await withServer { server, s, vm, user in
            ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [], hasMore: false, cursor: nil)
            await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: self.group, userId: user)
            vm.sendMessage(text: "x", attachment: nil, contact: self.group, userId: user)
            let local = vm.messages.last!.id
            try server.sendFrame(["type": "error", "reason": "rate_limited"])
            await self.eventually("failed") { vm.failedMessageIds.contains(local) }
            XCTAssertNil(vm.restoredDraft)
            XCTAssertEqual(vm.termsGateSignal, 0)
        }
    }

    // MARK: optimistic delete, rollback, undo window

    func test_delete_isOptimistic_returnsServerWindow_andUndoReinsertsAtTimePosition() async throws {
        let s = service(); let user = uid("del")
        let vm = await loaded(s, user: user)
        ThreadsSeam.deleteResult = FSMessageDeleteResult(id: "", undoSeconds: 7)
        let target = vm.messages.first { $0.id == "m1" }!
        let r = try await vm.deleteOwnMessage(target, service: s, contact: group, userId: user)
        XCTAssertEqual(r.undoSeconds, 7, "server undo_seconds is honoured")
        XCTAssertEqual(vm.messages.map(\.id), ["m2"])
        try await vm.undoDelete(target, service: s, contact: group, userId: user)
        XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2"], "restored in place by time")
        XCTAssertEqual(ThreadsSeam.log.filter { $0.hasPrefix("delete:") || $0.hasPrefix("restore:") }, ["delete:m1", "restore:m1"])
        vm.disconnect()
    }

    func test_delete_failure_rollsBackAndRethrows() async {
        let s = service(); let user = uid("rb")
        let vm = await loaded(s, user: user)
        ThreadsSeam.deleteError = FSThreadsError.failed("nope")
        let target = vm.messages.first { $0.id == "m2" }!
        do { _ = try await vm.deleteOwnMessage(target, service: s, contact: group, userId: user); XCTFail() }
        catch { XCTAssertEqual(error as? FSThreadsError, .failed("nope")) }
        XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2"], "rolled back at its position")
        vm.disconnect()
    }

    func test_undo_failureAfterWindow_leavesMessageDeleted_andThrows() async throws {
        let s = service(); let user = uid("late")
        let vm = await loaded(s, user: user)
        let target = vm.messages.first { $0.id == "m1" }!
        _ = try await vm.deleteOwnMessage(target, service: s, contact: group, userId: user)
        ThreadsSeam.restoreError = FSThreadsError.failed("Undo window over")
        do { try await vm.undoDelete(target, service: s, contact: group, userId: user); XCTFail() } catch {}
        XCTAssertEqual(vm.messages.map(\.id), ["m2"])
        vm.disconnect()
    }

    func test_deleteWhileThreadOpen_removesFromStash_rollbackAlsoTargetsStash() async throws {
        let s = service(); let user = uid("stashdel")
        let vm = await loaded(s, user: user)
        ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [m("r1")], hasMore: false, cursor: nil)
        await vm.openThread(FSThreadSummary(id: "t1", rootPreview: "t-m1", rootMessageId: "m1"), service: s, contact: group, userId: user)
        let target = m("m1")
        ThreadsSeam.deleteError = FSThreadsError.failed("x")
        _ = try? await vm.deleteOwnMessage(target, service: s, contact: group, userId: user)
        XCTAssertEqual(vm.messages.map(\.id), ["r1"], "thread list untouched by a main-chat delete")
        vm.closeThread()
        XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2"])
        vm.disconnect()
    }

    func test_undoDelete_ofRoot_clearsRootDeletedHeader() async throws {
        let s = service(); let user = uid("rootundo")
        let vm = await loaded(s, user: user)
        ThreadsSeam.threadPages["t1"] = FSMessagePage(messages: [], hasMore: false, cursor: nil)
        var summary = FSThreadSummary(id: "t1", rootPreview: "", rootMessageId: "m1")
        summary.rootDeleted = true
        await vm.openThread(summary, service: s, contact: group, userId: user)
        XCTAssertEqual(vm.activeThread?.rootDeleted, true)
        try await vm.undoDelete(m("m1", text: "root text"), service: s, contact: group, userId: user)
        XCTAssertEqual(vm.activeThread?.rootDeleted, false)
        XCTAssertEqual(vm.activeThread?.rootPreview, "root text")
        vm.disconnect()
    }

    func test_originalMessageDeleted_headerTextIsWiredToRootDeleted() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("FellowScript/Chat/ChatThreadView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(#"t.rootDeleted ? "Original message deleted" : t.rootPreview"#))
    }
}

// MARK: - Registry, threads list VM, push routing

@MainActor
final class MessageThreadsRegistryAndRoutingTests: XCTestCase {

    override func setUp() { ThreadsSeam.reset() }

    private let ctx = GroupInfoSectionContext(service: MockDataService.shared, groupId: "g", userId: "u", isOwner: false)

    func test_registry_isOrderedPublish10_then_threads30() {
        XCTAssertEqual(GroupInfoExtraSections.registry.count, 2)
        let sorted = GroupInfoExtraSections.registry.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.order), [10, 30])
        XCTAssertEqual(sorted.last?.id, "threads")
        XCTAssertEqual(GroupThreadsSection.registration.order, 30)
    }

    func test_threadsSection_visibleOnlyWhenFlagTrue_failsClosedOtherwise() {
        let on = FSCapabilities(features: ["threads": true], exploreLink: nil, termsCurrent: true)
        let off = FSCapabilities(features: ["threads": false], exploreLink: nil, termsCurrent: true)
        func ids(_ c: FSCapabilities) -> [String] {
            GroupInfoExtraSections.visible(capabilities: c, context: ctx).map(\.id)
        }
        XCTAssertTrue(ids(on).contains("threads"))
        XCTAssertFalse(ids(off).contains("threads"))
        XCTAssertFalse(ids(.allOff).contains("threads"), "missing flag")
    }

    func test_threadsListVM_loadsPages_dedupsMore_andKeepsRowsOnFailedRefresh() async {
        let s = ThrowingTestDataService()
        let g = "g-\(UUID().uuidString)"
        ThreadsSeam.threadsPages = [
            FSThreadsPage(threads: [FSThreadSummary(id: "a"), FSThreadSummary(id: "b")], hasMore: true, cursorTimestamp: "ts", cursorId: "b"),
            FSThreadsPage(threads: [FSThreadSummary(id: "b"), FSThreadSummary(id: "c")], hasMore: false, cursorTimestamp: nil, cursorId: nil)]
        let vm = GroupThreadsViewModel(service: s, groupId: g, userId: "u")
        await vm.load()
        XCTAssertEqual(vm.threads.map(\.id), ["a", "b"])
        XCTAssertTrue(vm.hasMore)
        await vm.loadMore()
        XCTAssertEqual(vm.threads.map(\.id), ["a", "b", "c"], "keyset page deduped by id")
        XCTAssertFalse(vm.hasMore)
        ThreadsSeam.threadsError = FSThreadsError.failed("down")
        await vm.load()
        XCTAssertTrue(vm.loadFailed)
        XCTAssertEqual(vm.threads.map(\.id), ["a", "b", "c"], "preserve-cache-on-failed-refresh")
    }

    func test_threadsListVM_moreFailure_isFlagged_notFatal() async {
        let s = ThrowingTestDataService()
        ThreadsSeam.threadsPages = [FSThreadsPage(threads: [FSThreadSummary(id: "a")], hasMore: true, cursorTimestamp: "ts", cursorId: "a")]
        let vm = GroupThreadsViewModel(service: s, groupId: "g-\(UUID().uuidString)", userId: "u")
        await vm.load()
        ThreadsSeam.threadsError = FSThreadsError.failed("down")
        await vm.loadMore()
        XCTAssertTrue(vm.moreFailed)
        XCTAssertEqual(vm.threads.map(\.id), ["a"])
    }

    // push routing

    func test_appState_openThread_setsPendingThread_andOpensGroupChat() {
        let s = AppState(service: MockDataService.shared)
        s.currentUser = FSUser(user_id: "me", username: "me", email: "m@x.com")
        s.isAuthenticated = true
        s.openThread(groupId: "g1", threadId: "t1")
        XCTAssertEqual(s.pendingThreadOpen, PendingThreadOpen(groupId: "g1", threadId: "t1"))
        XCTAssertEqual(s.pendingChatContact?.id, "g1")
        XCTAssertEqual(s.pendingChatContact?.type, .group)
    }

    func test_appState_openThread_withoutThreadId_justOpensChat_andEmptyGroupIsIgnored() {
        let s = AppState(service: MockDataService.shared)
        s.currentUser = FSUser(user_id: "me", username: "me", email: "m@x.com")
        s.isAuthenticated = true
        s.openThread(groupId: "g1", threadId: "")
        XCTAssertNil(s.pendingThreadOpen)
        XCTAssertEqual(s.pendingChatContact?.id, "g1")
        let s2 = AppState(service: MockDataService.shared)
        s2.currentUser = s.currentUser; s2.isAuthenticated = true
        s2.openThread(groupId: "", threadId: "t")
        XCTAssertNil(s2.pendingThreadOpen)
        XCTAssertNil(s2.pendingChatContact)
    }

    func test_pushDelegate_routesThreadMessageAction_toThreadPushTapped() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("FellowScript/FellowScriptApp.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(#"action == "thread_message""#))
        XCTAssertTrue(src.contains("name: .threadPushTapped"))
        XCTAssertTrue(src.contains(#"data["thread_id"] as? String"#))
        XCTAssertTrue(src.contains("appState.openThread(groupId: target.groupId, threadId: target.threadId)"))
    }
}
