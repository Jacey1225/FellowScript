// NetworkServiceSyncAppleSubscriptionErrorHandlingTests.swift — regression
// coverage for task: 20260808-ios-backend-integration-audit, step 15
// (frontend), finding 1: the CRITICAL false-success StoreKit purchase bug —
// "real money is at stake" per backend step 14's audit.
//
// Root cause layer proven here (the lowest of the three compounding layers
// backend step 14 / frontend step 15 identified):
//
//   NetworkService.syncAppleSubscription used to call `requestRaw` (no
//   throwIfError) and had no empty-id guard. POST /subscriptions/apple/sync
//   returns a 400 body like {"detail": "Non-production transaction ignored"}
//   or a 409 like {"detail": "This Apple subscription is already linked to a
//   different account."} for a rejected sync — but FSSubscription's decoder
//   (Models.swift) is FULLY LENIENT (every field falls back to a default via
//   `try?`), so decoding either error body "succeeds" and produces a non-nil,
//   all-default FSSubscription (id: "", status: "inactive", ...) instead of
//   throwing or returning nil. StoreKitManager.purchase() would then treat
//   that non-nil result as a successful sync, finish() the transaction (so
//   StoreKit will never re-present it), and report the purchase as
//   successful to the user — even though the backend never granted the plan.
//   The user has paid Apple and gets nothing: a paid-but-unentitled state.
//
// The fix: syncAppleSubscription now uses checkedRequestRaw (throws on any
// 4xx/5xx) AND guards `!sub.id.isEmpty` on the one legitimate no-id success
// body (`{"status": "expired"}`, mirroring fetchUserSubscription's existing
// pattern directly above it in NetworkService.swift), so a real rejection can
// no longer masquerade as a successful (if empty) plan.
//
// Exercised against the REAL NetworkService (not MockDataService) via the
// StubURLProtocol already defined in NetworkServiceGetErrorHandlingTests.swift,
// since the bug lives in NetworkService's HTTP/decode handling itself.

import XCTest
@testable import FellowScript

final class NetworkServiceSyncAppleSubscriptionErrorHandlingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    /// The exact pre-fix failure mode: a 400 rejection ("untrusted
    /// environment" / "unknown product" / "invalid transaction") must throw,
    /// not decode into a bogus non-nil FSSubscription.
    func test_syncAppleSubscription_throws_on400_insteadOfDecodingBogusSubscription() async {
        StubURLProtocol.stubStatusCode = 400
        StubURLProtocol.stubBody = #"{"detail": "Non-production transaction ignored"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.syncAppleSubscription(userId: "user-123", jws: "fake-jws")
            XCTFail("syncAppleSubscription() must throw on a 400 response, not return a decoded FSSubscription")
        } catch {
            if case AppError.networkError(let detail) = error {
                XCTAssertEqual(detail, "Non-production transaction ignored")
            } else {
                XCTFail("expected AppError.networkError, got \(error)")
            }
        }
    }

    /// The other rejection case the backend explicitly returns: 409, "already
    /// linked to a different account" — same requirement, must throw.
    func test_syncAppleSubscription_throws_on409_alreadyLinkedToDifferentAccount() async {
        StubURLProtocol.stubStatusCode = 409
        StubURLProtocol.stubBody = #"{"detail": "This Apple subscription is already linked to a different account."}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.syncAppleSubscription(userId: "user-123", jws: "fake-jws")
            XCTFail("syncAppleSubscription() must throw on a 409 response")
        } catch {
            if case AppError.networkError(let detail) = error {
                XCTAssertEqual(detail, "This Apple subscription is already linked to a different account.")
            } else {
                XCTFail("expected AppError.networkError, got \(error)")
            }
        }
    }

    /// Regression-proof that the bug is real without the fix: decoding these
    /// exact error bodies directly through FSSubscription's lenient decoder
    /// (independent of NetworkService) produces a non-nil, "successful-looking"
    /// subscription — this is what StoreKitManager.purchase() would have
    /// treated as a granted plan before the checkedRequestRaw + empty-id-guard
    /// fix made NetworkService throw before ever reaching this decode step.
    func test_regressionProof_lenientDecoderAloneWouldTurnRejectionBodyIntoBogusSubscription() throws {
        let rejectionBody = #"{"detail": "Non-production transaction ignored"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FSSubscription.self, from: rejectionBody)
        XCTAssertEqual(decoded.id, "", "sanity: the lenient decoder alone cannot distinguish a rejection body from a real empty-id success body")
        XCTAssertEqual(decoded.status, "inactive")
        // This is exactly why the fix cannot rely on decode() + an id-emptiness
        // check alone without ALSO throwing on the HTTP status first — a 200
        // success body legitimately has no id (`{"status": "expired"}`), so the
        // id-emptiness guard by itself can't tell "rejected" from "no active
        // plan" without checkedRequestRaw's throwIfError running first.
    }

    /// The one legitimate no-id SUCCESS body — `{"status": "expired"}`,
    /// returned with 200 when the transaction is no longer active — must
    /// decode to `nil`, not be confused with a real plan.
    func test_syncAppleSubscription_returnsNil_onExpiredStatusBody_withNoId() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"status": "expired"}"#.data(using: .utf8)!

        let result = try await NetworkService.shared.syncAppleSubscription(userId: "user-123", jws: "fake-jws")
        XCTAssertNil(result, "a success body with no id ('expired') must decode to nil, not a bogus empty-id plan")
    }

    /// Happy-path regression guard: a genuine successful sync (200, real id)
    /// must still decode and return correctly.
    func test_syncAppleSubscription_returnsDecodedSubscription_on200WithId() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {"id": "sub-abc123", "user_id": "user-123", "plan_type": "group", "provider": "apple",
         "status": "active", "price_cents": 1799, "max_members": 2}
        """#.data(using: .utf8)!

        let result = try await NetworkService.shared.syncAppleSubscription(userId: "user-123", jws: "fake-jws")
        XCTAssertEqual(result?.id, "sub-abc123")
        XCTAssertEqual(result?.status, "active")
        XCTAssertEqual(result?.provider, "apple")
    }
}
