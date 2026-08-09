// GroupCreateUpdateErrorHandlingTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, step 8 (backend) finding #1 /
// step 9 (frontend) fix.
//
// NetworkService.createGroup() and updateGroup() previously used the unchecked
// `requestRaw` (no throwIfError), the exact requestRaw-vs-checkedRequestRaw
// silent-failure class as incident #1 (20260808-timezone-not-persisting). A
// rejected create/update — e.g. an expired session (401), or group_router's
// content-filter 422 on a disallowed title via check_clean(title=...) — threw
// nothing, so call sites using bare `try?` (ChatRootView's group-creation
// sheet, ChatThreadView.addMembers()) saw no error and the UI looked like
// nothing happened (or, for addMembers, left an already-applied optimistic
// mutation silently out of sync with the server).
//
// The fix switched both methods to checkedRequestRaw. This proves, against
// the real NetworkService (not MockDataService) via the same stubbed
// URLProtocol harness used by NetworkServiceGetErrorHandlingTests, that:
//   1. A 422 (content-filter rejection) from createGroup/updateGroup now
//      throws instead of silently no-opping.
//   2. A 401 (expired session) from createGroup/updateGroup now throws.
//   3. A 200 happy path still succeeds cleanly (regression guard — the fix
//      must not turn successful creates/updates into false failures).
//
// Run with Xcode/xcodebuild once available in this environment; verified here
// via `swiftc -parse` only (no simulator available — see prior steps 3/4/6/7/9
// for the same noted constraint).

import XCTest
@testable import FellowScript

final class GroupCreateUpdateErrorHandlingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    // ── createGroup ──────────────────────────────────────────────────────

    func test_createGroup_throws_on422ContentFilterRejection() async {
        StubURLProtocol.stubStatusCode = 422
        StubURLProtocol.stubBody =
            #"{"detail": "Group title contains language that isn't allowed."}"#
            .data(using: .utf8)!

        do {
            try await NetworkService.shared.createGroup(
                userId: "user-123", groupId: "group-456",
                title: "disallowed title", users: ["user-123", "user-789"]
            )
            XCTFail("createGroup() must throw on a 422 content-filter rejection, not silently no-op")
        } catch {
            // expected — any thrown error is correct; the important behavior
            // is that it throws at all, matching incident #1's fix pattern.
        }
    }

    func test_createGroup_throws_on401ExpiredSession() async {
        StubURLProtocol.stubStatusCode = 401
        StubURLProtocol.stubBody = #"{"detail": "Not authenticated"}"#.data(using: .utf8)!

        do {
            try await NetworkService.shared.createGroup(
                userId: "user-123", groupId: "group-456",
                title: "Bible Study", users: ["user-123", "user-789"]
            )
            XCTFail("createGroup() must throw on a 401 (expired session), not silently no-op")
        } catch {
            // expected
        }
    }

    func test_createGroup_succeeds_on200() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data()

        // Must not throw.
        try await NetworkService.shared.createGroup(
            userId: "user-123", groupId: "group-456",
            title: "Bible Study", users: ["user-123", "user-789"]
        )
    }

    // ── updateGroup ──────────────────────────────────────────────────────

    func test_updateGroup_throws_on422ContentFilterRejection() async {
        StubURLProtocol.stubStatusCode = 422
        StubURLProtocol.stubBody =
            #"{"detail": "Group title contains language that isn't allowed."}"#
            .data(using: .utf8)!

        do {
            try await NetworkService.shared.updateGroup(
                userId: "user-123", groupId: "group-456",
                title: "disallowed title", users: ["user-123", "user-789", "user-999"]
            )
            XCTFail("updateGroup() must throw on a 422 content-filter rejection, not silently no-op — this is exactly the case ChatThreadView.addMembers() relies on to roll back its optimistic member-list mutation")
        } catch {
            // expected
        }
    }

    func test_updateGroup_throws_on401ExpiredSession() async {
        StubURLProtocol.stubStatusCode = 401
        StubURLProtocol.stubBody = #"{"detail": "Not authenticated"}"#.data(using: .utf8)!

        do {
            try await NetworkService.shared.updateGroup(
                userId: "user-123", groupId: "group-456",
                title: "Bible Study", users: ["user-123", "user-789", "user-999"]
            )
            XCTFail("updateGroup() must throw on a 401 (expired session), not silently no-op")
        } catch {
            // expected
        }
    }

    func test_updateGroup_succeeds_on200() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data()

        // Must not throw — happy-path regression guard.
        try await NetworkService.shared.updateGroup(
            userId: "user-123", groupId: "group-456",
            title: "Bible Study", users: ["user-123", "user-789", "user-999"]
        )
    }
}
