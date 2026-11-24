// ChatForegroundRefreshRegressionTests.swift -- task 20261124-chat-lags-new-messages,
// testing step 2.
//
// Bug: the chat socket is closed on background by design, frames sent while it
// was closed are never replayed, and a push tap for the thread already on
// screen was a no-op, so a new message (e.g. a GIF) stayed invisible until the
// app was fully relaunched. Fix: ChatThreadViewModel.refreshOpenConversation
// refetches the newest page and merges it by id (mergeRefreshed).
//
// Covers: pure merge (new row appended, dedup, older pages kept, optimistic
// rows kept, gap replaces window, legacy full replace); view-model refresh for
// main chat and open thread; failed refresh keeps the list; throttle vs force;
// same-id openThread refetches; GIF row from history; source pins for the
// foreground / reconnect / push-tap wiring.
//
// NOT runnable on the Linux dev host (no xcodebuild/swift); needs a Mac, one
// simulator run at a time.

import XCTest
@testable import FellowScript

@MainActor
final class ChatForegroundRefreshRegressionTests: XCTestCase {

    private func m(_ id: String, _ ts: String = "2026-11-24T10:00:00Z", kind: String? = nil, url: String? = nil) -> FSMessage {
        FSMessage(id: id, text: "t-\(id)", mine: false, sender: "someone", timestamp: ts,
                  attachmentKind: kind, attachmentURL: url)
    }
    private func uid(_ l: String) -> String { "\(l)-\(UUID().uuidString)" }
    private func caps() -> FSCapabilities {
        FSCapabilities(features: ["chat_pagination": true, "chat_pagination_dm": true], exploreLink: nil, termsCurrent: true)
    }
    private func page(_ msgs: [FSMessage], more: Bool = false) -> FSMessagePage {
        FSMessagePage(messages: msgs, hasMore: more,
                      cursor: more ? FSMessageCursor(timestamp: "ts", seq: 1, id: msgs.first!.id) : nil)
    }
    private func service() -> ThrowingTestDataService {
        let s = ThrowingTestDataService()
        s.wsBaseOverride = "ws://127.0.0.1:1"
        return s
    }
    private let group = FSContact(id: "group-1", name: "G", type: .group, toUsers: ["me", "x"])

    override func setUp() { super.setUp(); ThreadsSeam.reset() }
    override func tearDown() { ThreadsSeam.reset(); super.tearDown() }

