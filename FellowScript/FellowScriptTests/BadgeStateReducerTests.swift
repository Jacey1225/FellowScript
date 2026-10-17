// BadgeStateReducerTests.swift -- testing gate for task
// 20261016-ipad-parity-and-persistent-badges.
//
// Pure-reducer coverage of BadgeState: "displayed badge = exists AND unseen".
//   * friend requests: seen clears while still pending, a NEW requester re-raises,
//     resolved requesters drop out of both sets, a snapshot can never resurrect a
//     seen item, an empty (proven) snapshot clears;
//   * join requests: unseen until the owner opens the list, newer
//     newest_request_at re-badges, same/older does not, older server (no
//     timestamp) stays seen once seen, group dropping out prunes the watermark;
//   * Codable round trip and the pending-summary wire decode.

import XCTest
@testable import FellowScript

final class BadgeStateReducerTests: XCTestCase {

    private func row(_ g: String, _ n: Int, _ newest: String?) -> FSJoinRequestSummaryRow {
        FSJoinRequestSummaryRow(groupId: g, pendingCount: n, newestRequestAt: newest)
    }

    private let t1 = "2026-10-16T22:41:07.123456Z"
    private let t2 = "2026-10-16T22:41:07.123457Z"   // one microsecond later
    private let t3 = "2026-10-17T01:00:00.000000Z"

    // MARK: Friend requests

    func test_friend_snapshotIsUnseenUntilViewed() {
        var s = BadgeState()
        s.applyFriendSnapshot(["a", "b"])
        XCTAssertEqual(s.unseenFriendRequestCount, 2)
    }

    func test_friend_seenClearsBadge_whileRequestsStillPending() {
        var s = BadgeState()
        s.applyFriendSnapshot(["a", "b"])
        s.markFriendRequestsSeen(["a", "b"])
        XCTAssertEqual(s.unseenFriendRequestCount, 0)
        XCTAssertEqual(s.friendPending, ["a", "b"], "still pending server-side; only the display clears")
    }

    func test_friend_refreshAfterSeen_doesNotResurrectSeenItems() {
        var s = BadgeState()
        s.markFriendRequestsSeen(["a", "b"])
        s.applyFriendSnapshot(["a", "b"])     // foreground refresh, same pending set
        XCTAssertEqual(s.unseenFriendRequestCount, 0)
    }

    func test_friend_newRequesterAfterSeen_reRaisesOnlyForTheNewOne() {
        var s = BadgeState()
        s.markFriendRequestsSeen(["a"])
        s.applyFriendSnapshot(["a", "c"])
        XCTAssertEqual(s.unseenFriendRequestCount, 1)
        s.markFriendRequestsSeen(["a", "c"])
        XCTAssertEqual(s.unseenFriendRequestCount, 0)
    }

    func test_friend_resolvedAndNewNetEqualCount_stillRaisesBadge() {
        // The case a count watermark would miss: approve one, receive one.
        var s = BadgeState()
        s.markFriendRequestsSeen(["a", "b"])
        s.applyFriendSnapshot(["b", "x"])
        XCTAssertEqual(s.unseenFriendRequestCount, 1)
        XCTAssertEqual(s.friendSeen, ["b"], "resolved id 'a' is pruned from the seen set")
    }

    func test_friend_resolvedRequesterWhoReturns_isUnseenAgain() {
        var s = BadgeState()
        s.markFriendRequestsSeen(["a"])
        s.applyFriendSnapshot([])             // declined/withdrawn
        s.applyFriendSnapshot(["a"])          // sends a fresh request later
        XCTAssertEqual(s.unseenFriendRequestCount, 1)
    }

    func test_friend_emptyProvenSnapshot_clears() {
        var s = BadgeState()
        s.applyFriendSnapshot(["a", "b"])
        s.applyFriendSnapshot([])
        XCTAssertEqual(s.unseenFriendRequestCount, 0)
        XCTAssertTrue(s.friendPending.isEmpty)
        XCTAssertTrue(s.friendSeen.isEmpty)
    }

    func test_friend_viewedListIsItselfAProvenSnapshot_prunesStaleIds() {
        var s = BadgeState()
        s.applyFriendSnapshot(["a", "b", "c"])
        s.markFriendRequestsSeen(["b"])       // list on screen now has only b
        XCTAssertEqual(s.friendPending, ["b"])
        XCTAssertEqual(s.unseenFriendRequestCount, 0)
    }

    // MARK: Join requests

