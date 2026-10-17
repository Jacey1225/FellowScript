// BadgePersistenceTests.swift -- testing gate for task
// 20261016-ipad-parity-and-persistent-badges.
//
// Store + persistence behaviour (BadgeCountsStore over BadgeState):
//   * per-user UserDefaults key fs_badge_state_<uid>; hydrated synchronously at
//     launch (AppState.init) so the first frame already shows last-known badges;
//   * sign-out wipes that user's key and nothing is rewritten afterwards;
//     another user's state is never loaded for this user;
//   * corrupted or wrong-version payloads are dropped (cache, never truth);
//   * failed refresh changes nothing (memory and disk); empty 200 clears;
//   * seen events (friendRequestsViewed / joinRequestsViewed) clear while the
//     items are still pending; refresh does not resurrect; new item re-raises;
//   * unread count is persisted, hydrated, and NOT zeroed by an unproven empty
//     contacts list, but is replaced by a proven load;
//   * the screens' "seen" modifiers fire only with a loaded list.

import XCTest
import SwiftUI
import UIKit
@testable import FellowScript

@MainActor
final class BadgePersistenceTests: XCTestCase {

    private let users = ["bp-user-1", "bp-user-2", "bp-user-3"]
    private let sessionKeys = ["fs_user_id", "fs_username", "fs_email"]
    private var savedSession: [String: Any?] = [:]
    private let lastReadKey = "fs_last_read_timestamps"
    private var savedLastRead: Data?
    private let t1 = "2026-10-16T22:41:07.123456Z"
    private let t2 = "2026-10-16T22:41:08.000000Z"

