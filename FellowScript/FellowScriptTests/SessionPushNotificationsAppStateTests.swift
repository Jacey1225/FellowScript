// SessionPushNotificationsAppStateTests.swift — testing gate coverage for
// task 20260904-session-push-notifications, step 3 (testing), covering
// frontend step 2's iOS-side tap-navigation logic.
//
// Frontend step 2 added:
//   1. FellowScriptApp.AppDelegate's `didReceive response:` -- the first
//      tap-handler this project has ever had (previously only `willPresent`
//      existed, controlling foreground banner display only). It posts
//      `.sessionPushTapped` with the payload's `group_id`, but ONLY when
//      `devotion_id` is present in the payload -- any other push shape
//      (heartbeat's `heartbeat_id`/`agent_id`, or the plain friend-activity/
//      no-activity pushes with no `data` at all) is left exactly as inert
//      on tap as before.
//   2. `AppState.openSession(groupId:)`, which resolves a push's `group_id`
//      into `pendingChatContact` -- a real group id becomes a `.group`
//      contact; a DM room key (`"uidA|uidB"`, split on `"|"`) becomes a
//      `.friend` contact for the OTHER participant (not the room key
//      itself), reusing the pre-existing cross-tab navigation mechanism
//      (ChatRootView's `onChange(of: appState.pendingChatContact)`).
//
// This file exercises `AppState.openSession(groupId:)` directly -- the real
// seam carrying this task's actual new logic (AppDelegate's own body is a
// thin one-line `if data["devotion_id"] != nil` extraction with no branching
// worth a dedicated unit test beyond what test 6 below pins at the source
// level, matching this project's established technique for UIKit delegate
// methods that can't be constructed directly in XCTest -- see
// SubmenuFollowupPolishRegressionTests.swift's `readSource` technique).
//
// Proves:
//   1. A real group id (no "|") resolves to a `.group` FSContact with that
//      id.
//   2. A DM room key resolves to a `.friend` FSContact for the OTHER user,
//      not the current user and not the raw room key itself.
//   3. A DM room key still resolves correctly regardless of which side of
//      the key the current user's id is on (order-independence -- the room
//      key is a sorted pair per `ChatThreadViewModel.roomKey`, but this
//      method must not assume the current user is always first/second).
//   4. No signed-in user (`currentUser == nil`) is a no-op -- does not set
//      `pendingChatContact` (guards a stale/late-arriving push tap after
//      sign-out).
//   5. An empty `groupId` is a no-op -- guards a malformed/missing payload.
//   6. Source-pinning (mirrors SubmenuFollowupPolishRegressionTests'
//      technique): `didReceive response:` only posts `.sessionPushTapped`
//      when `devotion_id` is present, so no other existing push type (e.g.
//      heartbeat's) starts navigating anywhere as an accidental side effect
//      of this task.

import XCTest
@testable import FellowScript

@MainActor
final class SessionPushNotificationsAppStateTests: XCTestCase {

    private func makeSignedInAppState(userId: String = "user-creator") -> AppState {
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: userId, username: "creator", email: "creator@example.com")
        appState.isAuthenticated = true
        return appState
    }

    // MARK: 1 — a real group id resolves to a .group contact

    func test_openSession_realGroupId_resolvesToGroupContact() {
        let appState = makeSignedInAppState()
        appState.openSession(groupId: "group-abc-123")

        XCTAssertEqual(appState.pendingChatContact?.id, "group-abc-123")
        XCTAssertEqual(appState.pendingChatContact?.type, .group,
                       "a group_id with no '|' separator must resolve to a .group contact, not .friend")
    }

    // MARK: 2 — a DM room key resolves to the OTHER participant, as .friend

    func test_openSession_dmRoomKey_resolvesToOtherParticipant_asFriendContact() {
        let appState = makeSignedInAppState(userId: "user-creator")
        appState.openSession(groupId: "user-creator|user-other")

        XCTAssertEqual(appState.pendingChatContact?.id, "user-other",
                       "a DM room key must resolve to the OTHER participant's id, not the room key itself")
        XCTAssertEqual(appState.pendingChatContact?.type, .friend,
                       "a DM room key ('|' present) must resolve to a .friend contact, not .group")
    }

    // MARK: 3 — order-independence: current user can be on either side of the key

    func test_openSession_dmRoomKey_currentUserOnEitherSide_stillResolvesToTheOtherUser() {
        let appStateFirst = makeSignedInAppState(userId: "user-a")
        appStateFirst.openSession(groupId: "user-a|user-b")
        XCTAssertEqual(appStateFirst.pendingChatContact?.id, "user-b")

        let appStateSecond = makeSignedInAppState(userId: "user-b")
        appStateSecond.openSession(groupId: "user-a|user-b")
        XCTAssertEqual(appStateSecond.pendingChatContact?.id, "user-a",
                       "must resolve to the other user regardless of which side of the sorted "
                       + "room key the current user's id falls on")
    }

    // MARK: 4 — no signed-in user is a no-op

    func test_openSession_noCurrentUser_isNoOp() {
        let appState = AppState(service: MockDataService.shared)
        XCTAssertNil(appState.currentUser, "sanity check: no user signed in")

        appState.openSession(groupId: "group-abc-123")

        XCTAssertNil(appState.pendingChatContact,
                     "a push-tap resolving with no signed-in user (e.g. after sign-out) must not "
                     + "set pendingChatContact")
    }

    // MARK: 5 — an empty groupId is a no-op

    func test_openSession_emptyGroupId_isNoOp() {
        let appState = makeSignedInAppState()

        appState.openSession(groupId: "")

        XCTAssertNil(appState.pendingChatContact,
                     "an empty/malformed group_id in the push payload must not set pendingChatContact")
    }

    // MARK: 6 — source-pinning: didReceive response: only fires for devotion_id-bearing payloads

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_appDelegate_didReceiveResponse_onlyPostsSessionPushTapped_whenDevotionIdPresent() throws {
        let source = try readSource("FellowScript/FellowScriptApp.swift")
        guard let methodRange = source.range(of: "func userNotificationCenter(_ center: UNUserNotificationCenter,\n                                didReceive response:") else {
            XCTFail("didReceive response: handler not found")
            return
        }
        let end = source.range(of: "\n}", range: methodRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let body = String(source[methodRange.upperBound..<end])

        XCTAssertTrue(body.contains("data[\"devotion_id\"]"),
                      "the tap handler must gate on the presence of devotion_id -- the marker "
                      + "these two new push types (and only these two) carry")
        XCTAssertTrue(body.contains(".sessionPushTapped"),
                      "must post .sessionPushTapped, the notification AppState/FellowScriptApp wire up")
        XCTAssertTrue(body.contains("group_id"),
                      "must extract group_id from the payload to hand to AppState.openSession")
        // Out-of-scope guard: this task must not have generalized tap
        // handling to heartbeat's own payload shape (heartbeat_id/agent_id)
        // -- that push type stays exactly as inert on tap as before.
        XCTAssertFalse(body.contains("heartbeat_id"),
                       "must not also start dispatching on heartbeat's payload shape -- out of scope for this task")
    }
}
