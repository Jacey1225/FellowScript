// NetworkServiceGetErrorHandlingTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, step 3 (frontend), finding 3.
//
// NetworkService.get() — the shared private helper behind nearly every
// fetch* method across every domain (user, notes, agents, notifications,
// highlights, bookmarks, blocks, contacts, usage, subscriptions...) — never
// called throwIfError(), unlike request()/checkedRequestRaw(). Any HTTP error
// response (e.g. a 401 from an expired session) silently decoded to nil and
// fell through to a blank default value or empty collection instead of being
// surfaced as a thrown error.
//
// This is the exact code path incident #2 (20260808-timezone-display-stale-utc)
// lives in: AccountView.load() calls `try? await service.fetchUser(...)`, and
// before this fix a 401 mid-session would silently replace good cached
// profile data with a blank FSUser instead of leaving it untouched (since
// `try?` only preserves the old value when the call actually throws).
//
// Exercised against the real NetworkService (not MockDataService) via a
// stubbed URLProtocol, since the bug lives in NetworkService's HTTP handling
// itself, not in any mock.

import XCTest
@testable import FellowScript

/// Intercepts every request NetworkService makes (it always targets
/// `fellowscript.com`) and returns a configured status code + body instead of
/// hitting the real network. Registered globally via `URLProtocol
/// .registerClass`, which `URLSession.shared` (what NetworkService uses)
/// honors for the default configuration.
final class StubURLProtocol: URLProtocol {
    static var stubStatusCode = 200
    static var stubBody: Data = Data()

    /// One entry per intercepted request, in call order -- lets tests prove
    /// NOT ONLY what NetworkService did with a stubbed response, but also
    /// what (if anything) it sent back out afterward, e.g. the fire-and-
    /// forget POST /monitoring/client-error decode-failure beacon
    /// (NotesLoadFailureHardeningTests.swift). `bodyData` is reconstructed
    /// from `httpBodyStream` when present -- URLSession commonly hands a
    /// custom URLProtocol the body as a stream rather than surfacing it via
    /// `request.httpBody` directly once the request has been handed off.
    struct RecordedRequest {
        let path:   String   // URL path only, no query string (use `url` for query-string assertions)
        let url:    String   // full absoluteString, including query string
        let method: String
        let bodyData: Data?
        // The built URLRequest's timeoutInterval -- added for
        // 20260828-networkservice-get-hang-investigation to let tests verify
        // NetworkService's four request-building helpers (get()/request()/
        // requestRaw()/checkedRequestRaw()) actually attach the new defensive
        // 30s bound rather than leaving it implicit/untested. Additive field,
        // only ever populated by startLoading() below, so it's safe for the
        // 7 other files sharing this harness.
        let timeoutInterval: TimeInterval
        var bodyJSON: [String: Any]? {
            guard let bodyData, !bodyData.isEmpty else { return nil }
            return (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        }
    }
    static var requestLog: [RecordedRequest] = []

    static func resetRequestLog() { requestLog = [] }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data.isEmpty ? nil : data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fellowscript.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestLog.append(RecordedRequest(
            path: request.url?.path ?? "",
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            bodyData: Self.readBody(from: request),
            timeoutInterval: request.timeoutInterval
        ))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.stubStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class NetworkServiceGetErrorHandlingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    /// Before the fix: a 401 (e.g. an expired session) during fetchUser()
    /// silently decoded to nil and NetworkService.fetchUser() fell back to a
    /// blank `FSUser(user_id: userId, username: "", email: "")` instead of
    /// throwing — exactly the shape that clobbers good cached profile data
    /// in AccountView.load()'s `try? await fetchUser(...)`. After the fix,
    /// get() calls throwIfError() and the error propagates.
    func test_fetchUser_throws_on401_insteadOfReturningBlankUser() async {
        StubURLProtocol.stubStatusCode = 401
        StubURLProtocol.stubBody = #"{"detail": "Not authenticated"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.fetchUser(userId: "user-123")
            XCTFail("fetchUser() must throw on a 401 response, not silently return a blank FSUser")
        } catch {
            // expected — any thrown error is correct; specifically confirm it's
            // surfaced as the app's typed network error, not decoded as success.
            if case AppError.networkError(let detail) = error {
                XCTAssertEqual(detail, "Not authenticated")
            } else {
                XCTFail("expected AppError.networkError, got \(error)")
            }
        }
    }

