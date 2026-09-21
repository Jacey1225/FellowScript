// ChatUnreadBadgeRegressionTests.swift — coverage for
// task: 20260913-chat-unread-badges, testing step 3.
//
// Proves AppState's generic unread-conversation-tracking mechanism
// (hasUnread(_:) / markRead(_:) / unreadConversationCount /
// lastReadVersion — Services/AppState.swift) behaves correctly for both
// friend and group FSContact instances (the intake spec's "one generic
// mechanism keyed by conversation/contact id" decision), matches the
// acceptance criteria's anti-fabrication rule (no unread indicator without
// a genuinely newer message), and survives a relaunch (client-local
// UserDefaults persistence) while being correctly wiped on sign-out so a
// second account on the same device never inherits the first account's
// read/unread state for a colliding conversation id.
//
// This is manager/service-logic coverage (per this project's write-tests
// skill: iOS tests exercise service/manager logic, not UI layout) — the
// FloatingTabBar/ContactRow badge rendering itself is a thin, directly-
// visible `if appState.hasUnread(...)`/`if showBadge` read of this exact
// state, so proving the state is correct is what actually guards against a
// regression here; there is no independent view-layer logic to test.

import XCTest
@testable import FellowScript

@MainActor
final class ChatUnreadBadgeRegressionTests: XCTestCase {

    private let lastReadDefaultsKey = "fs_last_read_timestamps"
    private var savedLastReadData: Data?

    override func setUp() {
        super.setUp()
        // Isolate this suite from any real on-disk state (and from other
        // suites in the same run) — save whatever's really there and start
        // every test from a clean slate, mirroring
        // RestoreSessionPhotoBackfillTests' save/restore convention for the
        // sibling fs_user_id/fs_username/fs_email keys.
        savedLastReadData = UserDefaults.standard.data(forKey: lastReadDefaultsKey)
        UserDefaults.standard.removeObject(forKey: lastReadDefaultsKey)
    }

