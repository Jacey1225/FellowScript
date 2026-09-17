// ChatPushDeepLinkTapTests.swift — testing gate coverage for task
// 20260916-chat-push-deep-link, step 3 (testing), covering frontend step 2's
// new `action == "message"` case in
// FellowScriptApp.AppDelegate.userNotificationCenter(_:didReceive:).
//
// Frontend step 2 added a third branch to the same tap handler
// SessionPushNotificationsAppStateTests.swift already exercises (see that
// file's own header for the session-created/reminder and ring cases):
//
//   Backend now sends `data = {"group_id": <group id or synthesized
//   "uidA|uidB" DM room key>, "action": "message"}` for a plain chat-message
//   push (ConnectionManager.send_msg's offline-recipient branch --
//   api/backend/interactions/websockets.py). AppDelegate's handler, checked
//   AFTER the `action == "ring"` branch and BEFORE the plain `devotion_id`
//   branch, posts `.sessionPushTapped` with that `group_id`/room-key string
//   -- reusing `AppState.openSession(groupId:)` completely unmodified, since
//   it already resolves both a bare group id and a `"uidA|uidB"` DM room key
//   (SessionPushNotificationsAppStateTests.swift's tests 1-3 already pin
//   that resolution logic itself; this file pins the NEW dispatch path that
//   feeds it, not that logic again).
//
// This file uses the same `readSource` source-pinning technique
// SessionPushNotificationsAppStateTests.swift established (test 6) --
// AppDelegate can't be constructed/driven directly in XCTest since a real
// `UNNotificationResponse` can't be built from a test target -- plus one
// live NotificationCenter round-trip proving the object type AppDelegate
// posts is exactly what `openSession(groupId:)` (via FellowScriptApp's own
// `.onReceive(.sessionPushTapped)`) expects, so a payload-shape mismatch
// between the two wouldn't silently no-op.
//
// Proves:
//   1. The `action == "message"` branch exists, extracts `group_id`, and
//      posts `.sessionPushTapped` with it.
//   2. It is checked AFTER `action == "ring"` and BEFORE the plain
//      `devotion_id` branch, so a ring push (which also carries a `group_id`)
//      can never be misrouted into this new branch, and this new branch
//      can't be shadowed by the pre-existing `devotion_id` branch either.
//   3. The pre-existing `action == "ring"` branch (task
//      20260916-call-ring-members) is untouched by this task -- still posts
//      `.ringPushTapped` with both `devotionId` and `groupId`.
//   4. The pre-existing plain `devotion_id` branch (task
//      20260904-session-push-notifications) is untouched -- still posts
//      `.sessionPushTapped` for a session-created/reminder push with no
//      `action` field at all.
//   5. A `.sessionPushTapped` notification carrying a synthesized DM room
//      key as its `object` (exactly the shape AppDelegate posts for the new
//      branch) round-trips through `AppState.openSession(groupId:)` via a
//      live NotificationCenter observer, resolving to the correct `.friend`
//      contact end to end -- not just proving the source text mentions the
//      right calls.
//   6. Any other push shape with neither `action` nor `devotion_id` (e.g.
//      heartbeat's `heartbeat_id`/`agent_id`, or the plain
//      friend-activity/no-activity pushes with no `data` at all) still has
//      no matching branch -- continues to be exactly as inert on tap as
//      before this task.

import XCTest
import Combine
@testable import FellowScript

@MainActor
final class ChatPushDeepLinkTapTests: XCTestCase {