    func test_join_unseenUntilOwnerOpensTheList() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 2, t1)])
        XCTAssertEqual(s.unseenJoinCounts, ["g1": 2])
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 2, newestRequestAt: t1)
        XCTAssertTrue(s.unseenJoinCounts.isEmpty)
    }

    func test_join_refreshWithSameNewest_doesNotReRaiseAfterSeen() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 2, t1)])
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 2, newestRequestAt: t1)
        s.applyJoinSnapshot([row("g1", 2, t1)])
        XCTAssertTrue(s.unseenJoinCounts.isEmpty)
    }

    func test_join_newerRequestAfterSeen_reBadgesWithTheWholePendingCount() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 1, t1)])
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 1, newestRequestAt: t1)
        s.applyJoinSnapshot([row("g1", 2, t2)])
        XCTAssertEqual(s.unseenJoinCounts, ["g1": 2])
    }

    func test_join_microsecondDifferenceIsEnough() {
        var s = BadgeState()
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 1, newestRequestAt: t1)
        s.applyJoinSnapshot([row("g1", 1, t2)])
        XCTAssertEqual(s.unseenJoinCounts, ["g1": 1])
    }

    func test_join_approveOneReceiveOneNetEqualCount_stillRaises() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 2, t1)])
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 2, newestRequestAt: t1)
        s.applyJoinSnapshot([row("g1", 2, t3)])   // one approved, one newer arrived
        XCTAssertEqual(s.unseenJoinCounts, ["g1": 2])
    }

    func test_join_countDropsButNoNewerRequest_staysSeen() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 3, t2)])
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 3, newestRequestAt: t2)
        s.applyJoinSnapshot([row("g1", 1, t1)])   // older ones resolved, newest gone: older ts
        XCTAssertTrue(s.unseenJoinCounts.isEmpty)
    }

    func test_join_olderServerWithoutTimestamp_staysSeenAfterViewing() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 1, nil)])
        XCTAssertEqual(s.unseenJoinCounts, ["g1": 1], "no watermark yet = unseen")
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 1, newestRequestAt: nil)
        s.applyJoinSnapshot([row("g1", 1, nil)])
        XCTAssertTrue(s.unseenJoinCounts.isEmpty, "no timestamp from server: cannot prove anything newer")
    }

    func test_join_groupLeavingSummary_prunesWatermark_andLaterRequestIsUnseen() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 1, t1)])
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 1, newestRequestAt: t1)
        s.applyJoinSnapshot([])                  // all resolved
        XCTAssertNil(s.joinSeen["g1"])
        s.applyJoinSnapshot([row("g1", 1, t1)])  // even an equal timestamp is a fresh unseen group now
        XCTAssertEqual(s.unseenJoinCounts, ["g1": 1])
    }

    func test_join_viewedZeroPending_removesGroup() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 1, t1)])
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 0, newestRequestAt: nil)
        XCTAssertTrue(s.joinSummary.isEmpty)
        XCTAssertTrue(s.unseenJoinCounts.isEmpty)
    }

    func test_join_zeroCountRowsAreNotStored() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 0, t1), row("g2", 2, t2)])
        XCTAssertEqual(Set(s.joinSummary.keys), ["g2"])
    }

    func test_join_seenIsPerGroup() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 1, t1), row("g2", 4, t2)])
        s.markJoinRequestsSeen(groupId: "g1", pendingCount: 1, newestRequestAt: t1)
        XCTAssertEqual(s.unseenJoinCounts, ["g2": 4])
    }

    func test_join_emptyProvenSnapshot_clears() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 1, t1)])
        s.applyJoinSnapshot([])
        XCTAssertTrue(s.unseenJoinCounts.isEmpty)
    }

    func test_join_setJoinCount_afterApprove_keepsNewestMarker_andZeroRemoves() {
        var s = BadgeState()
        s.applyJoinSnapshot([row("g1", 2, t2)])
        s.setJoinCount(groupId: "g1", 1)
        XCTAssertEqual(s.joinSummary["g1"]?.newest, t2)
        s.setJoinCount(groupId: "g1", 0)
        XCTAssertNil(s.joinSummary["g1"])
    }

    // MARK: Codable / wire

    func test_codable_roundTripPreservesEverything() throws {
        var s = BadgeState()
        s.applyFriendSnapshot(["a", "b"]); s.markFriendRequestsSeen(["a", "b"]); s.applyFriendSnapshot(["a", "b", "c"])
        s.applyJoinSnapshot([row("g1", 2, t1)]); s.markJoinRequestsSeen(groupId: "g1", pendingCount: 2, newestRequestAt: t1)
        s.unreadConversations = 4
        let back = try JSONDecoder().decode(BadgeState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.version, BadgeState.currentVersion)
    }

    func test_payloadHoldsNoApplicantData() throws {
        var s = BadgeState()
        s.applyFriendSnapshot(["user-123"])
        s.applyJoinSnapshot([row("g1", 1, t1)])
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8) ?? ""
        for forbidden in ["email", "username", "token", "password", "message"] {
            XCTAssertFalse(json.lowercased().contains(forbidden), "persisted badge payload must not carry \(forbidden)")
        }
    }

    func test_summaryRow_decodesNewestRequestAt_andToleratesItsAbsence() throws {
        let withTs = Data(#"{"group_id":"g1","pending_count":2,"newest_request_at":"2026-10-16T22:41:07.123456Z"}"#.utf8)
        let r1 = try JSONDecoder().decode(FSJoinRequestSummaryRow.self, from: withTs)
        XCTAssertEqual(r1.newestRequestAt, "2026-10-16T22:41:07.123456Z")
        let without = Data(#"{"group_id":"g1","pending_count":2}"#.utf8)
        let r2 = try JSONDecoder().decode(FSJoinRequestSummaryRow.self, from: without)
        XCTAssertNil(r2.newestRequestAt)
        XCTAssertEqual(r2.pendingCount, 2)
    }
}
