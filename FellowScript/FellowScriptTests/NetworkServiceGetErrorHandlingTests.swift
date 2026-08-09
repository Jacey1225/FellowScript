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

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fellowscript.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
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
}
