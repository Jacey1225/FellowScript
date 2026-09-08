// ChatScrollToBottomOnOpenRegressionTests.swift — regression coverage for
// task 20260908-chat-scroll-to-bottom-on-open, testing gate.
//
// Root cause: ChatThreadView.swift and AgentChatView.swift only ever
// scrolled their message list to the bottom reactively, from
// `.onChange(of: vm.messages.count)`. That handler's own (pre-fix) comment
// acknowledged it "wouldn't fire ... if the disk-cache read and the fresh
// fetch happen to land on the exact same count (e.g. re-opening a thread
// with no new messages since last time)" -- the `.task` block that runs
// first only called recomputeMessageGroups()/vm.load() to populate the list,
// never proxy.scrollTo(...). In that common "reopen with nothing new" case,
// the list rendered wherever SwiftUI's ScrollView happened to leave it,
// which is not necessarily the bottom.
//
// The fix adds an explicit, unconditional initial scroll inside `.task`,
// once loading/grouping finishes, driven by a `scrollProxy` @State captured
// via `ScrollViewReader`'s `.onAppear` (which fires before `.task`'s
// network-bound load resolves, since `.task` sits outside the
// ScrollViewReader closure and has no other way to reach `proxy`). Snapped
// (no `withMotionAwareAnimation`), unlike the existing reactive
// `.onChange(of: vm.messages.count)` scroll, which stays animated and
// untouched -- a live "new message arrived while you're already looking at
// it" moment is a different case from establishing the thread's starting
// position before the screen has settled.
//
// `scrollProxy`/the `.task` scroll call live on the View struct itself (not
// a testable ViewModel) -- proving SwiftUI actually calls
// `ScrollViewProxy.scrollTo` at runtime requires a real render pass (UI
// test / simulator run), which this pass explicitly skips per the user's
// time constraint (see testing.json). This suite instead:
//
//   1. Proves the exact bug scenario is real at the ViewModel layer:
//      ChatThreadViewModel.load() reopening a thread whose disk cache and
//      fresh network fetch land on the same message count (the case
//      `.onChange(of: vm.messages.count)` cannot detect) still leaves
//      `messages` correctly populated with a valid last message -- i.e.
//      there IS a real target for the `.task` block's unconditional
//      scrollTo to reach, not an empty list masking the bug.
//   2. Source-guards the actual fix: the `.task` block in both
//      ChatThreadView.swift and AgentChatView.swift must call
//      `scrollProxy?.scrollTo(...)` unconditionally after
//      load/recompute finishes, ordered after the load call, guarded
//      against an empty list, and NOT wrapped in the animated
//      `withMotionAwareAnimation` the reactive `.onChange` path uses --
//      while the reactive `.onChange(of: vm.messages.count)` handler
//      itself remains present and animated, unregressed.
import XCTest
@testable import FellowScript

@MainActor
final class ChatScrollToBottomOnOpenRegressionTests: XCTestCase {

    private func msg(_ id: String, sender: String, timestamp: String) -> FSMessage {
        FSMessage(id: id, text: "text-\(id)", mine: false, sender: sender, timestamp: timestamp)
    }

    /// Fresh per-test user id -- DiskCache.shared is the real on-disk cache
    /// (persists across test runs in the same simulator container), so a
    /// stable/shared id would risk cross-test pollution. Same rationale as
    /// ChatThreadCacheIsolationRegressionTests.freshUserId().
    private func freshUserId(_ label: String) -> String { "\(label)-\(UUID().uuidString)" }

    // MARK: - 1. The bug scenario is real: cache count == fresh fetch count