    /// Same class of bug, a second call site: a 500 during fetchNotes() must
    /// throw rather than silently returning an empty notes dictionary that
    /// looks indistinguishable from "this user really has zero notes".
    func test_fetchNotes_throws_on500_insteadOfReturningEmptyDictionary() async {
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail": "Internal Server Error"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.fetchNotes(userId: "user-123")
            XCTFail("fetchNotes() must throw on a 500 response, not silently return an empty dictionary")
        } catch {
            // expected
        }
    }

    /// Happy path regression guard: a normal 200 response must still decode
    /// and return correctly — the fix must not turn successful reads into
    /// false failures.
    func test_fetchUser_returnsDecodedUser_on200() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {"user_id": "user-123", "username": "alice", "email": "alice@example.com", "timezone": "America/Los_Angeles"}
        """#.data(using: .utf8)!

        let user = try await NetworkService.shared.fetchUser(userId: "user-123")

        XCTAssertEqual(user.user_id, "user-123")
        XCTAssertEqual(user.username, "alice")
        XCTAssertEqual(user.timezone, "America/Los_Angeles")
    }

    // MARK: - Decode-failure-disguised-as-empty-page hardening (20260905-notes-group-refresh-clobber-rootcause)
    //
    // Root cause of the live "group notes wiped to empty on pull-to-refresh"
    // report: fetchNotes'/fetchGroupNotes' own decode-failure branches used
    // to fabricate a successful, non-throwing, EMPTY NotesPage instead of
    // throwing -- indistinguishable, at NotesViewModel.fetchAndCache's
    // merge/splice layer, from a genuinely-empty backend page. These tests
    // exercise the REAL NetworkService code path (via StubURLProtocol, a
    // 200 status so throwIfError() doesn't intervene first) proving a
    // malformed-but-200 response now throws instead of returning a
    // fabricated empty page.
    //
    // Live-data investigation note: this task also traced GroupsManager
    // .fetch_notes' actual return shape against real, production-mirrored
    // data for the exact group/user the user reported ("Godly Goobers",
    // 60aa9553-b147-4e09-9a6e-b3e3abcf57f0) at the DB/backend-code layer
    // (api/backend/interactions/groups.py, run locally against a synced
    // dev DB containing that same group/user/notes) -- every field the real
    // backend sends (user_id, title, text, public, group_id, is_reply,
    // parent_note_id, timestamp, created_at, profile_photo_url) matches
    // what fetchGroupNotes' manual parse + FSNote's fully-lenient
    // `decodeLenient`-based Decodable conformance (Models.swift) already
    // require or gracefully default, and produced no decode failure for
    // that group's real 15-note page. So the fabricated-empty-page bug this
    // fix closes is a real, live-reachable gap (confirmed reachable via the
    // synthetic malformed-response tests below, and the class of bug most
    // exposed to it per the intake's architecture step), but it is NOT
    // presently tripped by this specific group's ordinary, well-formed
    // note data -- a normal refresh for that group succeeds today, both
    // before and after this fix; the fix's value is making a genuine
    // decode failure (whatever transient/infra condition triggers one --
    // no direct evidence of one firing in production was found, matching
    // the intake's own open question) fail safely and visibly instead of
    // silently wiping good data. `test_fetchGroupNotes_decodesRealBackendShape_
    // withoutThrowing` below pins that real captured response shape as a
    // permanent regression guard.

    func test_fetchGroupNotes_throws_onMalformedResponseShape_insteadOfReturningEmptyPage() async {
        StubURLProtocol.stubStatusCode = 200
        // Valid JSON, 200 status (throwIfError never fires), but missing the
        // required top-level "notes" object entirely -- the exact shape
        // fetchGroupNotes' `guard let top = ..., let outer = top["notes"]
        // as? [String: Any] else { throw ... }` exists to catch.
        StubURLProtocol.stubBody = #"{"unexpected": "shape"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.fetchGroupNotes(userId: "user-123", groupId: "group-abc")
            XCTFail("fetchGroupNotes() must throw on a malformed response shape, not silently return an empty NotesPage")
        } catch {
            // expected -- any thrown error is correct; the group's segment
            // must be treated as "this fetch failed", never as "this group
            // is now genuinely empty".
        }
    }

    func test_fetchNotes_throws_onUndecodableBody_insteadOfReturningEmptyPage() async {
        StubURLProtocol.stubStatusCode = 200
        // Valid JSON, 200 status, but not RawNotesPage's shape at all (no
        // "notes"/"has_more" keys) -- distinct from the 500-status test
        // above, which never even reaches decode() because throwIfError()
        // intervenes first. This is the actual decode-failure branch fix.
        StubURLProtocol.stubBody = #"{"unexpected": "shape"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.fetchNotes(userId: "user-123")
            XCTFail("fetchNotes() must throw when a 200 response body can't decode as RawNotesPage, not silently return an empty page")
        } catch {
            // expected
        }
    }

    /// Regression guard pinning the REAL response shape traced from
    /// GroupsManager.fetch_notes (see MARK comment above) -- a well-formed
    /// page must keep decoding successfully; this fix must not turn a
    /// legitimate, well-formed response into a false failure.
    func test_fetchGroupNotes_decodesRealBackendShape_withoutThrowing() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {"notes": {"jaceysimpson": {"e2913f3d-e2bf-4b58-88a8-249e60000518": {
            "user_id": "60aa9553-b147-4e09-9a6e-b3e3abcf57f0",
            "title": "Dead Works",
            "text": "Just wanted to take this verse as a reminder to myself.",
            "public": true,
            "group_id": "b7fce9fc-3658-42c1-9e03-dde6c6b80c51",
            "is_reply": false,
            "parent_note_id": null,
            "timestamp": "2026-05-30T05:52:42.120403-07:00",
            "created_at": "2026-08-30T21:19:36.240889-07:00",
            "profile_photo_url": null
        }}}, "next_cursor_created_at": "2026-08-30 21:19:36.240889-07", "next_cursor_id": "38c318b1-67dd-40fd-ba93-ac2c000603e7", "has_more": true}
        """#.data(using: .utf8)!

        let page = try await NetworkService.shared.fetchGroupNotes(userId: "60aa9553-b147-4e09-9a6e-b3e3abcf57f0", groupId: "b7fce9fc-3658-42c1-9e03-dde6c6b80c51")

        XCTAssertEqual(page.notes.count, 1)
        let decoded = try XCTUnwrap(page.notes["e2913f3d-e2bf-4b58-88a8-249e60000518"])
        XCTAssertEqual(decoded.title, "Dead Works")
        XCTAssertEqual(decoded.user, "60aa9553-b147-4e09-9a6e-b3e3abcf57f0", "user_id must be remapped to FSNote.user")
        XCTAssertEqual(decoded.username, "jaceysimpson", "the outer notes[username] key must be stamped onto the decoded note")
        XCTAssertTrue(page.hasMore)
    }

    // MARK: - Request timeout hardening (20260828-networkservice-get-hang-investigation)
    //
    // get()/request()/requestRaw()/checkedRequestRaw() now attach an explicit
    // 30s timeoutInterval to every request they build, so a stalled/
    // black-holed connect phase can no longer hang indefinitely -- the one
    // plausible mechanism identified for the never-reproduced hang this test
    // class is named for (see that task's testing.json for the four real,
    // no-mock reproduction attempts that all came back clean). These tests
    // would catch a regression that silently drops the timeout from any of
    // the four helpers (e.g. a future refactor), which nothing else in this
    // suite currently checks.

    func test_get_attachesThirtySecondTimeout() async throws {
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"user_id": "u1", "username": "a", "email": "a@example.com"}"#.data(using: .utf8)!

        _ = try await NetworkService.shared.fetchUser(userId: "u1")

        XCTAssertEqual(StubURLProtocol.requestLog.last?.timeoutInterval, 30,
                        "get() (via fetchUser) must attach the 30s defensive timeout")
    }

    func test_request_attachesThirtySecondTimeout() async {
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data()

        _ = try? await NetworkService.shared.logout()

        XCTAssertEqual(StubURLProtocol.requestLog.last?.timeoutInterval, 30,
                        "request() (via logout) must attach the 30s defensive timeout")
    }

    func test_requestRaw_attachesThirtySecondTimeout() async {
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"user_id": "u1", "username": "a", "email": "a@example.com"}"#.data(using: .utf8)!

        _ = try? await NetworkService.shared.signIn(username: "a", password: "b")

        XCTAssertEqual(StubURLProtocol.requestLog.last?.timeoutInterval, 30,
                        "requestRaw() (via signIn) must attach the 30s defensive timeout")
    }

    func test_checkedRequestRaw_attachesThirtySecondTimeout() async {
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = Data()

        _ = try? await NetworkService.shared.mfaEnable()

        XCTAssertEqual(StubURLProtocol.requestLog.last?.timeoutInterval, 30,
                        "checkedRequestRaw() (via mfaEnable) must attach the 30s defensive timeout")
    }
}