    private func loadedGroupVM(_ s: ThrowingTestDataService, user: String, initial: [FSMessage]) async -> ChatThreadViewModel {
        s.historyResult = .paged(page(initial))
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: group, userId: user, capabilities: caps())
        return vm
    }

    // MARK: pure merge

    func test_merge_appendsNewMessage_noDuplicates_keepsOrder() {
        let r = ChatThreadViewModel.mergeRefreshed(existing: [m("1"), m("2")], fetched: [m("2"), m("3")],
                                                   localIds: [], paged: true)
        XCTAssertEqual(r.messages.map(\.id), ["1", "2", "3"])
        XCTAssertFalse(r.windowReplaced)
    }

    func test_merge_keepsOlderPagesAlreadyLoaded() {
        let existing = [m("a"), m("b"), m("c"), m("d")]
        let r = ChatThreadViewModel.mergeRefreshed(existing: existing, fetched: [m("c"), m("d"), m("e")],
                                                   localIds: [], paged: true)
        XCTAssertEqual(r.messages.map(\.id), ["a", "b", "c", "d", "e"])
    }

    func test_merge_keepsOptimisticRows_atTheEnd_andNeverDuplicatesThem() {
        let r = ChatThreadViewModel.mergeRefreshed(existing: [m("1"), m("local")], fetched: [m("1"), m("2"), m("local")],
                                                   localIds: ["local"], paged: true)
        XCTAssertEqual(r.messages.map(\.id), ["1", "2", "local"])
    }

    func test_merge_gapWithNoOverlap_replacesWindowWithNewestPage_keepsLocal() {
        let r = ChatThreadViewModel.mergeRefreshed(existing: [m("1"), m("2"), m("local")], fetched: [m("90"), m("91")],
                                                   localIds: ["local"], paged: true)
        XCTAssertEqual(r.messages.map(\.id), ["90", "91", "local"])
        XCTAssertTrue(r.windowReplaced)
    }

    func test_merge_emptyFetch_neverDropsShownRows() {
        let r = ChatThreadViewModel.mergeRefreshed(existing: [m("1"), m("2")], fetched: [], localIds: [], paged: true)
        XCTAssertEqual(r.messages.map(\.id), ["1", "2"])
        // Empty page with no overlap must not be reported as a replaced window.
        XCTAssertFalse(r.windowReplaced)
    }

    func test_merge_legacyFullReplace_keepsLocalRows() {
        let r = ChatThreadViewModel.mergeRefreshed(existing: [m("1"), m("local")], fetched: [m("1"), m("2")],
                                                   localIds: ["local"], paged: false)
        XCTAssertEqual(r.messages.map(\.id), ["1", "2", "local"])
    }

    // MARK: main chat refresh

    func test_foregroundRefresh_mainChat_showsMissedMessage() async {
        let s = service()
        let user = uid("fg")
        let vm = await loadedGroupVM(s, user: user, initial: [m("1"), m("2")])
        s.historyResult = .paged(page([m("1"), m("2"), m("3")]))
        await vm.refreshOpenConversation(service: s, contact: group, userId: user, force: true)
        XCTAssertEqual(vm.messages.map(\.id), ["1", "2", "3"])
        vm.disconnect()
    }

    func test_failedRefresh_mainChat_preservesList() async {
        let s = service()
        let user = uid("fail")
        let dm = FSContact(id: "friend-1", name: "Friend", type: .friend)
        s.historyResult = .paged(page([m("1"), m("2")]))
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: dm, userId: user, capabilities: caps())
        XCTAssertEqual(vm.messages.map(\.id), ["1", "2"])
        // nil historyResult falls through to the legacy fetch, which now throws.
        s.historyResult = nil
        s.fetchFriendMessagesError = AppError.networkError("down")
        await vm.refreshOpenConversation(service: s, contact: dm, userId: user, force: true)
        XCTAssertEqual(vm.messages.map(\.id), ["1", "2"], "failed refresh must not clear or fabricate")
        vm.disconnect()
    }

    func test_refresh_isThrottled_unlessForced() async {
        let s = service()
        let user = uid("thr")
        let vm = await loadedGroupVM(s, user: user, initial: [m("1")])
        s.historyResult = .paged(page([m("1"), m("2")]))
        await vm.refreshOpenConversation(service: s, contact: group, userId: user, force: true)
        let callsAfterFirst = s.historyLimits.count
        s.historyResult = .paged(page([m("1"), m("2"), m("3")]))
        await vm.refreshOpenConversation(service: s, contact: group, userId: user, force: false)
        XCTAssertEqual(s.historyLimits.count, callsAfterFirst, "second unforced refresh inside the window is skipped")
        XCTAssertEqual(vm.messages.map(\.id), ["1", "2"])
        await vm.refreshOpenConversation(service: s, contact: group, userId: user, force: true)
        XCTAssertEqual(vm.messages.map(\.id), ["1", "2", "3"], "push tap forces past the throttle")
        vm.disconnect()
    }

    // MARK: thread refresh / same-id openThread

    func test_openThread_sameId_refetchesAndShowsNewGifMessage() async {
        let s = service()
        let user = uid("thr-same")
        let vm = await loadedGroupVM(s, user: user, initial: [m("main")])
        let summary = FSThreadSummary(id: "t1")
        ThreadsSeam.threadPages["t1"] = page([m("r"), m("a")])
        await vm.openThread(summary, service: s, contact: group, userId: user)
        XCTAssertEqual(vm.messages.map(\.id), ["r", "a"])

        ThreadsSeam.threadPages["t1"] = page([m("r"), m("a"), m("gif", kind: "gif", url: "https://x/g.gif")])
        ThreadsSeam.log = []
        await vm.openThread(summary, service: s, contact: group, userId: user)   // push tap, same thread
        XCTAssertEqual(ThreadsSeam.log, ["msgs:t1"], "same-id open must refetch, not no-op")
        XCTAssertEqual(vm.messages.map(\.id), ["r", "a", "gif"])
        XCTAssertEqual(vm.messages.last?.attachmentKind, "gif", "GIF row renders from history")
        XCTAssertEqual(vm.messages.last?.attachmentURL, "https://x/g.gif")
        vm.disconnect()
    }

    func test_threadRefresh_failure_keepsThreadMessages() async {
        let s = service()
        let user = uid("thr-fail")
        let vm = await loadedGroupVM(s, user: user, initial: [m("main")])
        let summary = FSThreadSummary(id: "t1")
        ThreadsSeam.threadPages["t1"] = page([m("r"), m("a")])
        await vm.openThread(summary, service: s, contact: group, userId: user)
        ThreadsSeam.threadMessagesError = AppError.networkError("down")
        await vm.openThread(summary, service: s, contact: group, userId: user)
        XCTAssertEqual(vm.messages.map(\.id), ["r", "a"])
        vm.disconnect()
    }

    // MARK: source pins (same technique as ChatPushDeepLinkTapTests)

    private func readSource(_ relativePath: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_sourcePins_foregroundReconnectAndPushTapPathsRefresh() throws {
        let view = try readSource("FellowScript/Chat/ChatThreadView.swift")
        XCTAssertTrue(view.contains("} else if phase == .active {"))
        XCTAssertTrue(view.contains("Task { await vm.refreshFromStoredContext() }"), "foreground must refresh")
        XCTAssertTrue(view.contains("self.wasDropped = false"), "reconnect-after-drop must refresh")
        XCTAssertTrue(view.contains("refreshFromStoredContext(force: true)"), "push tap must force refresh")
        XCTAssertTrue(view.contains("func handleAppBackgrounded() { socket.handleAppBackgrounded() }"),
                      "background disconnect must stay (APNs fall-through)")
        let app = try readSource("FellowScript/Services/AppState.swift")
        XCTAssertTrue(app.contains("conversationRefreshSignal += 1"))
    }
}
