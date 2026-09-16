// GroupLeaveDeleteEndpointTests.swift — regression coverage for
// task: 20260916-group-leave-deletes-group (frontend step 3).
//
// Bug: NetworkService.leaveGroup(userId:groupId:) used to send
// `DELETE /groups/{userId}/{groupId}` — the same full-group-destroying
// route now reserved for the owner-gated "delete group" action — so any
// single member tapping "Leave" destroyed the group for everyone.
//
// The fix points leaveGroup at the new single-member-removal endpoint
// (`POST /groups/{userId}/{groupId}/leave`) and adds a distinct
// deleteGroup(userId:groupId:) for the explicit, owner-gated full deletion
// (`DELETE /groups/{userId}/{groupId}`).
//
// This proves, against the real NetworkService (not MockDataService) via
// the shared stubbed URLProtocol harness (see StubURLProtocol in
// NetworkServiceGetErrorHandlingTests.swift):
//   1. leaveGroup sends POST to the .../leave path, NOT DELETE to the bare
//      group path — the actual bug, must now pass.
//   2. deleteGroup sends DELETE to the bare group path — the distinct,
//      owner-gated action leaveGroup must no longer alias to.
//   3. Both propagate a server-side rejection (leaveGroup: unexpected
//      error; deleteGroup: 403 not-authorized) as a thrown error rather
//      than silently no-opping, matching this codebase's established
//      checkedRequestRaw/request() error-propagation convention.
//   4. Both succeed cleanly on a 204, so the fix doesn't turn a normal
//      leave/delete into a false failure.
//
// Run with Xcode/xcodebuild (see write-tests skill for the project's iOS
// test invocation).

import XCTest
@testable import FellowScript

final class GroupLeaveDeleteEndpointTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
    }

    // ── leaveGroup ───────────────────────────────────────────────────────

    func test_leaveGroup_sendsPOSTToLeaveEndpoint_notDELETEToBareGroupPath() async throws {
        StubURLProtocol.stubStatusCode = 204
        StubURLProtocol.stubBody = Data()

        try await NetworkService.shared.leaveGroup(userId: "user-123", groupId: "group-456")

        XCTAssertEqual(StubURLProtocol.requestLog.count, 1)
        let sent = StubURLProtocol.requestLog[0]
        XCTAssertEqual(sent.method, "POST",
                       "leaveGroup must POST to the dedicated leave endpoint, not DELETE the group outright")
        XCTAssertEqual(sent.path, "/api/groups/user-123/group-456/leave")
    }

    func test_leaveGroup_throws_onServerRejection() async {
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail": "unexpected failure"}"#.data(using: .utf8)!

        do {
            try await NetworkService.shared.leaveGroup(userId: "user-123", groupId: "group-456")
            XCTFail("leaveGroup() must throw on a server-side rejection, not silently no-op")
        } catch {
            // expected
        }
    }

    // ── deleteGroup ──────────────────────────────────────────────────────

    func test_deleteGroup_sendsDELETEToBareGroupPath() async throws {
        StubURLProtocol.stubStatusCode = 204
        StubURLProtocol.stubBody = Data()

        try await NetworkService.shared.deleteGroup(userId: "user-123", groupId: "group-456")

        XCTAssertEqual(StubURLProtocol.requestLog.count, 1)
        let sent = StubURLProtocol.requestLog[0]
        XCTAssertEqual(sent.method, "DELETE")
        XCTAssertEqual(sent.path, "/api/groups/user-123/group-456")
    }

    func test_deleteGroup_throws_on403NotAuthorized() async {
        StubURLProtocol.stubStatusCode = 403
        StubURLProtocol.stubBody = #"{"detail": "Not authorized to delete this group"}"#.data(using: .utf8)!

        do {
            try await NetworkService.shared.deleteGroup(userId: "user-123", groupId: "group-456")
            XCTFail("deleteGroup() must throw when the server denies (403) a non-owner caller, not silently no-op")
        } catch {
            // expected — this is exactly the case ChatViewModel.deleteGroup()
            // relies on to revert its optimistic remove and surface
            // deleteGroupActionError.
        }
    }

    // ── distinctness regression guard ───────────────────────────────────

    func test_leaveGroupAndDeleteGroup_hitDifferentPathsAndMethods() async throws {
        StubURLProtocol.stubStatusCode = 204
        StubURLProtocol.stubBody = Data()

        try await NetworkService.shared.leaveGroup(userId: "user-1", groupId: "group-9")
        try await NetworkService.shared.deleteGroup(userId: "user-1", groupId: "group-9")

        XCTAssertEqual(StubURLProtocol.requestLog.count, 2)
        let leaveReq = StubURLProtocol.requestLog[0]
        let deleteReq = StubURLProtocol.requestLog[1]
        XCTAssertNotEqual(leaveReq.path, deleteReq.path,
                           "leave and delete must no longer alias to the same route (the original bug)")
        XCTAssertNotEqual(leaveReq.method, deleteReq.method)
    }
}