    func test_load_reopenWithUnchangedMessageCount_stillPopulatesMessages_withValidLastMessage() async {
        // Mirrors the exact scenario the pre-fix `.onChange` comment called
        // out: the disk-cache read and the fresh network fetch land on the
        // *same* count -- meaning `.onChange(of: vm.messages.count)` would
        // never fire, and the `.task` block's unconditional scrollTo is the
        // only thing standing between the user and a stale scroll position.
        let contact = FSContact(id: "reopen-contact", name: "Reopen Friend", type: .friend)
        let userId = freshUserId("reopenUser")
        let sessionKey = ChatThreadViewModel.roomKey(contact: contact, userId: userId)

        let cachedMessages = [
            msg("1", sender: contact.id, timestamp: "2026-09-07T10:00:00Z"),
            msg("2", sender: contact.id, timestamp: "2026-09-07T10:05:00Z"),
            msg("3", sender: contact.id, timestamp: "2026-09-07T10:10:00Z"),
        ]
        await DiskCache.shared.save(cachedMessages, forKey: "messages:\(sessionKey)")

        let service = ThrowingTestDataService()
        // Fresh fetch returns the identical set (same ids, same count) --
        // the exact "nothing new since last time" case.
        service.fetchFriendMessagesResult = cachedMessages
        service.wsBaseOverride = "ws://127.0.0.1:1"

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: userId)

