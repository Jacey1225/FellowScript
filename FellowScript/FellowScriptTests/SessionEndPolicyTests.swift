// SessionEndPolicyTests.swift — task 20261017-chat-ws-reconnect-stuck (step 3).
//
// Pure-logic coverage (no sockets, no URLProtocol stub, no run-loop pumping):
//   1. handshake status classification (auth rejection vs transient),
//   2. the stop-on-auth-failure / capped-backoff reconnect decision,
//   3. the global 401 path in NetworkService (which paths count, one
//      notification per 401, request still throws, unauthenticated endpoints
//      never mark the session ended),
//   4. the de-duplicating latch AppState uses.

import XCTest
@testable import FellowScript

final class SessionEndPolicyTests: XCTestCase {

    // MARK: classification

    func testHandshake401And403AreAuthRejected() {
        XCTAssertEqual(SessionEndPolicy.classifyHandshake(status: 401), .authRejected)
        XCTAssertEqual(SessionEndPolicy.classifyHandshake(status: 403), .authRejected)
    }

    func testOtherStatusesAndNoResponseAreTransient() {
        for status in [200, 400, 404, 429, 500, 502, 503, 504] {
            XCTAssertEqual(SessionEndPolicy.classifyHandshake(status: status), .transient, "status \(status)")
        }
        XCTAssertEqual(SessionEndPolicy.classifyHandshake(status: nil), .transient)
    }

    // MARK: reconnect decision

    func testAuthRejectionStopsTheLoop() {
        XCTAssertEqual(SessionEndPolicy.decide(handshakeStatus: 403, isDisconnecting: false, nextAttempt: 1),
                       .stopSessionEnded)
        XCTAssertEqual(SessionEndPolicy.decide(handshakeStatus: 401, isDisconnecting: false, nextAttempt: 7),
                       .stopSessionEnded)
    }

    func testTransientFailureRetriesWithCappedBackoff() {
        XCTAssertEqual(SessionEndPolicy.decide(handshakeStatus: nil, isDisconnecting: false, nextAttempt: 1),
                       .retry(after: 1))
        XCTAssertEqual(SessionEndPolicy.decide(handshakeStatus: 503, isDisconnecting: false, nextAttempt: 3),
                       .retry(after: 4))
        XCTAssertEqual(SessionEndPolicy.decide(handshakeStatus: nil, isDisconnecting: false, nextAttempt: 50),
                       .retry(after: 30))
    }

    func testBackoffGrowsThenCaps() {
        let delays = (1...8).map { SessionEndPolicy.backoffDelay(attempt: $0) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(SessionEndPolicy.backoffDelay(attempt: 0), 1)
        XCTAssertEqual(SessionEndPolicy.backoffDelay(attempt: 10_000), 30)
    }

    func testIntentionalCloseIsIgnoredEvenOnAuthStatus() {
        XCTAssertEqual(SessionEndPolicy.decide(handshakeStatus: 403, isDisconnecting: true, nextAttempt: 1), .ignore)
        XCTAssertEqual(SessionEndPolicy.decide(handshakeStatus: nil, isDisconnecting: true, nextAttempt: 1), .ignore)
    }

    // MARK: global 401 path

    func testOnly401OnAuthenticatedPathMarksSessionEnded() {
        XCTAssertTrue(SessionEndPolicy.shouldMarkSessionEnded(status: 401, path: "/api/message/u1/f1"))
        XCTAssertTrue(SessionEndPolicy.shouldMarkSessionEnded(status: 401, path: nil))
        XCTAssertFalse(SessionEndPolicy.shouldMarkSessionEnded(status: 403, path: "/api/message/u1/f1"))
        XCTAssertFalse(SessionEndPolicy.shouldMarkSessionEnded(status: 500, path: "/api/message/u1/f1"))
        XCTAssertFalse(SessionEndPolicy.shouldMarkSessionEnded(status: 404, path: "/api/message/u1/f1"))
    }

    func testPreLoginEndpointsNeverMarkSessionEnded() {
        let paths = [
            "/api/login", "/api/signup", "/api/logout", "/api/auth/google", "/api/auth/apple",
            "/api/auth/mfa/verify-login", "/api/auth/password-reset/request", "/api/app/capabilities",
            "/api/invites/preview", "/api/explorer/listings/abc123", "/login",
        ]
        for path in paths {
            XCTAssertTrue(SessionEndPolicy.isUnauthenticatedPath(path), path)
            XCTAssertFalse(SessionEndPolicy.shouldMarkSessionEnded(status: 401, path: path), path)
        }
        XCTAssertFalse(SessionEndPolicy.isUnauthenticatedPath("/api/user/u1"))
        XCTAssertFalse(SessionEndPolicy.isUnauthenticatedPath("/api/auth/mfa/enable"))
    }

    func testThrowIfErrorPostsSessionEndedOnAuthenticated401AndStillThrows() {
        let net = NetworkService.shared
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: .sessionEndedByServer, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let ok = HTTPURLResponse(url: URL(string: "https://fellowscript.com/api/user/u1")!, statusCode: 401,
                                 httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try net.throwIfError(ok, Data()))
        XCTAssertEqual(posts, 1)

        let login = HTTPURLResponse(url: URL(string: "https://fellowscript.com/api/login")!, statusCode: 401,
                                    httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try net.throwIfError(login, Data()))
        let caps = HTTPURLResponse(url: URL(string: "https://fellowscript.com/api/app/capabilities")!, statusCode: 401,
                                   httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try net.throwIfError(caps, Data()))
        let server = HTTPURLResponse(url: URL(string: "https://fellowscript.com/api/user/u1")!, statusCode: 500,
                                     httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try net.throwIfError(server, Data()))
        XCTAssertEqual(posts, 1, "pre-login 401s and non-401 errors must not mark the session ended")
    }

    // MARK: latch

    func testLatchHandlesABurstOnce() {
        var latch = SessionEndLatch()
        XCTAssertFalse(latch.isEnded)
        XCTAssertTrue(latch.mark())
        XCTAssertFalse(latch.mark())
        XCTAssertFalse(latch.mark())
        XCTAssertTrue(latch.isEnded)
        latch.reset()
        XCTAssertFalse(latch.isEnded)
        XCTAssertTrue(latch.mark())
    }
}
