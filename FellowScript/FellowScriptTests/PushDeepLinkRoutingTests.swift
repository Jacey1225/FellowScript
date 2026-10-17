// PushDeepLinkRoutingTests.swift -- testing gate for task
// 20261016-push-notifications-and-ui (iOS). Tap routing for the always-on
// social pushes: friend_request (incl. cold-start flag), join_request,
// member_joined. Malformed payloads must stay inert.

import XCTest
@testable import FellowScript

@MainActor
final class PushDeepLinkRoutingTests: XCTestCase {

    private func makeAppState(userId: String = "me") -> AppState {
        let a = AppState(service: MockDataService.shared)
        a.currentUser = FSUser(user_id: userId, username: "me", email: "me@example.com")
        a.isAuthenticated = true
        return a
    }

    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: target parsing

    func test_target_joinRequest_and_memberJoined_parse() {
        let j = GroupMembershipPushTarget(userInfo: ["action": "join_request", "group_id": "g1"])
        XCTAssertEqual(j?.kind, .joinRequest)
        XCTAssertEqual(j?.groupId, "g1")
        let m = GroupMembershipPushTarget(userInfo: ["action": "member_joined", "group_id": "g2"])
        XCTAssertEqual(m?.kind, .memberJoined)
        XCTAssertEqual(m?.groupId, "g2")
    }

    func test_target_malformed_isNil() {
        XCTAssertNil(GroupMembershipPushTarget(userInfo: [:]))
        XCTAssertNil(GroupMembershipPushTarget(userInfo: ["action": "join_request"]))
        XCTAssertNil(GroupMembershipPushTarget(userInfo: ["action": "join_request", "group_id": ""]))
        XCTAssertNil(GroupMembershipPushTarget(userInfo: ["action": "join_request", "group_id": 5]))
        XCTAssertNil(GroupMembershipPushTarget(userInfo: ["action": "other", "group_id": "g1"]))
        XCTAssertNil(GroupMembershipPushTarget(userInfo: ["action": "member_joined",
                                                          "group_id": String(repeating: "x", count: 129)]))
        XCTAssertNotNil(GroupMembershipPushTarget(userInfo: ["action": "member_joined",
                                                             "group_id": String(repeating: "x", count: 128)]))
    }

    // MARK: SocialPushRouting.route

    func test_route_friendRequest_postsNotification_noGroupIdNeeded() {
        let exp = expectation(forNotification: .friendRequestPushTapped, object: nil)
        XCTAssertTrue(SocialPushRouting.route(userInfo: ["action": "friend_request"]))
        wait(for: [exp], timeout: 1)
    }

    func test_route_joinRequest_postsTargetOnMembershipChannel() {
        var got: GroupMembershipPushTarget?
        let exp = expectation(forNotification: .groupMembershipPushTapped, object: nil) { n in
            got = n.object as? GroupMembershipPushTarget; return true
        }
        XCTAssertTrue(SocialPushRouting.route(userInfo: ["action": "join_request", "group_id": "g9"]))
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(got, GroupMembershipPushTarget(userInfo: ["action": "join_request", "group_id": "g9"]))
    }

    func test_route_memberJoined_postsTarget() {
        var got: GroupMembershipPushTarget?
        let exp = expectation(forNotification: .groupMembershipPushTapped, object: nil) { n in
            got = n.object as? GroupMembershipPushTarget; return true
        }
        XCTAssertTrue(SocialPushRouting.route(userInfo: ["action": "member_joined", "group_id": "g3"]))
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(got?.kind, .memberJoined)
    }

    func test_route_unhandledOrMalformed_returnsFalseAndPostsNothing() {
        let a = expectation(forNotification: .friendRequestPushTapped, object: nil); a.isInverted = true
        let b = expectation(forNotification: .groupMembershipPushTapped, object: nil); b.isInverted = true
        XCTAssertFalse(SocialPushRouting.route(userInfo: [:]))
        XCTAssertFalse(SocialPushRouting.route(userInfo: ["action": "message", "group_id": "g"]))
        XCTAssertFalse(SocialPushRouting.route(userInfo: ["action": "join_request"]))
        XCTAssertFalse(SocialPushRouting.route(userInfo: ["action": "member_joined", "group_id": ""]))
        wait(for: [a, b], timeout: 0.3)
    }

    // MARK: AppState handling

    func test_handle_joinRequest_opensChatAndRequestsGroupInfo() {
        let app = makeAppState()
        app.handleGroupMembershipPush(GroupMembershipPushTarget(userInfo: ["action": "join_request", "group_id": "g1"])!)
        XCTAssertEqual(app.pendingChatContact?.id, "g1")
        XCTAssertEqual(app.pendingChatContact?.type, .group)
        XCTAssertEqual(app.pendingGroupInfoOpen, "g1")
    }

    func test_handle_memberJoined_opensChatOnly() {
        let app = makeAppState()
        app.handleGroupMembershipPush(GroupMembershipPushTarget(userInfo: ["action": "member_joined", "group_id": "g2"])!)
        XCTAssertEqual(app.pendingChatContact?.id, "g2")
        XCTAssertNil(app.pendingGroupInfoOpen, "member_joined must not open the group info sheet")
    }

    func test_handle_signedOut_stillNoChatContact() {
        let app = AppState(service: MockDataService.shared)
        app.currentUser = nil   // init may restore a persisted session
        app.handleGroupMembershipPush(GroupMembershipPushTarget(userInfo: ["action": "member_joined", "group_id": "g2"])!)
        XCTAssertNil(app.pendingChatContact)
    }

    // MARK: friend-request flag (cold start) wiring, source-pinned

    func test_friendRequestFlag_defaultsFalse() {
        XCTAssertFalse(makeAppState().pendingFriendRequestsOpen)
    }

    func test_coldStart_contentViewChecksFlagOnAppearAndOnChange() throws {
        let cv = try source("FellowScript/ContentView.swift")
        XCTAssertTrue(cv.contains(".onChange(of: appState.pendingFriendRequestsOpen)"))
        XCTAssertTrue(cv.contains(".onAppear { if appState.pendingFriendRequestsOpen { selectedTab = .account } }"),
                      "cold start: flag set before ContentView exists must still switch to Account")
    }

    func test_accountView_consumesFlagOnAppearAndClearsIt() throws {
        let av = try source("FellowScript/Account/AccountView.swift")
        XCTAssertTrue(av.contains("consumePendingFriendRequestsOpen(scrollProxy)"))
        XCTAssertTrue(av.contains(".id(\"friendRequestsSection\")"))
        let misc = try source("FellowScript/Account/AccountView+Misc.swift")
        XCTAssertTrue(misc.contains("appState.pendingFriendRequestsOpen = false"))
    }

    func test_appDelegate_routesSocialPushesAndAppSetsFlag() throws {
        let app = try source("FellowScript/FellowScriptApp.swift")
        XCTAssertTrue(app.contains("SocialPushRouting.route(userInfo: data)"))
        XCTAssertTrue(app.contains("appState.pendingFriendRequestsOpen = true"))
        XCTAssertTrue(app.contains("appState.handleGroupMembershipPush(t)"))
    }
}
