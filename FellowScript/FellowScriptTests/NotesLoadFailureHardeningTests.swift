// NotesLoadFailureHardeningTests.swift — heavy testing coverage for task
// 20260817-notes-load-failure-cloudwatch-gap, step 4 (testing), covering the
// frontend gate's step 3 changes to NetworkService.swift.
//
// Unlike NotesPaginationRegressionTests.swift (which exercises NotesViewModel
// against the ThrowingTestDataService mock, proving VM-level cursor/append
// logic), this file exercises the REAL NetworkService directly against a
// stubbed HTTP layer — the acceptance criteria explicitly call for "an
// end-to-end test that decodes a real/representative current-backend
// response shape through the actual client code path", which the VM-level
// mock tests cannot prove (the mock never touches NetworkService's decode()
// or the actual JSON shapes api/routes/notes.py / community.py serialize).
//
// Covers:
//   1. fetchNotes decodes the REAL current GET /notes/{user_id} envelope
//      ({notes, next_cursor_created_at, next_cursor_id, has_more}) for both
//      a first page and a scroll-triggered next page fetched via the
//      previous page's own cursor — proving the client/server contract
//      introduced by 8710a27a is intact end-to-end, not just re-verified by
//      reading the code.
//   2. fetchGroupNotes decodes the REAL current GET /groups/{user_id}/
//      {group_id}/notes envelope (notes keyed by username, then by note id)
//      the same way, for both a first and next page.
//   3. THE REGRESSION ITSELF: fetchNotes against the OLD pre-8710a27a flat
//      `{note_id: note}` shape (no envelope) — reproducing exactly what an
//      out-of-date installed client build would still receive from today's
//      backend — no longer crashes or silently returns nothing invisibly:
//      it returns an empty NotesPage AND fires the new decode-failure beacon
//      (POST /monitoring/client-error) so the failure is no longer invisible
//      to the developer/reporter, per this task's acceptance criteria.
//   4. Same regression proof for fetchGroupNotes's manual-JSONSerialization
//      decode path (a malformed response missing the top-level "notes" key).
//   5. Happy-path regression guard: a well-formed response never fires the
//      beacon (no false-positive noise/cost on every normal page load).
//   6. Data-minimization contract: the beacon body carries only endpoint/
//      client_app_version/error_summary (per security step 2's review) —
//      never the raw response body, and `endpoint` is the templated path
//      ("GET /notes/{user_id}"), not a raw URL with query string/cursor
//      tokens (per security step 2's explicit note for steps 3-4).
//
// Uses StubURLProtocol (defined in NetworkServiceGetErrorHandlingTests.swift,
// same test target) extended with request logging so the fire-and-forget
// beacon call can be observed after the fact.

import XCTest
@testable import FellowScript

@MainActor
final class NotesLoadFailureHardeningTests: XCTestCase {

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

