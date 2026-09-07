// NetworkServiceSendNudgeTests.swift — testing coverage for task
// 20260906-friend-nudges, testing step 4 (re-entry pass).
//
// Covers NetworkService.sendNudge(userId:friendId:) — the shared client-side
// helper every nudge-trigger surface (CheckInRow today) calls — against the
// real NetworkService via a stubbed HTTP layer, since the status-code-to-
// NudgeResult mapping this method owns lives in NetworkService's own HTTP
// handling (throwIfError's AppError.rateLimited case, this method's own
// do/catch), not in any mock. Mirrors NetworkServiceGetErrorHandlingTests.swift
// / CheckInRowFetchFailureHardeningTests.swift's established pattern of
// exercising the real NetworkService against StubURLProtocol (defined in
// NetworkServiceGetErrorHandlingTests.swift, same test target).
//
// See DashboardCheckInNudgeTests.swift for the sibling coverage of
// DashboardViewModel.sendCheckInNudge's state-machine consumption of this
// same NudgeResult contract.
//
// Covers every documented mapping from NetworkService+Contacts.swift's own
// sendNudge doc comment:
//   204                              -> .sent
//   429 (per-pair or per-IP limit)   -> .rateLimited
//   403 (not friend / blocked)       -> .failed
//   404 (feature disabled, or
//        recipient unreachable)      -> .failed
//   502 (APNs delivery failure)      -> .failed
//   500 (misconfigured APNs)         -> .failed
// plus the request shape itself: POST /friends/{userId}/{friendId}/nudge,
// with the friendId percent-encoded.

import XCTest
@testable import FellowScript

final class NetworkServiceSendNudgeTests: XCTestCase {

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

    // MARK: Request shape

    func test_sendNudge_postsToCorrectPath_withPercentEncodedFriendId() async {
        StubURLProtocol.stubStatusCode = 204
        StubURLProtocol.stubBody = Data()

        let result = await NetworkService.shared.sendNudge(userId: "user-123", friendId: "friend one/two")

        XCTAssertEqual(result, .sent)
        guard let req = StubURLProtocol.requestLog.first else {
            XCTFail("expected exactly one request")
            return
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertTrue(req.url.contains("/friends/user-123/"), "must target the documented per-recipient nudge path")
        XCTAssertTrue(req.url.hasSuffix("/nudge"))
        XCTAssertFalse(req.url.contains("friend one/two"),
                       "friendId must be percent-encoded, not interpolated raw into the path")
    }

    // MARK: Success

    func test_sendNudge_204_returnsSent() async {
        StubURLProtocol.stubStatusCode = 204
        StubURLProtocol.stubBody = Data()

        let result = await NetworkService.shared.sendNudge(userId: "user-123", friendId: "friend-1")

        XCTAssertEqual(result, .sent)
    }

    // MARK: Rate-limited (both the per-pair limit and the per-IP backstop return 429)

    func test_sendNudge_429_returnsRateLimited_notFailed() async {
        StubURLProtocol.stubStatusCode = 429
        StubURLProtocol.stubBody = #"{"detail": "Already nudged recently"}"#.data(using: .utf8)!

        let result = await NetworkService.shared.sendNudge(userId: "user-123", friendId: "friend-1")

        XCTAssertEqual(result, .rateLimited,
                       "a 429 must map to the distinguishable .rateLimited case, never collapse into generic .failed")
    }

    // MARK: Rejections that must all collapse to .failed, not crash or propagate

    func test_sendNudge_403_notFriendOrBlocked_returnsFailed() async {
        StubURLProtocol.stubStatusCode = 403
        StubURLProtocol.stubBody = #"{"detail": "Not friends with this user"}"#.data(using: .utf8)!

        let result = await NetworkService.shared.sendNudge(userId: "user-123", friendId: "friend-1")

        XCTAssertEqual(result, .failed)
    }

    func test_sendNudge_404_featureDisabledOrUnreachable_returnsFailed() async {
        StubURLProtocol.stubStatusCode = 404
        StubURLProtocol.stubBody = #"{"detail": "Not found"}"#.data(using: .utf8)!

        let result = await NetworkService.shared.sendNudge(userId: "user-123", friendId: "friend-1")

        XCTAssertEqual(result, .failed)
    }

    func test_sendNudge_502_apnsDeliveryFailure_returnsFailed() async {
        StubURLProtocol.stubStatusCode = 502
        StubURLProtocol.stubBody = #"{"detail": "Push delivery failed"}"#.data(using: .utf8)!

        let result = await NetworkService.shared.sendNudge(userId: "user-123", friendId: "friend-1")

        XCTAssertEqual(result, .failed)
    }

    func test_sendNudge_500_misconfiguredApns_returnsFailed_doesNotThrowOrCrash() async {
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail": "Internal Server Error"}"#.data(using: .utf8)!

        let result = await NetworkService.shared.sendNudge(userId: "user-123", friendId: "friend-1")

        XCTAssertEqual(result, .failed,
                       "sendNudge is deliberately non-throwing (see its doc comment) -- even a loud server-side " +
                       "APNs-misconfiguration 500 must resolve to .failed for the caller, not propagate an error")
    }
}