    private func makeSignedInAppState(userId: String = "user-creator") -> AppState {
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: userId, username: "creator", email: "creator@example.com")
        appState.isAuthenticated = true
        return appState
    }

    // MARK: - Source-pinning: AppDelegate.userNotificationCenter(_:didReceive:)

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func didReceiveBody() throws -> String {
        let source = try readSource("FellowScript/FellowScriptApp.swift")
        guard let methodRange = source.range(of: "func userNotificationCenter(_ center: UNUserNotificationCenter,\n                                didReceive response:") else {
            XCTFail("didReceive response: handler not found")
            return ""
        }
        let end = source.range(of: "\n}", range: methodRange.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        return String(source[methodRange.upperBound..<end])
    }

    // MARK: 1 — the new action == "message" branch exists and does the right thing

    func test_appDelegate_didReceiveResponse_messageAction_postsSessionPushTappedWithGroupId() throws {
        let body = try didReceiveBody()

        XCTAssertTrue(body.contains("action == \"message\""),
                      "must add an explicit action == \"message\" discriminator branch, per "
                      + "architecture's explicit-discriminator decision (Q26/Q27) -- not an implicit "
                      + "fallback on the mere absence of devotion_id")

        // Isolate the action == "message" branch's own body so assertions 1/2
        // below can't accidentally pass by matching text from a sibling branch.
        guard let messageBranchRange = body.range(of: "action == \"message\"") else {
            XCTFail("action == \"message\" branch not found")
            return
        }
        let afterMessageBranch = String(body[messageBranchRange.upperBound...])
        let messageBranchEnd = afterMessageBranch.range(of: "} else if data[\"devotion_id\"]")?.lowerBound
            ?? afterMessageBranch.endIndex
        let messageBranchBody = String(afterMessageBranch[..<messageBranchEnd])

        XCTAssertTrue(messageBranchBody.contains(".sessionPushTapped"),
                      "a chat-message push tap must post .sessionPushTapped, reusing the same "
                      + "notification/openSession(groupId:) path the session-created/reminder push already uses")
        XCTAssertTrue(messageBranchBody.contains("groupId"),
                      "must pass the payload's resolved group_id (or synthesized DM room key) as the object")
        XCTAssertFalse(messageBranchBody.contains("ringPushTapped"),
                       "must NOT post .ringPushTapped -- that's the action == \"ring\" branch's job, not this one's")
    }

    // MARK: 2 — branch ordering: ring first, then message, then plain devotion_id

    func test_appDelegate_didReceiveResponse_branchOrdering_ringThenMessageThenDevotionId() throws {
        let body = try didReceiveBody()

        guard let ringRange = body.range(of: "action == \"ring\"") else {
            XCTFail("action == \"ring\" branch not found"); return
        }
        guard let messageRange = body.range(of: "action == \"message\"") else {
            XCTFail("action == \"message\" branch not found"); return
        }
        guard let devotionRange = body.range(of: "data[\"devotion_id\"] != nil") else {
            XCTFail("plain devotion_id branch not found"); return
        }

        XCTAssertTrue(ringRange.lowerBound < messageRange.lowerBound,
                      "action == \"ring\" (most specific) must still be checked before "
                      + "action == \"message\" -- a ring push also carries group_id and must not be "
                      + "misrouted into the new plain-message branch")
        XCTAssertTrue(messageRange.lowerBound < devotionRange.lowerBound,
                      "action == \"message\" must be checked before the plain devotion_id branch, per "
                      + "architecture's decision, so it can't be shadowed by (or shadow) that branch")
    }

    // MARK: 3 — pre-existing ring branch is untouched

    func test_appDelegate_didReceiveResponse_ringAction_stillPostsRingPushTappedWithBothFields() throws {
        let body = try didReceiveBody()

        guard let ringRange = body.range(of: "action == \"ring\"") else {
            XCTFail("action == \"ring\" branch not found"); return
        }
        let afterRing = String(body[ringRange.upperBound...])
        let ringBranchEnd = afterRing.range(of: "} else if action == \"message\"")?.lowerBound ?? afterRing.endIndex
        let ringBranchBody = String(afterRing[..<ringBranchEnd])

        XCTAssertTrue(ringBranchBody.contains(".ringPushTapped"),
                      "ring push tap must still post .ringPushTapped, unregressed by this task")
        XCTAssertTrue(ringBranchBody.contains("devotionId") && ringBranchBody.contains("groupId"),
                      "ring push tap must still resolve RingPushTarget with both devotionId and groupId")
    }

    // MARK: 4 — pre-existing plain devotion_id (session-created/reminder) branch is untouched

    func test_appDelegate_didReceiveResponse_plainDevotionId_stillPostsSessionPushTapped() throws {
        let body = try didReceiveBody()

        XCTAssertTrue(body.contains("data[\"devotion_id\"] != nil"),
                      "the pre-existing session-created/reminder branch must still gate on devotion_id presence")

        guard let devotionRange = body.range(of: "data[\"devotion_id\"] != nil") else {
            XCTFail("plain devotion_id branch not found"); return
        }
        let devotionBranchBody = String(body[devotionRange.upperBound...])
        XCTAssertTrue(devotionBranchBody.contains(".sessionPushTapped"),
                      "session-created/reminder push tap must still post .sessionPushTapped")
    }

    // MARK: 5 — end-to-end: the notification shape AppDelegate posts for a DM room key
    //           round-trips through AppState.openSession(groupId:) via a live observer,
    //           exactly mirroring FellowScriptApp's own .onReceive(.sessionPushTapped)

    func test_sessionPushTapped_withSynthesizedDmRoomKey_resolvesThroughOpenSession_endToEnd() {
        let appState = makeSignedInAppState(userId: "user-creator")
        var cancellables = Set<AnyCancellable>()

        NotificationCenter.default.publisher(for: .sessionPushTapped)
            .sink { note in
                if let groupId = note.object as? String {
                    appState.openSession(groupId: groupId)
                }
            }
            .store(in: &cancellables)

        // Exactly the payload shape the new action == "message" branch posts
        // for a DM: the backend-synthesized sorted "uidA|uidB" room key.
        NotificationCenter.default.post(name: .sessionPushTapped, object: "user-creator|user-other")

        XCTAssertEqual(appState.pendingChatContact?.id, "user-other",
                       "the DM room key carried by .sessionPushTapped must resolve to the OTHER "
                       + "participant, exactly as it would for the pre-existing session-push branch")
        XCTAssertEqual(appState.pendingChatContact?.type, .friend)
    }

    func test_sessionPushTapped_withGroupId_resolvesThroughOpenSession_endToEnd() {
        let appState = makeSignedInAppState()
        var cancellables = Set<AnyCancellable>()

        NotificationCenter.default.publisher(for: .sessionPushTapped)
            .sink { note in
                if let groupId = note.object as? String {
                    appState.openSession(groupId: groupId)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .sessionPushTapped, object: "group-deep-link-456")

        XCTAssertEqual(appState.pendingChatContact?.id, "group-deep-link-456")
        XCTAssertEqual(appState.pendingChatContact?.type, .group)
    }

    // MARK: 6 — out-of-scope guard: still no dispatch on heartbeat's own payload shape

    func test_appDelegate_didReceiveResponse_stillDoesNotDispatchOnHeartbeatShape() throws {
        let body = try didReceiveBody()

        XCTAssertFalse(body.contains("heartbeat_id"),
                       "must not have generalized tap handling to heartbeat's payload shape -- "
                       + "out of scope for this task, same guard SessionPushNotificationsAppStateTests "
                       + "already pinned for the prior task")
    }
}