    override func tearDown() {
        if let savedLastReadData {
            UserDefaults.standard.set(savedLastReadData, forKey: lastReadDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastReadDefaultsKey)
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeAppState() -> AppState {
        AppState(service: MockDataService.shared)
    }

    private func friend(id: String = "friend-1", lastMessageAt: String, lastMessageSenderId: String? = nil) -> FSContact {
        FSContact(id: id, name: "Alice", type: .friend, lastMessageAt: lastMessageAt,
                  lastMessageSenderId: lastMessageSenderId)
    }

    private func group(id: String = "group-1", lastMessageAt: String, lastMessageSenderId: String? = nil) -> FSContact {
        FSContact(id: id, name: "Bible Study", type: .group, lastMessageAt: lastMessageAt,
                  lastMessageSenderId: lastMessageSenderId)
    }

    // MARK: - hasUnread: no fabricated state

    /// Acceptance criterion: "No unread indicator is ever shown for a
    /// conversation that has no genuinely new message" — a contact with no
    /// message yet (empty lastMessageAt, the FSContact default) must never
    /// read as unread just because it's never been opened.
    func test_hasUnread_false_whenContactHasNoMessageYet() {
        let appState = makeAppState()
        let contact = friend(lastMessageAt: "")

        XCTAssertFalse(appState.hasUnread(contact),
                        "a conversation with no message yet must never show a fabricated unread badge")
    }

    /// A conversation with a real message that has never been opened (no
    /// last-read marker stored) must read as unread — this is the "first
    /// time" case every friend/group starts in once it has any activity.
    func test_hasUnread_true_forNeverOpenedConversation_withARealMessage() {
        let appState = makeAppState()
        let contact = friend(lastMessageAt: "2026-09-13T10:00:00Z")

        XCTAssertTrue(appState.hasUnread(contact))
    }

    /// A malformed/unparseable lastMessageAt must not be treated as "newer
    /// than anything" — same anti-fabrication posture as the empty-string
    /// case above, exercising hasUnread's own `guard let latest =
    /// parseFlexibleISO8601(...) else { return false }` path specifically.
    func test_hasUnread_false_whenLastMessageAtIsUnparseable() {
        let appState = makeAppState()
        let contact = friend(lastMessageAt: "not-a-real-timestamp")

        XCTAssertFalse(appState.hasUnread(contact))
    }

    // MARK: - markRead clears exactly that conversation

    func test_markRead_clearsUnread_forThatContact() {
        let appState = makeAppState()
        let contact = friend(lastMessageAt: "2026-09-13T10:00:00Z")
        XCTAssertTrue(appState.hasUnread(contact))

        appState.markRead(contact)

        XCTAssertFalse(appState.hasUnread(contact),
                        "opening the thread (markRead) must clear that conversation's unread state immediately")
    }

    /// markRead(_:) is keyed by FSContact.id and applies identically to a
    /// `.group` contact — the intake spec's "one generic mechanism ...
    /// rather than a narrow single-case hack that would need duplicating
    /// for groups" requirement.
    func test_markRead_clearsUnread_forAGroupContact_sameMechanismAsFriend() {
        let appState = makeAppState()
        let aGroup = group(lastMessageAt: "2026-09-13T10:00:00Z")
        XCTAssertTrue(appState.hasUnread(aGroup))

        appState.markRead(aGroup)

        XCTAssertFalse(appState.hasUnread(aGroup))
    }

    /// markRead(_:) on one contact must not clear (or otherwise touch)
    /// another conversation's unread state — proves the marker is truly
    /// per-conversation, not a single shared flag.
    func test_markRead_doesNotClearUnreadState_forADifferentContact() {
        let appState = makeAppState()
        let a = friend(id: "friend-a", lastMessageAt: "2026-09-13T10:00:00Z")
        let b = friend(id: "friend-b", lastMessageAt: "2026-09-13T10:00:00Z")

        appState.markRead(a)

        XCTAssertFalse(appState.hasUnread(a))
        XCTAssertTrue(appState.hasUnread(b),
                       "marking one conversation read must not affect a different conversation's unread state")
    }

    /// Guard clause: markRead(_:) on a contact with no message yet must be a
    /// no-op (it has nothing real to record as "read as of"), and must not
    /// spuriously bump lastReadVersion either — no state changed, so no
    /// change-notification should fire.
    func test_markRead_isNoOp_forAContactWithNoMessageYet() {
        let appState = makeAppState()
        let contact = friend(lastMessageAt: "")
        let versionBefore = appState.lastReadVersion

        appState.markRead(contact)

        XCTAssertEqual(appState.lastReadVersion, versionBefore,
                        "markRead on a contact with no message yet must not record a marker or bump lastReadVersion")
        XCTAssertFalse(appState.hasUnread(contact))
    }

    // MARK: - A genuinely new message after markRead must show unread again

    /// This is the core "what counts as seen?" correctness case: markRead
    /// records the conversation's OWN latest-known-message timestamp (not
    /// device "now"), so a subsequent, strictly newer message must read as
    /// unread again — proving markRead doesn't just set a blanket "read
    /// until further notice" flag that a race with a live delivery could
    /// silently swallow.
    func test_hasUnread_trueAgain_afterANewerMessageArrives_pastTheMarkReadPoint() {
        let appState = makeAppState()
        let atOpen = friend(lastMessageAt: "2026-09-13T10:00:00Z")
        appState.markRead(atOpen)
        XCTAssertFalse(appState.hasUnread(atOpen))

        let afterNewMessage = friend(lastMessageAt: "2026-09-13T10:05:00Z")
        XCTAssertTrue(appState.hasUnread(afterNewMessage),
                       "a message strictly newer than the last-read marker must read as unread again")
    }

    /// The mirror of the above: a message at exactly the same timestamp the
    /// thread was last read at (e.g. a duplicate/replayed contacts fetch)
    /// must NOT read as unread — `>` not `>=`, so re-fetching the exact same
    /// state the user already saw never re-shows a badge.
    func test_hasUnread_staysFalse_whenLastMessageAtHasNotAdvancedPastMarkRead() {
        let appState = makeAppState()
        let contact = friend(lastMessageAt: "2026-09-13T10:00:00Z")
        appState.markRead(contact)

        let sameSnapshotAgain = friend(lastMessageAt: "2026-09-13T10:00:00Z")
        XCTAssertFalse(appState.hasUnread(sameSnapshotAgain))
    }

    // MARK: - Aggregate tab-bar count: one generic mechanism, friends + groups together

    /// The tab-bar badge (unreadConversationCount) must be a pure recompute
    /// over whatever combined friend+group contacts it's handed — covers
    /// the "count of unread conversations" design decision and proves one
    /// code path handles both contact types without a special case.
    func test_recomputeUnreadConversationCount_countsUnreadAcrossFriendsAndGroupsTogether() {
        let appState = makeAppState()
        let readFriend    = friend(id: "f-read",   lastMessageAt: "2026-09-13T09:00:00Z")
        let unreadFriend  = friend(id: "f-unread", lastMessageAt: "2026-09-13T09:00:00Z")
        let unreadGroup   = group(id: "g-unread",  lastMessageAt: "2026-09-13T09:00:00Z")
        let noMessageYet  = friend(id: "f-empty",  lastMessageAt: "")

        appState.markRead(readFriend)

        appState.recomputeUnreadConversationCount(contacts: [readFriend, unreadFriend, unreadGroup, noMessageYet])

        XCTAssertEqual(appState.unreadConversationCount, 2,
                        "aggregate count must include both the unread friend and the unread group, and exclude the read friend and the never-messaged one")
    }

    /// unreadConversationCount must be wholesale-recomputed, not hand-
    /// incremented/decremented — calling recompute a second time with an
    /// updated snapshot (one more conversation now read) must land on the
    /// new true count, not drift from the old one.
    func test_recomputeUnreadConversationCount_reflectsLatestSnapshot_notAccumulatedDelta() {
        let appState = makeAppState()
        let a = friend(id: "f-a", lastMessageAt: "2026-09-13T09:00:00Z")
        let b = friend(id: "f-b", lastMessageAt: "2026-09-13T09:00:00Z")

        appState.recomputeUnreadConversationCount(contacts: [a, b])
        XCTAssertEqual(appState.unreadConversationCount, 2)

        appState.markRead(a)
        appState.recomputeUnreadConversationCount(contacts: [a, b])
        XCTAssertEqual(appState.unreadConversationCount, 1)

        appState.markRead(b)
        appState.recomputeUnreadConversationCount(contacts: [a, b])
        XCTAssertEqual(appState.unreadConversationCount, 0)
    }

    // MARK: - lastReadVersion: change notification for ChatRootView's own recompute wiring

    /// ChatRootView observes `appState.lastReadVersion` via `.onChange` to
    /// know when to call recomputeUnread() again — a markRead(_:) call that
    /// actually recorded something must bump it exactly once.
    func test_markRead_bumpsLastReadVersion_exactlyOnce_whenItRecordsAMarker() {
        let appState = makeAppState()
        let contact = friend(lastMessageAt: "2026-09-13T10:00:00Z")
        let versionBefore = appState.lastReadVersion

        appState.markRead(contact)

        XCTAssertEqual(appState.lastReadVersion, versionBefore + 1)
    }

    // MARK: - Client-local persistence across a relaunch (UserDefaults-backed)

    /// The intake spec's explicit scope: last-read state is client-local,
    /// persisted (not merely in-memory), so it survives an app relaunch on
    /// the same device. Simulated here the same way
    /// RestoreSessionPhotoBackfillTests simulates a relaunch — instantiate
    /// a brand-new AppState against the same real UserDefaults.standard.
    func test_unreadState_persistsAcrossAppStateInstances_viaUserDefaults() {
        let firstLaunch = makeAppState()
        let contact = friend(id: "friend-persist", lastMessageAt: "2026-09-13T10:00:00Z")
        firstLaunch.markRead(contact)
        XCTAssertFalse(firstLaunch.hasUnread(contact))

        let secondLaunch = makeAppState()
        XCTAssertFalse(secondLaunch.hasUnread(contact),
                        "a last-read marker recorded in a prior session must survive into a new AppState instance backed by the same UserDefaults, i.e. a relaunch")
    }

    // MARK: - Task 20260920-chat-self-sent-unread-badge: self-authored latest message never badges

    /// Core regression case: the exact "send a message, then leave the
    /// thread" bug report. Even though the marker was set BEFORE the send
    /// (so the raw timestamp comparison alone would say "unread," exactly
    /// like the real bug), a latest message authored by the current user
    /// must never badge, regardless of marker staleness.
    func test_hasUnread_false_whenLatestMessageSenderIsCurrentUser_evenWithStaleMarker() {
        let appState = makeAppState()
        appState.currentUser = FSUser(user_id: "user-1", username: "me", email: "me@example.com")

        let atOpen = friend(lastMessageAt: "2026-09-20T10:00:00Z")
        appState.markRead(atOpen)

        // Simulates leaving the thread right after sending: lastMessageAt
        // advanced past the marker (the real bug's trigger), but the sender
        // of that newest message is the current user themself.
        let afterOwnSend = friend(lastMessageAt: "2026-09-20T10:05:00Z", lastMessageSenderId: "user-1")

        XCTAssertFalse(appState.hasUnread(afterOwnSend),
                        "a conversation whose latest message was sent by the current user must never badge, even with a stale last-read marker")
    }

    /// Same self-authored suppression, but for a `.group` contact — proves
    /// this isn't a friend-only special case (mirrors the existing
    /// markRead friend/group parity test above).
    func test_hasUnread_false_whenLatestGroupMessageSenderIsCurrentUser() {
        let appState = makeAppState()
        appState.currentUser = FSUser(user_id: "user-1", username: "me", email: "me@example.com")

        let afterOwnSend = group(lastMessageAt: "2026-09-20T10:05:00Z", lastMessageSenderId: "user-1")

        XCTAssertFalse(appState.hasUnread(afterOwnSend))
    }

    /// The other half of the acceptance criteria: a genuine subsequent
    /// message from someone ELSE, arriving after the user's own sent
    /// message, must still correctly badge as unread — the self-authored
    /// suppression must not become a blanket "this conversation is
    /// permanently quiet" flag.
    func test_hasUnread_trueAgain_whenAnotherUserSendsAfterTheCurrentUsersOwnMessage() {
        let appState = makeAppState()
        appState.currentUser = FSUser(user_id: "user-1", username: "me", email: "me@example.com")

        let afterOwnSend = friend(lastMessageAt: "2026-09-20T10:05:00Z", lastMessageSenderId: "user-1")
        XCTAssertFalse(appState.hasUnread(afterOwnSend))

        let afterReply = friend(lastMessageAt: "2026-09-20T10:06:00Z", lastMessageSenderId: "friend-1")
        XCTAssertTrue(appState.hasUnread(afterReply),
                       "a genuinely newer message from another participant must still badge, even right after the user's own message was correctly suppressed")
    }

    /// Q27 (propagate missing data, don't fabricate): a contact whose
    /// sender is unknown (nil -- a cached contact predating this field, or a
    /// fetch that couldn't resolve a last message) must fall back to the
    /// existing timestamp-only behavior rather than being assumed "mine" or
    /// "not mine."
    func test_hasUnread_fallsBackToTimestampOnly_whenSenderIsUnknown() {
        let appState = makeAppState()
        appState.currentUser = FSUser(user_id: "user-1", username: "me", email: "me@example.com")

        let atOpen = friend(lastMessageAt: "2026-09-20T10:00:00Z", lastMessageSenderId: "friend-1")
        appState.markRead(atOpen)

        let unknownSenderNewer = friend(lastMessageAt: "2026-09-20T10:05:00Z", lastMessageSenderId: nil)
        XCTAssertTrue(appState.hasUnread(unknownSenderNewer),
                      "an unknown sender must fall back to the existing timestamp-vs-marker comparison, not be assumed self-authored")
    }

    /// A conversation that has ONLY EVER had messages from the current user
    /// (e.g. a group they created and messaged first, never yet replied to)
    /// must never be eligible to badge, even though it has never been
    /// opened/marked-read at all -- this must fall out of the sender check
    /// naturally, with no separate "never opened" special case.
    func test_hasUnread_false_forConversationWithOnlyEverTheCurrentUsersOwnMessages_neverOpened() {
        let appState = makeAppState()
        appState.currentUser = FSUser(user_id: "user-1", username: "me", email: "me@example.com")

        let neverOpenedSelfOnly = friend(id: "friend-self-only", lastMessageAt: "2026-09-20T10:00:00Z",
                                          lastMessageSenderId: "user-1")

        XCTAssertFalse(appState.hasUnread(neverOpenedSelfOnly),
                        "a conversation whose only-ever message is the current user's own must never badge, even with no last-read marker at all")
    }

    /// The aggregate tab-bar count must reflect the corrected per-contact
    /// state -- a self-authored latest message must not be counted, even
    /// when it sits alongside other genuinely-unread conversations.
    func test_recomputeUnreadConversationCount_excludesConversationsWhoseLatestMessageIsTheUsersOwn() {
        let appState = makeAppState()
        appState.currentUser = FSUser(user_id: "user-1", username: "me", email: "me@example.com")

        let selfSent    = friend(id: "f-self-sent", lastMessageAt: "2026-09-20T10:00:00Z", lastMessageSenderId: "user-1")
        let genuineUnread = friend(id: "f-genuine", lastMessageAt: "2026-09-20T10:00:00Z", lastMessageSenderId: "friend-2")

        appState.recomputeUnreadConversationCount(contacts: [selfSent, genuineUnread])

        XCTAssertEqual(appState.unreadConversationCount, 1,
                        "the aggregate count must exclude the conversation whose latest message is the current user's own, while still counting the genuinely unread one")
    }

    // MARK: - Sign-out wipes this device's read/unread state

    /// signOut() must wipe stored last-read markers (and reset the derived
    /// aggregate) so a second account signing in on this same device never
    /// inherits the first account's read state for a colliding conversation
    /// id (e.g. the same group id, or a mutual friend's user id).
    func test_signOut_wipesLastReadMarkers_soANewAccountDoesNotInheritReadState() {
        let appState = makeAppState()
        appState.currentUser = FSUser(user_id: "user-1", username: "alice", email: "alice@example.com")
        appState.isAuthenticated = true
        let contact = friend(id: "shared-conversation-id", lastMessageAt: "2026-09-13T10:00:00Z")
        appState.markRead(contact)
        XCTAssertFalse(appState.hasUnread(contact))

        appState.signOut()

        XCTAssertEqual(appState.unreadConversationCount, 0)

        // A different (or the same) account signing back in on this device
        // must see the conversation as unread again, not silently
        // "pre-read" from the previous session's marker.
        let secondSession = makeAppState()
        XCTAssertTrue(secondSession.hasUnread(contact),
                       "signOut() must wipe this device's last-read markers so a new sign-in never inherits a previous account's read state for a colliding conversation id")
    }
}
