// BadgeCountsStoreTests.swift -- coverage for task 20261016-notification-badges-logic
// (testing step 4).
//
// Proves the app-level badge state (BadgeCountsStore) and the unread baseline
// seeding (AppState+UnreadSeeding) behave as the spec requires:
//   * friend-request count and per-group join-request counts load at app level;
//   * a failed refresh (any error, including 404/not-found) preserves the last
//     known counts (throw-not-fabricate / preserve-cache-on-failed-refresh);
//   * sign-out clears everything and drops in-flight refreshes;
//   * foreground refresh is throttled;
//   * unread is computed from the shared ChatViewModel at app level, without
//     ChatRootView (acceptance criterion 1);
//   * baseline seeding (only when no read markers exist): first load seeds read,
//     later newer message is unread, reinstall does not flood, and an upgrader
//     with markers keeps real unread for never-opened conversations;
//   * unread rules: self-sent, unknown sender and member_joined never unread.

import XCTest
@testable import FellowScript

@MainActor
final class BadgeCountsStoreTests: XCTestCase {

    private let lastReadKey = "fs_last_read_timestamps"
    private var savedLastRead: Data?
    private let userIds = ["bc-user-1", "bc-user-2", "bc-user-upgrade", "bc-user-reinstall", "bc-user-e2e"]

    private let sessionKeys = ["fs_user_id", "fs_username", "fs_email"]
    private var savedSession: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        // A leaked stored session would make AppState.restoreSession() start a
        // background fetchUser that rewrites currentUser mid-test.
        for k in sessionKeys {
            savedSession[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
        savedLastRead = UserDefaults.standard.data(forKey: lastReadKey)
        UserDefaults.standard.removeObject(forKey: lastReadKey)
        for u in userIds { UserDefaults.standard.removeObject(forKey: "fs_last_read_seed_\(u)") }
    }

    override func tearDown() {
        for k in sessionKeys {
            if let v = savedSession[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        for u in userIds { UserDefaults.standard.removeObject(forKey: "fs_last_read_seed_\(u)") }
        if let savedLastRead { UserDefaults.standard.set(savedLastRead, forKey: lastReadKey) }
        else { UserDefaults.standard.removeObject(forKey: lastReadKey) }
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeState(userId: String = "bc-user-1",
                           service: DataServiceProtocol = ThrowingTestDataService()) -> AppState {
        let s = AppState(service: service)
        s.currentUser = FSUser(user_id: userId, username: "me", email: "me@example.com")
        s.isAuthenticated = true
        return s
    }

    private func dm(_ id: String, at ts: String, from sender: String? = "someone-else") -> FSContact {
        FSContact(id: id, name: "Friend \(id)", type: .friend, lastMessageAt: ts, lastMessageSenderId: sender)
    }

    private func grp(_ id: String, at ts: String, from sender: String? = "someone-else") -> FSContact {
        FSContact(id: id, name: "Group \(id)", type: .group, lastMessageAt: ts, lastMessageSenderId: sender)
    }

    private func rows(_ pairs: [(String, Int)]) -> [FSJoinRequestSummaryRow] {
        pairs.map { FSJoinRequestSummaryRow(groupId: $0.0, pendingCount: $0.1) }
    }

    // MARK: Friend-request count

    func test_refreshRequests_loadsFriendRequestCount_forAccountBadge() async {
        let svc = ThrowingTestDataService()
        svc.pendingFriendRequestCountResult = 3
        let state = makeState(service: svc)

        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 3)

        // Clears when none remain (a successful empty response is a real zero).
        svc.pendingFriendRequestCountResult = 0
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
    }

    func test_refreshRequests_isNoOp_whenSignedOut() async {
        let svc = ThrowingTestDataService()
        svc.pendingFriendRequestCountResult = 4
        let state = makeState(service: svc)
        state.isAuthenticated = false

        await state.badges.refreshRequests()

        XCTAssertEqual(svc.pendingFriendRequestCountCallCount, 0)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
    }

    // MARK: Join-request summary

    func test_refreshRequests_loadsJoinSummary_dropsZeroRows_andFeedsChatBadge() async {
        let svc = ThrowingTestDataService()
        svc.pendingJoinSummaryResult = rows([("g1", 2), ("g2", 1), ("g3", 0)])
        let state = makeState(service: svc)

        await state.badges.refreshRequests()

        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 2, "g2": 1])
        XCTAssertEqual(state.badges.joinRequestCount(forGroup: "g1"), 2)
        XCTAssertEqual(state.badges.joinRequestCount(forGroup: "g3"), 0)
        XCTAssertEqual(state.badges.pendingJoinRequestGroupCount, 2, "each group counts once, not per request")
        XCTAssertEqual(state.badges.chatBadgeCount(unreadConversations: 3), 5,
                       "Chat tab number = unread conversations + groups with join requests")
    }

    func test_refreshRequests_joinSummaryEmpty_clearsPreviousCounts() async {
        let svc = ThrowingTestDataService()
        svc.pendingJoinSummaryResult = rows([("g1", 2)])
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 2])

