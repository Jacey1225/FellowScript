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
