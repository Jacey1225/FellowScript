// NotesGroupMultiMemberVisibilityTests.swift — frontend gate coverage for
// task 20260828-group-notes-visibility-ios.
//
// Reported symptom: opening a group's notes segment on iOS only showed the
// current user's own notes, not every member's. Investigation (see this
// task's intake-spec.md) traced the path end to end and found the backend
// (GroupsManager.fetch_notes) already returns every member's notes
// correctly; NetworkService.fetchGroupNotes' manual per-note decode walk
// was the prime suspect for a silent per-note drop, but it had zero
// diagnostics on that path (only the outer "notes key missing" case was
// beaconed). This file:
//
//   1. Locks in the actual multi-member behavior end to end: a single
//      GET /groups/{user_id}/{group_id}/notes response containing more than
//      one username's notes must surface ALL of them in the decoded
//      NotesPage, not just one — the concrete regression this task reports.
//   2. Proves the newly-added granular per-note failure diagnostics (this
//      task's fix) actually fire when one member's note entry is malformed,
//      while still returning every other member's valid notes in the same
//      response (a malformed note must never take down its neighbors).
//
// Reuses StubURLProtocol from NetworkServiceGetErrorHandlingTests.swift
// (same test target), same pattern as NotesLoadFailureHardeningTests.swift.

import XCTest
@testable import FellowScript

@MainActor
final class NotesGroupMultiMemberVisibilityTests: XCTestCase {

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

    private func waitForFireAndForgetBeacon() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func beaconRequests() -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.path.contains("/monitoring/client-error") }
    }

    // MARK: 1 — every member's notes must decode, not just the caller's own

    func test_fetchGroupNotes_multipleMembersInOneResponse_allMembersNotesDecode() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "notes": {
            "me": {
              "aaaaaaaa-1111-1111-1111-111111111111": {
                "user_id": "user-me", "title": "My note", "text": "own body",
                "public": true, "group_id": "group-abc", "is_reply": false,
                "parent_note_id": null, "timestamp": "2026-08-17 09:00:00",
                "created_at": "2026-08-17 09:00:00.000000+00"
              }
            },
            "alice": {
              "bbbbbbbb-2222-2222-2222-222222222222": {
                "user_id": "user-alice", "title": "Alice note", "text": "alice body",
                "public": true, "group_id": "group-abc", "is_reply": false,
                "parent_note_id": null, "timestamp": "2026-08-17 08:00:00",
                "created_at": "2026-08-17 08:00:00.000000+00"
              }
            },
            "bob": {
              "cccccccc-3333-3333-3333-333333333333": {
                "user_id": "user-bob", "title": "Bob note", "text": "bob body",
                "public": false, "group_id": "group-abc", "is_reply": false,
                "parent_note_id": null, "timestamp": "2026-08-17 07:00:00",
                "created_at": "2026-08-17 07:00:00.000000+00"
              }
            }
          },
          "next_cursor_created_at": "2026-08-17 07:00:00.000000+00",
          "next_cursor_id": "cccccccc-3333-3333-3333-333333333333",
          "has_more": false
        }
        """#.data(using: .utf8)!

        let page = try await NetworkService.shared.fetchGroupNotes(userId: "user-me", groupId: "group-abc")

        XCTAssertEqual(page.notes.count, 3, "all three members' notes must decode, not just the caller's own")
        XCTAssertEqual(page.notes["aaaaaaaa-1111-1111-1111-111111111111"]?.user, "user-me")
        XCTAssertEqual(page.notes["bbbbbbbb-2222-2222-2222-222222222222"]?.user, "user-alice")
        XCTAssertEqual(page.notes["cccccccc-3333-3333-3333-333333333333"]?.user, "user-bob")
        // Every note must carry the requested group's id, regardless of author.
        XCTAssertTrue(page.notes.values.allSatisfy { $0.group_id == "group-abc" })

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty, "a fully successful multi-member decode must never fire the beacon")
    }

    // MARK: 2 — one member's malformed note is dropped + beaconed, others are unaffected

    func test_fetchGroupNotes_oneMemberNoteMalformed_isDroppedAndBeaconed_othersStillDecode() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "notes": {
            "alice": {
              "dddddddd-4444-4444-4444-444444444444": "this is not a note object"
            },
            "bob": {
              "eeeeeeee-5555-5555-5555-555555555555": {
                "user_id": "user-bob", "title": "Bob's valid note", "text": "still here",
                "public": true, "group_id": "group-abc", "is_reply": false,
                "parent_note_id": null, "timestamp": "2026-08-17 07:00:00",
                "created_at": "2026-08-17 07:00:00.000000+00"
              }
            }
          },
          "next_cursor_created_at": null,
          "next_cursor_id": null,
          "has_more": false
        }
        """#.data(using: .utf8)!

        let page = try await NetworkService.shared.fetchGroupNotes(userId: "user-me", groupId: "group-abc")

        XCTAssertEqual(page.notes.count, 1, "the malformed note must be dropped, but bob's valid note must still decode")
        XCTAssertEqual(page.notes["eeeeeeee-5555-5555-5555-555555555555"]?.title, "Bob's valid note")
        XCTAssertNil(page.notes["dddddddd-4444-4444-4444-444444444444"])

        try await waitForFireAndForgetBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1, "the malformed per-note entry must no longer be silently dropped with zero trace")
        XCTAssertEqual(beacons.first?.bodyJSON?["endpoint"] as? String, "GET /groups/{user_id}/{group_id}/notes")
        let summary = beacons.first?.bodyJSON?["error_summary"] as? String
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary?.isEmpty ?? true)
    }
}