        svc.pendingJoinSummaryResult = []      // all approved/denied/expired (or flag off)
        await state.badges.refreshRequests()
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
    }

    func test_nonOwnedGroup_hasNoJoinDot_becauseSummaryOnlyListsOwnedGroups() async {
        let svc = ThrowingTestDataService()
        svc.pendingJoinSummaryResult = rows([("owned", 1)])
        let state = makeState(service: svc)
        await state.badges.refreshRequests()

        XCTAssertEqual(state.badges.joinRequestCount(forGroup: "member-only-group"), 0)
        let label = state.rowAccessibilityLabel("Group member", contact: grp("member-only-group", at: ""))
        XCTAssertFalse(label.contains("join request"))
        XCTAssertTrue(state.rowAccessibilityLabel("Group owned", contact: grp("owned", at: ""))
                        .contains("1 pending join request"))
    }

    // MARK: Failed refresh / 404 preserve counts

    func test_failedRefresh_preservesLastKnownCounts() async {
        let svc = ThrowingTestDataService()
        svc.pendingFriendRequestCountResult = 2
        svc.pendingJoinSummaryResult = rows([("g1", 4)])
        let state = makeState(service: svc)
        await state.badges.refreshRequests()

        svc.pendingFriendRequestCountError = AppError.networkError("offline")
        svc.pendingJoinSummaryError = AppError.networkError("offline")
        svc.pendingFriendRequestCountResult = 0
        svc.pendingJoinSummaryResult = []
        await state.badges.refreshRequests()

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 2, "a failed fetch must not zero the friend badge")
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 4], "a failed fetch must not clear join counts")
    }

    func test_notFound404_preservesLastKnownCounts_andFirstRunStaysZeroNotInvented() async {
        let svc = ThrowingTestDataService()
        svc.pendingFriendRequestCountError = AppError.notFound
        svc.pendingJoinSummaryError = AppError.notFound   // e.g. older backend without pending-summary
        let state = makeState(service: svc)

        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)

        svc.pendingFriendRequestCountError = nil
        svc.pendingJoinSummaryError = nil
        svc.pendingFriendRequestCountResult = 1
        svc.pendingJoinSummaryResult = rows([("g9", 2)])
        await state.badges.refreshRequests()
        svc.pendingFriendRequestCountError = AppError.notFound
        svc.pendingJoinSummaryError = AppError.notFound
        await state.badges.refreshRequests()

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 1)
        XCTAssertEqual(state.badges.joinRequestCounts, ["g9": 2])
    }

    func test_partialFailure_updatesOnlyTheSourceThatSucceeded() async {
        let svc = ThrowingTestDataService()
        svc.pendingFriendRequestCountResult = 1
        svc.pendingJoinSummaryResult = rows([("g1", 1)])
        let state = makeState(service: svc)
        await state.badges.refreshRequests()

        svc.pendingFriendRequestCountError = AppError.networkError("boom")   // friends fail
        svc.pendingJoinSummaryResult = rows([("g1", 1), ("g2", 5)])           // joins succeed
        await state.badges.refreshRequests()

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 1)
        XCTAssertEqual(state.badges.joinRequestCounts, ["g1": 1, "g2": 5])
    }

    // MARK: Action hooks

    func test_setters_updateAndClearCounts_afterUserActions() {
        let state = makeState()
        state.badges.setFriendRequestCount(2)
        state.badges.setJoinRequestCount(groupId: "g1", 3)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 2)
        XCTAssertEqual(state.badges.joinRequestCount(forGroup: "g1"), 3)

        state.badges.setFriendRequestCount(0)
        state.badges.setJoinRequestCount(groupId: "g1", 0)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty, "zero is not stored")

        state.badges.setFriendRequestCount(-4)
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0, "never negative")
    }

    // MARK: Accessibility summaries (VoiceOver includes the counts)

    func test_accessibilitySummaries_includeCounts() {
        XCTAssertNil(BadgeCountsStore.chatAccessibilitySummary(unreadConversations: 0, joinRequestGroups: 0))
        XCTAssertEqual(BadgeCountsStore.chatAccessibilitySummary(unreadConversations: 1, joinRequestGroups: 0),
                       "1 unread conversation")
        XCTAssertEqual(BadgeCountsStore.chatAccessibilitySummary(unreadConversations: 3, joinRequestGroups: 1),
                       "3 unread conversations, 1 join request")
        XCTAssertEqual(BadgeCountsStore.chatAccessibilitySummary(unreadConversations: 0, joinRequestGroups: 2),
                       "2 groups with join requests")
        XCTAssertNil(BadgeCountsStore.friendRequestAccessibilitySummary(0))
        XCTAssertEqual(BadgeCountsStore.friendRequestAccessibilitySummary(1), "1 friend request")
        XCTAssertEqual(BadgeCountsStore.friendRequestAccessibilitySummary(5), "5 friend requests")
    }

    // MARK: Sign-out

    func test_signOut_clearsAllBadgeState() async {
        let svc = ThrowingTestDataService()
        svc.pendingFriendRequestCountResult = 2
        svc.pendingJoinSummaryResult = rows([("g1", 1)])
        let state = makeState(service: svc)
        await state.badges.refreshRequests()
        XCTAssertEqual(state.badges.pendingFriendRequestCount, 2)

        state.signOut()

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0)
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
        XCTAssertEqual(state.unreadConversationCount, 0)
        XCTAssertNil(UserDefaults.standard.string(forKey: "fs_last_read_seed_bc-user-1"),
                     "sign-out also clears the per-user seed point")
    }

    func test_signOut_midRefresh_dropsTheInFlightResult() async {
        let svc = ThrowingTestDataService()
        svc.pendingFriendRequestCountResult = 7
        svc.pendingJoinSummaryResult = rows([("g1", 7)])
        svc.pendingSummaryDelayNanoseconds = 300_000_000
        let state = makeState(service: svc)

        let inFlight = Task { await state.badges.refreshRequests() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        state.signOut()
        await inFlight.value

        XCTAssertEqual(state.badges.pendingFriendRequestCount, 0, "a late response must not repopulate a signed-out store")
        XCTAssertTrue(state.badges.joinRequestCounts.isEmpty)
    }

    // MARK: Foreground throttle

    func test_foregroundRefresh_isThrottled_thenRunsAfterTheWindow_andForceBypasses() async {
        let svc = ThrowingTestDataService()
        svc.fetchContactsResult = [dm("d1", at: "2026-10-16T10:00:00Z")]
        let state = makeState(userId: "bc-user-1", service: svc)
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)   // counts as a refresh "now"

        await state.badges.refreshForeground(capabilities: .allOff)
        XCTAssertEqual(svc.fetchContactsCallCount, 0, "inside the throttle window nothing is fetched")
        XCTAssertEqual(svc.pendingFriendRequestCountCallCount, 0)
        XCTAssertEqual(svc.pendingJoinSummaryCallCount, 0)

        await state.badges.refreshForeground(capabilities: .allOff, force: true)
        XCTAssertEqual(svc.fetchContactsCallCount, 1)
        XCTAssertEqual(svc.pendingFriendRequestCountCallCount, 1)
        XCTAssertEqual(svc.pendingJoinSummaryCallCount, 1)

        await state.badges.refreshForeground(capabilities: .allOff)   // right after a refresh
        XCTAssertEqual(svc.fetchContactsCallCount, 1, "second call inside the window is throttled")

        try? await Task.sleep(nanoseconds: UInt64((BadgeCountsStore.foregroundThrottle + 0.3) * 1_000_000_000))
        await state.badges.refreshForeground(capabilities: .allOff)
        XCTAssertEqual(svc.fetchContactsCallCount, 2, "after the window a foreground refresh runs again")
        XCTAssertEqual(svc.pendingFriendRequestCountCallCount, 2)
    }

    // MARK: App-level unread (no ChatRootView involved)

    func test_unreadCount_isComputedFromSharedChatVM_withoutChatRootView() async {
        let svc = ThrowingTestDataService()
        svc.fetchContactsResult = [
            dm("u-a", at: "2026-10-16T09:00:00Z"),
            grp("u-b", at: "2026-10-16T09:30:00Z"),
            dm("u-self", at: "2026-10-16T09:40:00Z", from: "bc-user-e2e"),
        ]
        let state = makeState(userId: "bc-user-e2e", service: svc)
        // Existing user mid-upgrade: this seed is already recorded, no markers,
        // so messages older than the seed are read and newer ones are unread.
        UserDefaults.standard.set("2026-10-16T09:10:00Z", forKey: "fs_last_read_seed_bc-user-e2e")
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)

        await chatVM.load(service: svc, userId: "bc-user-e2e")

        XCTAssertEqual(state.unreadConversationCount, 1,
                       "only the group message newer than the seed and not self-sent is unread, computed at app level")
        XCTAssertTrue(state.hasUnread(chatVM.groups[0]))
    }

    func test_failedContactsRefresh_keepsExistingLists_andDoesNotSeed() async {
        let svc = ThrowingTestDataService()
        svc.fetchContactsError = AppError.networkError("offline")
        let state = makeState(userId: "bc-user-2", service: svc)
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)
        chatVM.friends = [dm("keep-1", at: "2026-10-16T08:00:00Z")]
        state.recomputeUnreadConversationCount(contacts: chatVM.friends)
        XCTAssertEqual(state.unreadConversationCount, 1)

        await chatVM.refresh(service: svc, userId: "bc-user-2")

        XCTAssertEqual(chatVM.friends.map(\.id), ["keep-1"], "failed fetch keeps the last known list")
        XCTAssertEqual(state.unreadConversationCount, 1, "unread count unchanged by a failed refresh")
        XCTAssertNil(state.unreadSeedDate, "a failed load must never seed the baseline")
        XCTAssertNil(UserDefaults.standard.string(forKey: "fs_last_read_seed_bc-user-2"))
    }

    // MARK: Baseline seeding

    func test_seeding_firstLoadSeedsRead_laterNewerMessageIsUnread() {
        let state = makeState(userId: "bc-user-1")
        let a = dm("seed-a", at: "2026-10-10T10:00:00Z")
        XCTAssertTrue(state.hasUnread(a), "precondition: unseeded user keeps the old 'no marker = unread' rule")

        XCTAssertTrue(state.seedUnreadBaselineIfNeeded(contacts: [a]))

        XCTAssertFalse(state.hasUnread(a), "first successful load seeds existing conversations as read")
        XCTAssertNotNil(state.unreadSeedDate)

        let aLater = dm("seed-a", at: "2026-10-10T10:05:00Z")
        XCTAssertTrue(state.hasUnread(aLater), "a newer message after the seed is unread")
        let aLaterSelf = dm("seed-a", at: "2026-10-10T10:05:00Z", from: "bc-user-1")
        XCTAssertFalse(state.hasUnread(aLaterSelf), "...unless the user sent it")
    }

    func test_seeding_isOncePerUser_andNeverOverwritesLaterMarkers() {
        let state = makeState(userId: "bc-user-1")
        let opened = dm("seed-opened", at: "2026-10-10T10:00:00Z")
        let other = dm("seed-other", at: "2026-10-10T09:00:00Z")

        XCTAssertTrue(state.seedUnreadBaselineIfNeeded(contacts: [opened, other]), "no markers at all => seeds")
        XCTAssertFalse(state.hasUnread(opened))
        XCTAssertFalse(state.hasUnread(other))

        let newerOpened = dm("seed-opened", at: "2026-10-10T11:00:00Z")   // arrived after seed
        XCTAssertTrue(state.hasUnread(newerOpened), "seed marker is the old lastMessageAt, so a newer message is unread")
        XCTAssertFalse(state.seedUnreadBaselineIfNeeded(contacts: [dm("late", at: "2026-10-10T12:00:00Z")]),
                       "second call is a no-op")
        XCTAssertTrue(state.hasUnread(dm("late", at: "2026-10-10T12:00:00Z")),
                      "a conversation first seen after seeding with a newer message is unread (not retro-seeded)")
        XCTAssertFalse(state.hasUnread(dm("late-old", at: "2026-10-10T08:00:00Z")),
                       "a conversation with no marker whose newest message predates the seed point is read")
    }

    func test_seeding_skippedWhenAnyReadMarkerExists() {
        let state = makeState(userId: "bc-user-1")
        state.markRead(dm("has-marker", at: "2026-10-10T10:00:00Z"))
        XCTAssertFalse(state.seedUnreadBaselineIfNeeded(contacts: [dm("never", at: "2026-10-10T09:00:00Z")]),
                       "a user with persisted read markers (an upgrader) is never baselined")
        XCTAssertNil(state.unreadSeedDate)
    }

    func test_seeding_isPerUser() {
        let one = makeState(userId: "bc-user-1")
        XCTAssertTrue(one.seedUnreadBaselineIfNeeded(contacts: [dm("p", at: "2026-10-10T10:00:00Z")]))
        // Markers are device-wide but wiped on sign-out; simulate that handover.
        UserDefaults.standard.removeObject(forKey: lastReadKey)
        let two = makeState(userId: "bc-user-2")
        XCTAssertNil(two.unreadSeedDate, "user two on the same device is not covered by user one's seed")
        XCTAssertTrue(two.seedUnreadBaselineIfNeeded(contacts: [dm("p", at: "2026-10-10T10:00:00Z")]))
    }

    func test_seeding_noContacts_usesDeviceNow_soNothingOldBecomesUnread() {
        let state = makeState(userId: "bc-user-1")
        XCTAssertTrue(state.seedUnreadBaselineIfNeeded(contacts: []))
        XCTAssertNotNil(state.unreadSeedDate)
        XCTAssertFalse(state.hasUnread(dm("old", at: "2020-01-01T00:00:00Z")))
    }

    func test_reinstall_withoutMarkers_doesNotFloodHistoryAsUnread() async {
        // Reinstall / second device: no fs_last_read_timestamps, no seed key.
        let svc = ThrowingTestDataService()
        svc.fetchContactsResult = (0..<6).map { i in
            i % 2 == 0 ? dm("re-d\(i)", at: "2026-09-0\(i + 1)T10:00:00Z") : grp("re-g\(i)", at: "2026-09-0\(i + 1)T10:00:00Z")
        }
        let state = makeState(userId: "bc-user-reinstall", service: svc)
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)

        await chatVM.load(service: svc, userId: "bc-user-reinstall")

        XCTAssertEqual(chatVM.friends.count + chatVM.groups.count, 6)
        XCTAssertEqual(state.unreadConversationCount, 0, "old history must not be flagged unread after a reinstall")

        // ...but a message that arrives afterwards is.
        svc.fetchContactsResult = svc.fetchContactsResult! + [dm("re-new", at: "2099-01-01T00:00:00Z")]
        await chatVM.refresh(service: svc, userId: "bc-user-reinstall")
        XCTAssertEqual(state.unreadConversationCount, 1)
    }

    /// An existing user upgrading to this build already has persisted read
    /// markers (fs_last_read_timestamps, UserDefaults since build 47). They must
    /// NOT be baselined: conversations never opened keep showing unread when the
    /// last message is not theirs, and opened ones keep their markers.
    func test_upgrade_existingUserWithMarkers_keepsRealUnreadForNeverOpenedConversations() async {
        let state = makeState(userId: "bc-user-upgrade")
        let openedUpToDate = dm("up-opened-current", at: "2026-10-01T10:00:00Z")
        let openedThenNewMsg = dm("up-opened-stale", at: "2026-10-01T09:00:00Z")
        state.markRead(openedUpToDate)
        state.markRead(openedThenNewMsg)

        let svc = ThrowingTestDataService()
        let openedStaleNow = dm("up-opened-stale", at: "2026-10-12T09:00:00Z")           // new message since open
        let neverOpenedDM = dm("up-never-dm", at: "2026-09-15T09:00:00Z")                // never opened, unseen message
        let neverOpenedGroup = grp("up-never-grp", at: "2026-10-05T09:00:00Z")           // never opened, unseen message
        let neverOpenedSelf = dm("up-never-self", at: "2026-10-05T09:00:00Z", from: "bc-user-upgrade")
        svc.fetchContactsResult = [openedUpToDate, openedStaleNow, neverOpenedDM, neverOpenedGroup, neverOpenedSelf]

        XCTAssertNil(state.unreadSeedDate)
        let chatVM = ChatViewModel()
        state.badges.attach(chatVM: chatVM)
        await chatVM.load(service: svc, userId: "bc-user-upgrade")

        XCTAssertNil(state.unreadSeedDate, "an upgrader with markers is not seeded")
        XCTAssertFalse(state.hasUnread(openedUpToDate))
        XCTAssertTrue(state.hasUnread(openedStaleNow))
        XCTAssertTrue(state.hasUnread(neverOpenedDM), "never-opened DM from someone else stays unread")
        XCTAssertTrue(state.hasUnread(neverOpenedGroup), "never-opened group message from someone else stays unread")
        XCTAssertFalse(state.hasUnread(neverOpenedSelf), "self-sent is never unread")
        XCTAssertEqual(state.unreadConversationCount, 3)
    }

    // MARK: Unread rules

    func test_unreadRules_selfSentUnknownSenderAndOthers() {
        let state = makeState(userId: "bc-user-1")
        XCTAssertFalse(state.hasUnread(dm("r1", at: "2026-10-16T10:00:00Z", from: "bc-user-1")), "self-sent never unread")
        XCTAssertFalse(state.hasUnread(grp("r2", at: "2026-10-16T10:00:00Z", from: "bc-user-1")), "self-sent group never unread")
        XCTAssertFalse(state.hasUnread(dm("r3", at: "2026-10-16T10:00:00Z", from: nil)), "unknown sender never unread")
        XCTAssertFalse(state.hasUnread(grp("r4", at: "2026-10-16T10:00:00Z", from: nil)), "unknown sender never unread (group)")
        XCTAssertFalse(state.hasUnread(dm("r5", at: "", from: "x")), "no message => not unread")
        XCTAssertTrue(state.hasUnread(dm("r6", at: "2026-10-16T10:00:00Z", from: "x")))
        XCTAssertTrue(state.hasUnread(grp("r7", at: "2026-10-16T10:00:00Z", from: "x")))
    }

    func test_unreadRules_openingThreadClearsRow_andCountDrops() {
        let state = makeState(userId: "bc-user-1")
        let a = dm("o1", at: "2026-10-16T10:00:00Z")
        let b = grp("o2", at: "2026-10-16T10:00:00Z")
        state.recomputeUnreadConversationCount(contacts: [a, b])
        XCTAssertEqual(state.unreadConversationCount, 2)
        state.markRead(a)
        state.recomputeUnreadConversationCount(contacts: [a, b])
        XCTAssertEqual(state.unreadConversationCount, 1)
    }

    /// member_joined system lines must never raise an unread: the contact-list
    /// load (the only source of lastMessageAt / lastMessageSenderId) must not
    /// request system lines. Pinned at source because the filter lives in the
    /// request URL; the server side (system lines have no message_recipients
    /// rows, excluded without include_system) is covered by
    /// api/tests/test_member_joined_line.py.
    func test_memberJoined_neverUnread_contactsLoadDoesNotRequestSystemLines() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let src = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Services/NetworkService+Contacts.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        XCTAssertFalse(text.contains("include_system"), "contacts fetch must not ask for system lines")
        XCTAssertFalse(text.contains("includeSystemQuery"), "contacts fetch must not ask for system lines")

        let badges = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Services/BadgeCountsStore.swift")
        let badgesText = try String(contentsOf: badges, encoding: .utf8)
        XCTAssertFalse(badgesText.contains("includeSystemQuery"))
    }
}
