// ChatThreadCacheIsolationRegressionTests.swift — regression coverage for
// task 20260904-compliance-security-fixes (OWASP H3: cross-account DM cache
// leak), testing gate step 2.
//
// Root cause: ChatThreadViewModel.load() previously cached a friend-DM
// thread under the bare key "messages:\(contact.id)" -- with no userId
// component at all, unlike every other DiskCache call site in the codebase
// (and unlike the "sessions:\(sessionKey)" cache one line below it in the
// same function). On a shared device, two different accounts opening a
// thread with the *same* friend contact would read and overwrite each
// other's cached message history: account A's private DM history with
// "friend-X" could be shown to account B the instant B opened a thread with
// the same friend-X contact, before B's own network fetch resolved (and B's
// own fetch success would in turn clobber A's cache entry for next time).
//
// Fixed by keying the cache with the already-computed sessionKey
// (`ChatThreadViewModel.roomKey`, sorted [userId, contact.id] for a friend
// DM) instead of bare contact.id, so two different userIds against the same
// contact land in two distinct cache entries.
//
// This test proves the isolation directly through the real load() code path
// (not just the roomKey helper in isolation): it pre-seeds two distinct
// DiskCache entries under each user's own sessionKey, forces the network
// fetch to fail via the new fetchFriendMessagesError seam (AppStateAuthAccountTests.swift)
// so `messages` is left exactly as the cache-first read set it (load()'s
// `try? ... ?? messages` collapses the throw to nil, keeping the cached
// value), and asserts each user's load() only ever surfaces its own cached
// thread -- never the other account's.
import XCTest
@testable import FellowScript

private func msg(_ id: String, _ text: String) -> FSMessage {
    FSMessage(id: id, text: text, mine: false, sender: "friend-X", timestamp: "2026-09-04 00:00:00")
}

@MainActor
final class ChatThreadCacheIsolationRegressionTests: XCTestCase {

    /// Fresh per-test user ids -- DiskCache.shared is the real on-disk cache
    /// (persists across test runs in the same simulator container), so a
    /// stable/shared id would risk cross-test pollution. Same rationale as
    /// NotesGroupRefreshNullDataRegressionTests.freshUserId().
    private func freshUserId(_ label: String) -> String { "\(label)-\(UUID().uuidString)" }

    func test_load_twoDifferentUserIdsSameContact_neverShareOneAnothersCachedMessageHistory() async throws {
        let contact = FSContact(id: "cache-iso-contact", name: "Shared Friend", type: .friend)
        let userA = freshUserId("userA")
        let userB = freshUserId("userB")

        let sessionKeyA = ChatThreadViewModel.roomKey(contact: contact, userId: userA)
        let sessionKeyB = ChatThreadViewModel.roomKey(contact: contact, userId: userB)
        XCTAssertNotEqual(sessionKeyA, sessionKeyB,
                           "sanity check: two different userIds against the same contact must produce distinct sessionKeys")

        let messagesA = [msg("a1", "account A's private message")]
        let messagesB = [msg("b1", "account B's private message")]

        // Pre-seed each account's own cache entry directly, exactly as a
        // prior load() would have via `DiskCache.shared.save(messages, forKey: "messages:\(sessionKey)")`.
        await DiskCache.shared.save(messagesA, forKey: "messages:\(sessionKeyA)")
        await DiskCache.shared.save(messagesB, forKey: "messages:\(sessionKeyB)")

        // Regression guard against the OLD buggy key format: if the fix ever
        // regressed back to bare contact.id, both accounts would instead
        // collide on this single entry.
        await DiskCache.shared.remove(forKey: "messages:\(contact.id)")

        let service = ThrowingTestDataService()
        // Force the network fetch to fail so `messages` is left exactly as
        // the cache-first read set it -- MockDataService.fetchFriendMessages
        // ignores userId/friendId and always returns the same fixed fixture,
        // which would otherwise make both accounts converge on identical
        // `messages` and mask the very leak this test exists to catch.
        service.fetchFriendMessagesError = AppError.networkError("simulated fetch failure -- isolate the cache-first read")
        // Point the WebSocket connect at an address nothing is listening on
        // so this test doesn't depend on/attempt any real network I/O;
        // connectWebSocket() itself only opens the task, it doesn't block or
        // throw synchronously.
        service.wsBaseOverride = "ws://127.0.0.1:1"

        let vmA = ChatThreadViewModel()
        await vmA.load(service: service, contact: contact, userId: userA)
        XCTAssertEqual(vmA.messages.map(\.id), ["a1"],
                       "account A's load() must surface only its own cached message history")

        let vmB = ChatThreadViewModel()
        await vmB.load(service: service, contact: contact, userId: userB)
        XCTAssertEqual(vmB.messages.map(\.id), ["b1"],
                       "account B's load() must surface only its own cached message history, not account A's")

        XCTAssertNotEqual(vmA.messages.map(\.id), vmB.messages.map(\.id),
                           "regression guard for the exact leak: two different accounts must never converge on the same cached thread for a shared contact")

        vmA.disconnect()
        vmB.disconnect()
    }
}