    override func setUp() {
        super.setUp()
        for k in sessionKeys {
            savedSession[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
        savedLastRead = UserDefaults.standard.data(forKey: lastReadKey)
        UserDefaults.standard.removeObject(forKey: lastReadKey)
        for u in users {
            UserDefaults.standard.removeObject(forKey: BadgeCountsStore.persistenceKey(u))
            UserDefaults.standard.removeObject(forKey: "fs_last_read_seed_\(u)")
        }
    }

    override func tearDown() {
        for u in users {
            UserDefaults.standard.removeObject(forKey: BadgeCountsStore.persistenceKey(u))
            UserDefaults.standard.removeObject(forKey: "fs_last_read_seed_\(u)")
        }
        for k in sessionKeys {
            if let v = savedSession[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        if let savedLastRead { UserDefaults.standard.set(savedLastRead, forKey: lastReadKey) }
        else { UserDefaults.standard.removeObject(forKey: lastReadKey) }
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeService() -> ThrowingTestDataService {
        let svc = ThrowingTestDataService()
        svc.fetchUserError = AppError.networkError("offline")   // restoreSession's background refresh stays inert
        return svc
    }

    private func makeState(userId: String = "bp-user-1", service: ThrowingTestDataService? = nil) -> AppState {
        let s = AppState(service: service ?? makeService())
        s.currentUser = FSUser(user_id: userId, username: "me", email: "me@example.com")
        s.isAuthenticated = true
        s.badges.hydrate(userId: userId)
        return s
    }

    private func persisted(_ uid: String) -> BadgeState? { BadgeCountsStore.loadPersistedState(userId: uid) }

    private func seedDisk(_ state: BadgeState, for uid: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: BadgeCountsStore.persistenceKey(uid))
    }

    private func row(_ g: String, _ n: Int, _ newest: String?) -> FSJoinRequestSummaryRow {
        FSJoinRequestSummaryRow(groupId: g, pendingCount: n, newestRequestAt: newest)
    }

    private func dm(_ id: String, at ts: String, from sender: String? = "someone-else") -> FSContact {
        FSContact(id: id, name: "Friend \(id)", type: .friend, lastMessageAt: ts, lastMessageSenderId: sender)
    }

    // MARK: Key + persistence

    func test_key_isPerUser() {
        XCTAssertEqual(BadgeCountsStore.persistenceKey("abc"), "fs_badge_state_abc")
        XCTAssertNotEqual(BadgeCountsStore.persistenceKey("a"), BadgeCountsStore.persistenceKey("b"))
    }

    func test_refresh_persistsUnderThisUsersKeyOnly() async {
        let svc = makeService()
        svc.pendingFriendRequestCountResult = 2
        svc.pendingJoinSummaryResult = [row("g1", 1, t1)]
        let state = makeState(userId: "bp-user-1", service: svc)

        await state.badges.refreshRequests()

        let saved = persisted("bp-user-1")
        XCTAssertEqual(saved?.friendPending.count, 2)
        XCTAssertEqual(saved?.joinSummary["g1"]?.newest, t1)
        XCTAssertNil(persisted("bp-user-2"), "no write under any other user's key")
    }

    // MARK: Load at launch (first frame)

    func test_launch_hydratesBadgesSynchronously_beforeAnyNetworkResponse() throws {
        var s = BadgeState()
        s.applyFriendSnapshot(["r1", "r2"])
        s.applyJoinSnapshot([row("g1", 3, t1)])
        s.unreadConversations = 4
        try seedDisk(s, for: "bp-user-1")
        UserDefaults.standard.set("bp-user-1", forKey: "fs_user_id")
        UserDefaults.standard.set("me", forKey: "fs_username")
        UserDefaults.standard.set("me@example.com", forKey: "fs_email")

        let svc = makeService()
        let state = AppState(service: svc)   // cold launch with a stored session

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 2, "Account badge on the first frame")
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 3], "join-request dot on the first frame")
        XCTAssertEqual(state.unreadConversationCount, 4, "Chat unread count on the first frame")
        XCTAssertEqual(state.badges.chatBadgeCount(unreadConversations: state.unreadConversationCount), 5)
        XCTAssertEqual(svc.pendingFriendRequestCountCallCount, 0, "hydrate used no network")
        XCTAssertEqual(svc.pendingJoinSummaryCallCount, 0)
    }

    func test_launch_signedOut_hydratesNothing() throws {
        var s = BadgeState(); s.applyFriendSnapshot(["r1"])
        try seedDisk(s, for: "bp-user-1")
        let state = AppState(service: makeService())   // no stored session
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
    }

    func test_launch_failedRefreshAfterHydrate_keepsHydratedBadges() async throws {
        var s = BadgeState(); s.applyFriendSnapshot(["r1"]); s.applyJoinSnapshot([row("g1", 2, t1)])
        try seedDisk(s, for: "bp-user-1")
        let svc = makeService()
        svc.pendingFriendRequestCountError = AppError.networkError("offline")
        svc.pendingJoinSummaryError = AppError.networkError("offline")
        let state = makeState(userId: "bp-user-1", service: svc)

        await state.badges.refreshRequests()

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 1)
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 2])
        XCTAssertEqual(persisted("bp-user-1"), s, "disk unchanged by a failed refresh")
    }

    // MARK: Corrupt / wrong version

    func test_corruptPayload_isDropped_andStartsEmpty() {
        UserDefaults.standard.set(Data("{not json".utf8), forKey: BadgeCountsStore.persistenceKey("bp-user-1"))
        XCTAssertNil(persisted("bp-user-1"))
        let state = makeState(userId: "bp-user-1")
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
    }

    func test_wrongTypePayload_isDropped() {
        UserDefaults.standard.set(Data(#"{"version":1,"friendPending":"nope"}"#.utf8),
                                  forKey: BadgeCountsStore.persistenceKey("bp-user-1"))
        XCTAssertNil(persisted("bp-user-1"))
    }

    func test_wrongVersionPayload_isDropped() throws {
        var s = BadgeState(); s.applyFriendSnapshot(["r1", "r2"])
        s.version = BadgeState.currentVersion + 1
        try seedDisk(s, for: "bp-user-1")
        XCTAssertNil(persisted("bp-user-1"))
        let state = makeState(userId: "bp-user-1")
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0, "a future/unknown schema is never trusted")
    }

    // MARK: Sign-out wipe / user isolation

    func test_signOut_wipesThatUsersKey_andNeverRewritesIt() async throws {
        let svc = makeService()
        svc.pendingFriendRequestCountResult = 2
        let state = makeState(userId: "bp-user-1", service: svc)
        await state.badges.refreshRequests()
        XCTAssertNotNil(persisted("bp-user-1"))

        state.signOut()

        XCTAssertNil(persisted("bp-user-1"), "sign-out removes fs_badge_state_<uid>")
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
        XCTAssertEqual(state.unreadConversationCount, 0)

        // Late work after sign-out must not resurrect anything on disk.
        state.badges.friendRequestsViewed(ids: ["r1"])
        state.badges.noteUnreadCount(3)
        state.badges.publish()
        XCTAssertNil(persisted("bp-user-1"))
    }

    func test_signOut_leavesOtherUsersStateAlone() throws {
        var other = BadgeState(); other.applyFriendSnapshot(["x"])
        try seedDisk(other, for: "bp-user-2")
        let state = makeState(userId: "bp-user-1")
        state.signOut()
        XCTAssertEqual(persisted("bp-user-2"), other)
    }

    func test_accountSwitch_loadsOnlyTheNewUsersState() throws {
        var a = BadgeState(); a.applyFriendSnapshot(["a1", "a2", "a3"]); a.unreadConversations = 9
        var b = BadgeState(); b.applyJoinSnapshot([row("gB", 1, t1)])
        try seedDisk(a, for: "bp-user-1")
        try seedDisk(b, for: "bp-user-2")
        let state = makeState(userId: "bp-user-1")
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 3)
        XCTAssertEqual(state.unreadConversationCount, 9)

        // What persist(user) does on sign-in: switch currentUser, then hydrate.
        state.currentUser = FSUser(user_id: "bp-user-2", username: "two", email: "two@example.com")
        state.badges.hydrate(userId: "bp-user-2")

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0, "no leakage of user 1's friend badge")
        XCTAssertEqual(state.badges.joinRequestCounts, ["gB": 1])
        XCTAssertEqual(state.unreadConversationCount, 0)
        XCTAssertEqual(persisted("bp-user-1"), a, "switching does not mutate the other user's record")
    }

    func test_newUserWithNoRecord_startsEmpty() {
        let state = makeState(userId: "bp-user-3")
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
    }

    // MARK: Failed refresh vs empty success

    func test_failedRefresh_changesNothing_inMemoryOrOnDisk() async {
        let svc = makeService()
        svc.pendingFriendRequestCountResult = 3
        svc.pendingJoinSummaryResult = [row("g1", 2, t1)]
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        let before = persisted("bp-user-1")

        svc.pendingFriendRequestCountError = AppError.networkError("boom")
        svc.pendingJoinSummaryError = AppError.notFound
        svc.pendingFriendRequestCountResult = 0
        svc.pendingJoinSummaryResult = []
        await state.badges.refreshRequests()

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 3)
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 2])
        XCTAssertEqual(persisted("bp-user-1"), before)
    }

    func test_failedRefreshAfterSeen_doesNotRaiseOrLowerAnything() async {
        let svc = makeService()
        svc.pendingFriendRequestCountResult = 2
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        state.badges.friendRequestsViewed(ids: (0..<2).map { "test-requester-\($0)" })
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)

        svc.pendingFriendRequestCountError = AppError.networkError("offline")
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0, "a failed fetch must not re-raise a seen badge")
    }

    func test_emptySuccessfulResponse_clears_andPersistsTheClear() async {
        let svc = makeService()
        svc.pendingFriendRequestCountResult = 2
        svc.pendingJoinSummaryResult = [row("g1", 1, t1)]
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 2)

        svc.pendingFriendRequestCountResult = 0
        svc.pendingJoinSummaryResult = []
        await state.badges.refreshRequests()

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
        XCTAssertEqual(persisted("bp-user-1")?.friendPending, [])
        XCTAssertEqual(persisted("bp-user-1")?.joinSummary.isEmpty, true)
    }

    // MARK: Friend-request seen

    func test_friendRequestsSeen_clearsWhileStillPending_andSurvivesRefreshAndRelaunch() async {
        let svc = makeService()
        svc.pendingFriendRequestCountResult = 2      // ids test-requester-0/1
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 2)

        state.badges.friendRequestsViewed(ids: ["test-requester-0", "test-requester-1"])
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0, "seen while both still pending")

        await state.badges.refreshRequests()         // foreground refresh, still pending
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0, "refresh does not resurrect")

        // Relaunch: new store hydrates the same record.
        let relaunched = makeState(userId: "bp-user-1", service: svc)
        XCTAssertEqual(relaunched.badges.pendingFriendRequestCount, 0, "seen survives kill + relaunch")
    }

    func test_newFriendRequestAfterSeen_reRaises() async {
        let svc = makeService()
        svc.pendingFriendRequestCountResult = 1
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        state.badges.friendRequestsViewed(ids: ["test-requester-0"])
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)

        svc.pendingFriendRequestCountResult = 2      // adds test-requester-1
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 1, "only the new requester is unseen")
    }

    func test_legacyCountShim_isTreatedAsProvenUnseen() {
        let state = makeState()
        state.badges.setFriendRequestCount(3)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 3)
        state.badges.setFriendRequestCount(0)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
    }

    // MARK: Join-request newest_request_at logic

    func test_joinRequests_unseenUntilOwnerOpensList_thenClearsWhileStillPending() async {
        let svc = makeService()
        svc.pendingJoinSummaryResult = [row("g1", 2, t1)]
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 2])
        XCTAssertEqual(state.badges.pendingJoinRequestGroupCount, 1)

        state.badges.joinRequestsViewed(groupId: "g1", pendingCount: 2, newestRequestAt: t1)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty, "owner opened the list: dot cleared though 2 are pending")

        await state.badges.refreshRequests()         // same newest_request_at
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
        XCTAssertEqual(state.badges.chatBadgeCount(unreadConversations: 0), 0)
    }

    func test_newerJoinRequest_reBadges_andPersists() async {
        let svc = makeService()
        svc.pendingJoinSummaryResult = [row("g1", 1, t1)]
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        state.badges.joinRequestsViewed(groupId: "g1", pendingCount: 1, newestRequestAt: t1)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)

        svc.pendingJoinSummaryResult = [row("g1", 2, t2)]   // a newer applicant
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 2])

        let relaunched = makeState(userId: "bp-user-1", service: svc)
        XCTAssertEqual(relaunched.badges.joinRequestCounts, ["g1": 2], "the re-raised dot survives relaunch")
    }

    func test_joinRequestsSeen_surviveRelaunch_withoutNewerRequest() async {
        let svc = makeService()
        svc.pendingJoinSummaryResult = [row("g1", 1, t1)]
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        state.badges.joinRequestsViewed(groupId: "g1", pendingCount: 1, newestRequestAt: t1)

        let relaunched = makeState(userId: "bp-user-1", service: svc)
        XCTAssertTrue(relaunched.badges.joinRequestCounts.isEmpty)
        await relaunched.badges.refreshRequests()
        XCTAssertTrue(relaunched.badges.joinRequestCounts.isEmpty, "refresh after relaunch keeps it seen")
    }

    func test_approveDecrement_updatesCountWithoutReRaisingSeenGroup() {
        let state = makeState()
        state.badges.joinRequestsViewed(groupId: "g1", pendingCount: 2, newestRequestAt: t2)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
        state.badges.joinRequestsViewed(groupId: "g1", pendingCount: 1, newestRequestAt: t1)   // one approved
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
        state.badges.joinRequestsViewed(groupId: "g1", pendingCount: 0, newestRequestAt: nil)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
    }

    // MARK: Unread count persistence

    func test_unreadCount_isPersistedWhenItChanges() async {
        let svc = makeService()
        svc.fetchContactsResult = [dm("d1", at: "2026-10-16T10:00:00Z"), dm("d2", at: "2026-10-16T10:05:00Z")]
        let state = makeState(service: svc)
        // A marker for d1 so the baseline seed does not mark everything read.
        UserDefaults.standard.set("2026-10-16T09:00:00Z", forKey: "fs_last_read_seed_bp-user-1")
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)

        await chatVM.load(service: svc, userId: "bp-user-1")

        XCTAssertEqual(state.unreadConversationCount, 2)
        XCTAssertEqual(persisted("bp-user-1")?.unreadConversations, 2)
    }

    func test_unreadCount_notZeroedByUnprovenEmptyContacts() throws {
        var s = BadgeState(); s.unreadConversations = 3
        try seedDisk(s, for: "bp-user-1")
        let state = makeState(userId: "bp-user-1")
        XCTAssertEqual(state.unreadConversationCount, 3)

        state.badges.attach(chatVM: ChatViewModel())    // contacts empty, nothing proven yet

        XCTAssertEqual(state.unreadConversationCount, 3, "empty-but-unproven contacts must not zero the persisted count")
        XCTAssertEqual(persisted("bp-user-1")?.unreadConversations, 3)
    }

    // bp-user-3 never has contacts cached on disk by another test, so a failed load really has nothing.
    func test_unreadCount_notZeroedByFailedFirstLoad() async throws {
        var s = BadgeState(); s.unreadConversations = 3
        try seedDisk(s, for: "bp-user-3")
        let svc = makeService()
        svc.fetchContactsError = AppError.networkError("offline")
        let state = makeState(userId: "bp-user-3", service: svc)
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)

        await chatVM.load(service: svc, userId: "bp-user-3")

        XCTAssertEqual(state.unreadConversationCount, 3)
        XCTAssertEqual(persisted("bp-user-3")?.unreadConversations, 3)
    }

    func test_unreadCount_provenEmptyLoad_doesZeroIt() async throws {
        var s = BadgeState(); s.unreadConversations = 3
        try seedDisk(s, for: "bp-user-1")
        let svc = makeService()
        svc.fetchContactsResult = []          // HTTP success, genuinely no conversations
        let state = makeState(userId: "bp-user-1", service: svc)
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)

        await chatVM.load(service: svc, userId: "bp-user-1")

        XCTAssertEqual(state.unreadConversationCount, 0, "a proven load replaces the stale hydrate")
        XCTAssertEqual(persisted("bp-user-1")?.unreadConversations, 0)
    }

    func test_unreadCount_markReadOnThreadOpen_updatesPersistedCount() async {
        let svc = makeService()
        svc.fetchContactsResult = [dm("d1", at: "2026-10-16T10:00:00Z")]
        UserDefaults.standard.set("2026-10-16T09:00:00Z", forKey: "fs_last_read_seed_bp-user-1")
        let state = makeState(service: svc)
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)
        await chatVM.load(service: svc, userId: "bp-user-1")
        XCTAssertEqual(persisted("bp-user-1")?.unreadConversations, 1)

        state.markRead(chatVM.friends[0])    // ChatThreadView.task on open

        XCTAssertEqual(state.unreadConversationCount, 0)
        XCTAssertEqual(persisted("bp-user-1")?.unreadConversations, 0)
    }

    // MARK: Screen "seen" modifiers (hosted)

    private func host<V: View>(_ view: V, state: AppState) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.rootViewController = UIHostingController(rootView: view.environmentObject(state))
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return window
    }

    func test_friendRequestBadgeSync_firesSeenOnlyWithLoadedList() async {
        let svc = makeService()
        svc.pendingFriendRequestCountResult = 1
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 1)

        let notLoaded = host(Color.clear.modifier(FriendRequestBadgeSync(ids: ["test-requester-0"], loaded: false)), state: state)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 1, "screen visible but list not loaded: not seen")
        notLoaded.isHidden = true

        let loaded = host(Color.clear.modifier(FriendRequestBadgeSync(ids: ["test-requester-0"], loaded: true)), state: state)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0, "visible with a loaded list: seen")
        loaded.isHidden = true
    }

    func test_joinRequestBadgeSync_firesSeenOnlyWithLoadedList() async {
        let svc = makeService()
        svc.pendingJoinSummaryResult = [row("g1", 1, t1)]
        let state = makeState(service: svc)
        await state.badges.refreshRequests()

        let notLoaded = host(Color.clear.modifier(JoinRequestBadgeSync(groupId: "g1", loaded: false, pendingCount: 1, newestRequestAt: t1)), state: state)
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 1])
        notLoaded.isHidden = true

        let loaded = host(Color.clear.modifier(JoinRequestBadgeSync(groupId: "g1", loaded: true, pendingCount: 1, newestRequestAt: t1)), state: state)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
        loaded.isHidden = true
    }
}