        XCTAssertEqual(vm.messages.count, cachedMessages.count,
                       "sanity check: cache and fresh fetch must land on the same count -- the case `.onChange(of: vm.messages.count)` cannot detect")
        XCTAssertEqual(vm.messages.last?.id, "3",
                       "the .task block's unconditional scrollTo must have a real, correct last message to target even when the count never changes")
        vm.disconnect()
    }

    func test_load_reopenWithUnchangedMessageCount_groupThread_stillPopulatesMessages() async {
        // Same scenario via the group-thread path (fetchGroupMessages),
        // which the spec explicitly calls out as also in-bounds ("1:1,
        // group, or agent chat").
        let contact = FSContact(id: "reopen-group", name: "Reopen Group", type: .group, toUsers: ["member-1"])
        let userId = freshUserId("reopenGroupUser")
        let sessionKey = ChatThreadViewModel.roomKey(contact: contact, userId: userId)

        let cachedMessages = [
            msg("g1", sender: "member-1", timestamp: "2026-09-07T10:00:00Z"),
            msg("g2", sender: "member-1", timestamp: "2026-09-07T10:05:00Z"),
        ]
        await DiskCache.shared.save(cachedMessages, forKey: "messages:\(sessionKey)")

        let service = ThrowingTestDataService()
        service.fetchGroupMessagesResult = cachedMessages
        service.wsBaseOverride = "ws://127.0.0.1:1"

        let vm = ChatThreadViewModel()
        await vm.load(service: service, contact: contact, userId: userId)

        XCTAssertEqual(vm.messages.count, cachedMessages.count,
                       "group-thread reopen with unchanged count must still populate messages fully")
        XCTAssertEqual(vm.messages.last?.id, "g2",
                       "the .task block's unconditional scrollTo must have a real last message to target for a group thread reopen too")
        vm.disconnect()
    }

    // MARK: - 2. Source guard: the actual View-level fix

    private func sourceOf(_ relativePath: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_source_chatThreadView_taskBlock_scrollsToLastRowUnconditionally_afterLoad() throws {
        let source = try sourceOf("FellowScript/Chat/ChatThreadView.swift")

        XCTAssertTrue(source.contains("@State private var scrollProxy: ScrollViewProxy? = nil"),
                      "scrollProxy must be captured as @State so `.task` (outside ScrollViewReader) can reach it")
        XCTAssertTrue(source.contains(".onAppear { scrollProxy = proxy }"),
                      "scrollProxy must be captured via ScrollViewReader's onAppear, which fires before .task's network-bound load resolves")

        let scrollCall = "scrollProxy?.scrollTo(lastGroup.id, anchor: .bottom)"
        XCTAssertTrue(source.contains(scrollCall),
                      "the .task block must explicitly scroll to the last row once loading/grouping finishes")
        XCTAssertFalse(source.contains("withMotionAwareAnimation(.default, reduceMotion: reduceMotion) { scrollProxy?.scrollTo(lastGroup.id"),
                       "the initial on-open scroll must snap instantly, not animate from an undefined prior position")

        // Ordering: the initial scrollTo must happen after vm.load() resolves
        // within .task, not before -- otherwise messageGroups/threadRows
        // would still be empty/stale when it fires.
        guard let loadRange = source.range(of: "await vm.load(service: appState.service, contact: contact, userId: uid)"),
              let scrollRange = source.range(of: scrollCall, range: loadRange.upperBound..<source.endIndex)
        else {
            XCTFail("expected both vm.load(...) and the initial scrollTo(...) inside .task, with load first")
            return
        }
        XCTAssertLessThan(loadRange.lowerBound, scrollRange.lowerBound,
                          "initial scrollTo must run after vm.load() resolves, not before")

        // Guarded against an empty list -- must not force-unwrap.
        XCTAssertTrue(source.contains("if let lastGroup = messageGroups.last {\n                scrollProxy?.scrollTo(lastGroup.id, anchor: .bottom)\n            }"),
                      "initial scrollTo must be guarded by `if let ... .last`, not force-unwrapped -- a brand-new thread with zero messages must not crash")

        // The reactive path must remain present and unregressed: still
        // gated behind an actual count change, and still animated.
        XCTAssertTrue(source.contains(".onChange(of: vm.messages.count) { _ in"),
                      "the reactive scroll-on-new-message handler must remain, covering every later message-count change")
        XCTAssertTrue(source.contains("withMotionAwareAnimation(.default, reduceMotion: reduceMotion) { proxy.scrollTo(lastGroup.id, anchor: .bottom) }"),
                      "the reactive new-message scroll must remain animated -- only the initial on-open scroll should snap")
    }

    func test_source_agentChatView_taskBlock_scrollsToLastMessageUnconditionally_afterLoad() throws {
        let source = try sourceOf("FellowScript/Chat/AgentChatView.swift")

        XCTAssertTrue(source.contains("@State private var scrollProxy: ScrollViewProxy? = nil"),
                      "AgentChatView must carry the same scrollProxy capture as ChatThreadView -- identical structural fix")
        XCTAssertTrue(source.contains(".onAppear { scrollProxy = proxy }"),
                      "scrollProxy must be captured via ScrollViewReader's onAppear")

        let scrollCall = "scrollProxy?.scrollTo(last.id, anchor: .bottom)"
        XCTAssertTrue(source.contains(scrollCall),
                      "the .task block must explicitly scroll to the last message once vm.load() finishes")
        XCTAssertFalse(source.contains("withMotionAwareAnimation(.default, reduceMotion: reduceMotion) { scrollProxy?.scrollTo(last.id"),
                       "the initial on-open scroll must snap instantly, not animate")

        guard let loadRange = source.range(of: "await vm.load(service: appState.service, agentId: agent.id, userId: uid)"),
              let scrollRange = source.range(of: scrollCall, range: loadRange.upperBound..<source.endIndex)
        else {
            XCTFail("expected both vm.load(...) and the initial scrollTo(...) inside .task, with load first")
            return
        }
        XCTAssertLessThan(loadRange.lowerBound, scrollRange.lowerBound,
                          "initial scrollTo must run after vm.load() resolves, not before")

        XCTAssertTrue(source.contains("if let last = vm.messages.last {\n                scrollProxy?.scrollTo(last.id, anchor: .bottom)\n            }"),
                      "initial scrollTo must be guarded by `if let ... .last`, not force-unwrapped -- a brand-new agent thread with zero messages must not crash")

        // Reactive paths (new message, and the isThinking indicator) remain
        // unregressed.
        XCTAssertTrue(source.contains(".onChange(of: vm.messages.count) { _ in"),
                      "the reactive scroll-on-new-message handler must remain")
        XCTAssertTrue(source.contains("withMotionAwareAnimation(.default, reduceMotion: reduceMotion) { proxy.scrollTo(last.id, anchor: .bottom) }"),
                      "the reactive new-message scroll must remain animated")
        XCTAssertTrue(source.contains(".onChange(of: vm.isThinking) { t in"),
                      "the typing-indicator scroll handler must remain untouched by this fix")
    }
}