    /// The fire-and-forget beacon (`Task { try? await requestRaw(...) }` in
    /// NetworkService.reportDecodeFailure) is not awaited by its caller, so
    /// give it a brief window to actually run before asserting on
    /// StubURLProtocol.requestLog — same pattern used elsewhere in this
    /// target for other best-effort/fire-and-forget async work (see
    /// AppStateRegisterDeviceTokenErrorHandlingTests.swift).
    private func waitForFireAndForgetBeacon() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func beaconRequests() -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.path.contains("/monitoring/client-error") }
    }

    // MARK: 1 — fetchNotes: real envelope, first page + scroll-triggered next page

    func test_fetchNotes_decodesRealCurrentBackendEnvelope_firstPage_thenScrollTriggeredNextPage() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "notes": {
            "11111111-1111-1111-1111-111111111111": {
              "user": "user-1", "title": "Morning notes", "text": "body one",
              "public": false, "group_id": "", "is_reply": false,
              "timestamp": "2026-08-17 08:00:00", "created_at": "2026-08-17 08:00:00.123456+00",
              "verses": [], "replies": []
            },
            "22222222-2222-2222-2222-222222222222": {
              "user": "user-1", "title": "Evening notes", "text": "body two",
              "public": false, "group_id": "", "is_reply": false,
              "timestamp": "2026-08-16 20:00:00", "created_at": "2026-08-16 20:00:00.654321+00",
              "verses": [["1", "John", "3", "16"]], "replies": []
            }
          },
          "next_cursor_created_at": "2026-08-16 20:00:00.654321+00",
          "next_cursor_id": "22222222-2222-2222-2222-222222222222",
          "has_more": true
        }
        """#.data(using: .utf8)!

        let page1 = try await NetworkService.shared.fetchNotes(userId: "user-1")

        XCTAssertEqual(page1.notes.count, 2, "both notes in the real envelope's 'notes' object must decode")
        XCTAssertEqual(page1.notes["11111111-1111-1111-1111-111111111111"]?.title, "Morning notes")
        XCTAssertEqual(page1.notes["11111111-1111-1111-1111-111111111111"]?.id, "11111111-1111-1111-1111-111111111111",
                        "note.id must be set from the dict key, not left at the default UUID")
        XCTAssertEqual(page1.notes["11111111-1111-1111-1111-111111111111"]?.username, "",
                        "Personal notes (fetchNotes, not fetchGroupNotes) carry no outer username key to stamp -- must default to empty, never crash or leak an unrelated value")
        XCTAssertTrue(page1.hasMore, "has_more:true must carry through to NotesPage.hasMore")
        XCTAssertEqual(page1.nextCursorCreatedAt, "2026-08-16 20:00:00.654321+00")
        XCTAssertEqual(page1.nextCursorId, "22222222-2222-2222-2222-222222222222")

        // Scroll-triggered next page: pass page 1's own cursor back, exactly
        // as NotesViewModel.loadMoreIfNeeded does.
        StubURLProtocol.stubBody = #"""
        {
          "notes": {
            "33333333-3333-3333-3333-333333333333": {
              "user": "user-1", "title": "Older note", "text": "body three",
              "public": true, "group_id": "", "is_reply": false,
              "timestamp": "2026-08-15 10:00:00", "created_at": "2026-08-15 10:00:00.000000+00",
              "verses": [], "replies": []
            }
          },
          "next_cursor_created_at": "2026-08-15 10:00:00.000000+00",
          "next_cursor_id": "33333333-3333-3333-3333-333333333333",
          "has_more": false
        }
        """#.data(using: .utf8)!

        let page2 = try await NetworkService.shared.fetchNotes(
            userId: "user-1",
            cursorCreatedAt: page1.nextCursorCreatedAt,
            cursorId: page1.nextCursorId
        )

        XCTAssertEqual(page2.notes.count, 1)
        XCTAssertEqual(page2.notes["33333333-3333-3333-3333-333333333333"]?.title, "Older note")
        XCTAssertFalse(page2.hasMore, "has_more:false on the true last page must decode correctly")

        // The actual outgoing request for page 2 must carry the cursor as
        // query params (proves cursorQuery()/encodeURIComponent() wiring end
        // to end, not just that fetchNotes accepted the arguments).
        let requestURLs = StubURLProtocol.requestLog.map(\.url)
        XCTAssertTrue(requestURLs.contains { $0.contains("cursor_created_at=") && $0.contains("cursor_id=") },
                      "the scroll-triggered next-page request must include the cursor query params, got: \(requestURLs)")

        // Happy-path regression guard: two well-formed pages must never fire
        // the decode-failure beacon.
        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty, "a fully successful decode must never fire the client-error beacon")
    }

    // MARK: 2 — fetchGroupNotes: real envelope, first page + next page

    func test_fetchGroupNotes_decodesRealCurrentBackendEnvelope_firstPage_thenNextPage() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "notes": {
            "alice": {
              "44444444-4444-4444-4444-444444444444": {
                "user_id": "user-alice", "title": "Group note 1", "text": "shared body",
                "public": true, "group_id": "group-abc", "is_reply": false,
                "parent_note_id": null, "timestamp": "2026-08-17 09:00:00",
                "created_at": "2026-08-17 09:00:00.000000+00"
              }
            }
          },
          "next_cursor_created_at": "2026-08-17 09:00:00.000000+00",
          "next_cursor_id": "44444444-4444-4444-4444-444444444444",
          "has_more": true
        }
        """#.data(using: .utf8)!

        let page1 = try await NetworkService.shared.fetchGroupNotes(userId: "user-1", groupId: "group-abc")

        XCTAssertEqual(page1.notes.count, 1)
        let note1 = page1.notes["44444444-4444-4444-4444-444444444444"]
        XCTAssertEqual(note1?.title, "Group note 1")
        XCTAssertEqual(note1?.user, "user-alice", "the DB's 'user_id' key must be remapped to FSNote's 'user' field")
        XCTAssertEqual(note1?.username, "alice", "the outer 'notes[username]' key must be stamped onto the decoded note's new username field")
        XCTAssertEqual(note1?.group_id, "group-abc")
        XCTAssertTrue(page1.hasMore)

        StubURLProtocol.stubBody = #"""
        {
          "notes": {
            "bob": {
              "55555555-5555-5555-5555-555555555555": {
                "user_id": "user-bob", "title": "Group note 2", "text": "shared body 2",
                "public": true, "group_id": "group-abc", "is_reply": false,
                "parent_note_id": null, "timestamp": "2026-08-16 09:00:00",
                "created_at": "2026-08-16 09:00:00.000000+00"
              }
            }
          },
          "next_cursor_created_at": "2026-08-16 09:00:00.000000+00",
          "next_cursor_id": "55555555-5555-5555-5555-555555555555",
          "has_more": false
        }
        """#.data(using: .utf8)!

        let page2 = try await NetworkService.shared.fetchGroupNotes(
            userId: "user-1", groupId: "group-abc",
            cursorCreatedAt: page1.nextCursorCreatedAt, cursorId: page1.nextCursorId
        )

        XCTAssertEqual(page2.notes.count, 1)
        XCTAssertEqual(page2.notes["55555555-5555-5555-5555-555555555555"]?.user, "user-bob")
        XCTAssertEqual(page2.notes["55555555-5555-5555-5555-555555555555"]?.username, "bob",
                        "username must be re-stamped correctly on the next-page fetch too, not just the first page")
        XCTAssertFalse(page2.hasMore)

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(beaconRequests().isEmpty, "a fully successful group-notes decode must never fire the beacon")
    }

    // MARK: 3 — THE REGRESSION: fetchNotes against the OLD pre-envelope shape

    /// Reproduces the exact incident root cause: today's backend always
    /// sends the new envelope, but an out-of-date installed client build's
    /// OLD decode ([String: FSNote] with no envelope) is what actually broke
    /// in production. This proves the CURRENT client code, if handed that
    /// same flat old-style shape (e.g. by a hypothetical future contract
    /// regression, or to directly document what the incident's payload
    /// shape does against today's decode() hardening), no longer silently
    /// vanishes: it returns an empty page it can safely fall back to AND the
    /// developer/reporter now gets a beacon instead of nothing.
    func test_fetchNotes_oldPreEnvelopeFlatShape_decodeFails_returnsEmptyPage_andFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        // The OLD pre-8710a27a shape: a flat {note_id: note} dict with no
        // "notes"/"has_more" wrapper at all -- exactly what decode(RawNotesPage.self, ...)
        // cannot parse (missing the required "notes"/"has_more" keys).
        StubURLProtocol.stubBody = #"""
        {
          "66666666-6666-6666-6666-666666666666": {
            "user": "user-1", "title": "Pre-pagination note", "text": "body",
            "public": false, "group_id": "", "is_reply": false,
            "timestamp": "2026-08-10 08:00:00", "verses": [], "replies": []
          }
        }
        """#.data(using: .utf8)!

        let page = try await NetworkService.shared.fetchNotes(userId: "user-1")

        XCTAssertTrue(page.notes.isEmpty, "an undecodable envelope must fall back to an empty page, not crash")
        XCTAssertFalse(page.hasMore, "an undecodable envelope must not claim there's more to load")
        XCTAssertNil(page.nextCursorCreatedAt)
        XCTAssertNil(page.nextCursorId)

        try await waitForFireAndForgetBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1,
                        "the decode failure must no longer be silently swallowed -- it must fire exactly one beacon")

        guard let beacon = beacons.first else { return }
        XCTAssertEqual(beacon.method, "POST")
        let body = beacon.bodyJSON
        XCTAssertEqual(body?["endpoint"] as? String, "GET /notes/{user_id}",
                        "endpoint must be the templated path (per security step 2's note), not a raw URL with query/cursor tokens")
        XCTAssertNotNil(body?["client_app_version"] as? String, "must report a client_app_version so a triager can tell an old build from a new bug")
        let summary = body?["error_summary"] as? String
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary?.isEmpty ?? true, "error_summary must actually describe the decode failure, not be blank")
        XCTAssertLessThanOrEqual(summary?.count ?? 0, 500, "error_summary must respect the 500-char server-side cap")

        // Data minimization (security step 2): the beacon body must carry
        // ONLY the documented minimal fields -- never the raw response body
        // that failed to decode, which could carry other-user content.
        let allowedKeys: Set<String> = ["endpoint", "client_app_version", "error_summary", "http_status"]
        let actualKeys: Set<String> = Set(body?.keys.map { $0 } ?? [])
        XCTAssertTrue(actualKeys.isSubset(of: allowedKeys),
                      "beacon body must not carry any field beyond the documented minimal set, got keys: \(actualKeys)")
        if let bodyData = beacon.bodyData, let bodyString = String(data: bodyData, encoding: .utf8) {
            XCTAssertFalse(bodyString.contains("Pre-pagination note"),
                            "the beacon must never include the raw response body content (e.g. note text)")
        }
    }

    // MARK: 4 — THE REGRESSION: fetchGroupNotes against a malformed shape

    func test_fetchGroupNotes_malformedShape_missingNotesKey_returnsEmptyPage_andFiresBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"unexpected": "shape", "no_notes_key": true}"#.data(using: .utf8)!

        let page = try await NetworkService.shared.fetchGroupNotes(userId: "user-1", groupId: "group-abc")

        XCTAssertTrue(page.notes.isEmpty)
        XCTAssertFalse(page.hasMore)

        try await waitForFireAndForgetBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1, "the group-notes decode failure must also no longer be silently swallowed")
        XCTAssertEqual(beacons.first?.bodyJSON?["endpoint"] as? String, "GET /groups/{user_id}/{group_id}/notes")
    }
}
