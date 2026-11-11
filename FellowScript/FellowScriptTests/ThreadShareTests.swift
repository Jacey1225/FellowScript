// ThreadShareTests.swift — task 20261030-thread-share-notes-verses, testing step 7.
// Covers the thread-share pieces that are pure or driven by the test doubles:
//   - ShareThreadsViewModel.recent: newest activity first, capped at 10
//   - ShareThreadsViewModel.load: success, failure keeps prior rows (never fabricates)
//   - PendingChatShare equality with and without a thread
//   - ChatShareDelivery.canDeliver (main chat vs open thread vs thread share)
//   - ChatShareDelivery.deliver sends nothing when threads/chat_shared_objects are off
import XCTest
@testable import FellowScript

@MainActor
final class ThreadShareTests: XCTestCase {

    override func setUp() { ThreadsSeam.reset() }

    private func row(_ id: String, _ ts: String) -> FSThreadSummary { FSThreadSummary(id: id, lastActivityAt: ts) }
    private let group = FSContact(id: "group-1", name: "G", type: .group, toUsers: ["me", "x"])
    private let verse = SharedPayload.verse(book: "John", chapter: 3, verse: 16, text: "For God so loved")

    // MARK: recent

    func test_recent_sortsNewestFirst() {
        let out = ShareThreadsViewModel.recent([row("a", "2026-10-01T10:00:00Z"), row("c", "2026-10-03T10:00:00Z"),
                                                row("b", "2026-10-02T10:00:00Z")])
        XCTAssertEqual(out.map(\.id), ["c", "b", "a"])
    }

    func test_recent_capsAtTen_keepingTheNewest() {
        let rows = (1...14).map { row("t\($0)", String(format: "2026-10-%02dT10:00:00Z", $0)) }
        let out = ShareThreadsViewModel.recent(rows)
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(ShareThreadsViewModel.cap, 10)
        XCTAssertEqual(out.first?.id, "t14")
        XCTAssertEqual(out.last?.id, "t5")
        XCTAssertFalse(out.contains { $0.id == "t4" })
    }

    func test_recent_emptyAndUnderCap() {
        XCTAssertTrue(ShareThreadsViewModel.recent([]).isEmpty)
        XCTAssertEqual(ShareThreadsViewModel.recent([row("a", "2026-10-01T00:00:00Z")]).count, 1)
    }

    // MARK: load

    func test_load_success_publishesRecentRows() async {
        let s = ThrowingTestDataService()
        ThreadsSeam.threadsPages = [FSThreadsPage(threads: (1...12).map { row("t\($0)", String(format: "2026-10-%02dT10:00:00Z", $0)) },
                                                  hasMore: true, cursorTimestamp: nil, cursorId: nil)]
        let vm = ShareThreadsViewModel(service: s, groupId: "group-1", userId: "me")
        await vm.load()
        XCTAssertTrue(vm.loaded)
        XCTAssertFalse(vm.failed)
        XCTAssertEqual(vm.threads.count, 10)
        XCTAssertEqual(vm.threads.first?.id, "t12")
    }

    func test_load_failure_flagsFailed_neverFabricates_andRetryRecovers() async {
        let s = ThrowingTestDataService()
        ThreadsSeam.threadsError = FSThreadsError.failed("down")
        let vm = ShareThreadsViewModel(service: s, groupId: "group-1", userId: "me")
        await vm.load()
        XCTAssertTrue(vm.failed)
        XCTAssertFalse(vm.loaded)
        XCTAssertTrue(vm.threads.isEmpty)
        ThreadsSeam.threadsError = nil
        ThreadsSeam.threadsPages = [FSThreadsPage(threads: [row("a", "2026-10-01T00:00:00Z")], hasMore: false, cursorTimestamp: nil, cursorId: nil)]
        await vm.load()
        XCTAssertFalse(vm.failed)
        XCTAssertEqual(vm.threads.map(\.id), ["a"])
    }

    func test_load_failureAfterSuccess_keepsRowsShown() async {
        let s = ThrowingTestDataService()
        ThreadsSeam.threadsPages = [FSThreadsPage(threads: [row("a", "2026-10-01T00:00:00Z")], hasMore: false, cursorTimestamp: nil, cursorId: nil)]
        let vm = ShareThreadsViewModel(service: s, groupId: "group-1", userId: "me")
        await vm.load()
        ThreadsSeam.threadsError = FSThreadsError.failed("down")
        await vm.load()
        XCTAssertTrue(vm.failed)
        XCTAssertEqual(vm.threads.map(\.id), ["a"])
    }

    // MARK: PendingChatShare equality

    func test_pendingShare_equality_includesThread() {
        let a = PendingChatShare(contact: group, payload: verse)
        XCTAssertEqual(a, PendingChatShare(contact: group, payload: verse))
        XCTAssertNil(a.thread)
        let t1 = PendingChatShare(contact: group, payload: verse, thread: FSThreadSummary(id: "t1"))
        XCTAssertEqual(t1, PendingChatShare(contact: group, payload: verse, thread: FSThreadSummary(id: "t1")))
        XCTAssertNotEqual(t1, a)
        XCTAssertNotEqual(t1, PendingChatShare(contact: group, payload: verse, thread: FSThreadSummary(id: "t2")))
    }

    // MARK: delivery check

    func test_canDeliver_mainChatShare_onlyWhenNoThreadOpen() async {
        let vm = ChatThreadViewModel()
        let main = PendingChatShare(contact: group, payload: verse)
        XCTAssertTrue(ChatShareDelivery.canDeliver(main, vm: vm))
        let s = ThrowingTestDataService(); s.wsBaseOverride = "ws://127.0.0.1:1"
        await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: group, userId: "me-\(UUID().uuidString)")
        XCTAssertTrue(vm.isThreadOpen)
        XCTAssertFalse(ChatShareDelivery.canDeliver(main, vm: vm), "a main-chat share waits while a thread is open")
        vm.disconnect()
    }

    func test_canDeliver_threadShare_alwaysDeliverable() async {
        let vm = ChatThreadViewModel()
        let share = PendingChatShare(contact: group, payload: verse, thread: FSThreadSummary(id: "t1"))
        XCTAssertTrue(ChatShareDelivery.canDeliver(share, vm: vm))
        let s = ThrowingTestDataService(); s.wsBaseOverride = "ws://127.0.0.1:1"
        await vm.openThread(FSThreadSummary(id: "t1"), service: s, contact: group, userId: "me-\(UUID().uuidString)")
        XCTAssertTrue(ChatShareDelivery.canDeliver(share, vm: vm))
        vm.disconnect()
    }

    func test_deliver_threadShare_withFlagsOff_opensNothingAndSendsNothing() async {
        let app = AppState(service: MockDataService.shared)
        app.currentUser = FSUser(user_id: "me", username: "me", email: "me@example.com")
        let vm = ChatThreadViewModel()
        let share = PendingChatShare(contact: group, payload: verse, thread: FSThreadSummary(id: "t1"))
        ChatShareDelivery.deliver(share, vm: vm, appState: app, contact: group)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(vm.isThreadOpen, "flags are off by default, so the thread is never opened")
        XCTAssertTrue(vm.messages.isEmpty)
    }
}
