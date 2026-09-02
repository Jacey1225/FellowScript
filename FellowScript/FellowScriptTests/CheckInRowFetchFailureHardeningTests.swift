// CheckInRowFetchFailureHardeningTests.swift — testing coverage for task
// 20260827-checkin-row-investigation, testing step 2, covering frontend step
// 1's change to NetworkService.swift.
//
// The confirmed root cause of the reported bug was NOT a code bug (backend
// step 1: production was simply running a stale deploy predating the whole
// feature) — but the investigation surfaced a real, independent silent-
// failure gap: DashboardViewModel.load()'s `try? service.fetchFriendActivity(
// ...) ?? .empty` swallowed a thrown fetch-level AppError (exactly the 404 the
// stale deploy actually returned: `{"detail":"Friend not found"}`, from the
// request falling through to the `/{user_id}/{friend_id}` wildcard) with zero
// logging or telemetry, unlike a decode failure (already beaconed since the
// 20260817 notes-load-failure fix). Frontend step 1 added
// NetworkService.reportFetchFailure(endpoint:operation:), wrapping
// fetchFriendActivity's get() call so a thrown fetch error is now logged +
// beaconed via the existing POST /monitoring/client-error mechanism before
// being rethrown (control flow / the `.empty` fallback is unchanged).
//
// Mirrors NotesLoadFailureHardeningTests.swift's approach (exercise the REAL
// NetworkService against a stubbed HTTP layer, not the ThrowingTestDataService
// mock, since the bug and the fix both live in NetworkService's HTTP handling
// itself) and reuses its StubURLProtocol (defined in
// NetworkServiceGetErrorHandlingTests.swift, same test target).
//
// Covers:
//   1. THE REGRESSION ITSELF: a live-incident-shaped 404 (`{"detail":"Friend
//      not found"}`, the exact body backend step 1 observed against the stale
//      deploy) on GET /friends/{userId}/activity still throws (control flow
//      unchanged) AND now fires exactly one client-error beacon — previously
//      zero.
//   2. Same for a 500, proving this isn't 404-specific.
//   3. Happy-path regression guard: a real, non-empty check_in payload decodes
//      correctly and never fires the beacon.
//   4. The true-empty state (200, `friends_active: [], check_in_candidates:
//      []` — a real user with no friends) also never fires the beacon —
//      proving the beacon genuinely distinguishes "the backend said there's
//      nothing to show" from "the request itself failed," which is exactly
//      the distinguishability the architecture step called for.
//
// Updated for task 20260902-dashboard-friend-randomization: the response's
// single `check_in` winner became a `check_in_candidates` list -- test 3's
// stub payload and assertions below were updated to that shape; nothing
// about the beacon logic itself changed.
//   5. End-to-end through the real call path: DashboardViewModel.load() using
//      the real NetworkService still degrades to `.empty` on a fetch failure
//      (row correctly stays hidden, unchanged from before this fix) — but the
//      failure is no longer invisible: the beacon fires. This is the same
//      final on-screen state as the true-empty case (4), but now
//      distinguishable by whoever is triaging a "CheckInRow doesn't show up"
//      report, which is the entire point of this hardening.
//   6. Data-minimization contract carries over unchanged: the beacon body
//      only ever contains endpoint/client_app_version/error_summary, never
//      the raw response body.

import XCTest
@testable import FellowScript

@MainActor
final class CheckInRowFetchFailureHardeningTests: XCTestCase {

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

    /// Same fire-and-forget beacon timing caveat as NotesLoadFailureHardeningTests.
    private func waitForFireAndForgetBeacon() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func friendActivityBeacons() -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter {
            $0.path.contains("/monitoring/client-error") &&
            ($0.bodyJSON?["endpoint"] as? String) == "/friends/{userId}/activity"
        }
    }

    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    // MARK: 1 — THE REGRESSION: live-incident-shaped 404 now beacons

    func test_fetchFriendActivity_liveIncident404_stillThrows_andNowFiresFetchFailureBeacon() async throws {
        StubURLProtocol.stubStatusCode = 404
        // Exact body backend step 1 observed live: the request fell through
        // to the /{user_id}/{friend_id} wildcard route on the stale deploy,
        // treating the literal "activity" segment as a friend_id.
        StubURLProtocol.stubBody = #"{"detail": "Friend not found"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.fetchFriendActivity(userId: "user-123")
            XCTFail("fetchFriendActivity() must still throw on a 404 — this fix must not change control flow")
        } catch {
            if case AppError.networkError(let detail) = error {
                XCTAssertEqual(detail, "Friend not found")
            } else {
                XCTFail("expected AppError.networkError, got \(error)")
            }
        }

        try await waitForFireAndForgetBeacon()
        let beacons = friendActivityBeacons()
        XCTAssertEqual(beacons.count, 1,
                        "a thrown fetch-level error must no longer be silently swallowed -- it must fire exactly one beacon")

        guard let beacon = beacons.first else { return }
        XCTAssertEqual(beacon.method, "POST")
        let body = beacon.bodyJSON
        XCTAssertEqual(body?["endpoint"] as? String, "/friends/{userId}/activity",
                        "endpoint must be the templated path, matching the decode-failure beacon's convention")
        XCTAssertNotNil(body?["client_app_version"] as? String,
                         "must report a client_app_version so a triager can rule in/out a stale-build hypothesis")
        let summary = body?["error_summary"] as? String
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary?.isEmpty ?? true, "error_summary must actually describe the fetch failure, not be blank")
        XCTAssertTrue(summary?.contains("networkError") ?? false,
                      "error_summary should identify the thrown AppError case, got: \(summary ?? "nil")")
    }

    // MARK: 2 — same class of failure, a 500

    func test_fetchFriendActivity_500_stillThrows_andFiresFetchFailureBeacon() async throws {
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail": "Internal Server Error"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.fetchFriendActivity(userId: "user-123")
            XCTFail("fetchFriendActivity() must still throw on a 500")
        } catch {
            // expected
        }

        try await waitForFireAndForgetBeacon()
        XCTAssertEqual(friendActivityBeacons().count, 1,
                        "a 500 must also be beaconed, not just the 404 the live incident happened to produce")
    }

    // MARK: 3 — happy path with a real, non-empty check_in payload

    func test_fetchFriendActivity_decodesRealCheckInPayload_on200_doesNotFireBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "friends_active": [
            {"friend_id": "friend-001", "username": "Sarah", "last_active_at": "2026-08-26T09:14:00Z", "note_preview": null}
          ],
          "check_in_candidates": [{"friend_id": "friend-001", "username": "Sarah", "days_since_contact": 9}]
        }
        """#.data(using: .utf8)!

        let feed = try await NetworkService.shared.fetchFriendActivity(userId: "user-123")

        XCTAssertEqual(feed.friends_active.count, 1)
        XCTAssertEqual(feed.check_in_candidates.count, 1)
        XCTAssertEqual(feed.check_in_candidates.first?.friend_id, "friend-001")
        XCTAssertEqual(feed.check_in_candidates.first?.username, "Sarah")
        XCTAssertEqual(feed.check_in_candidates.first?.days_since_contact, 9)

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(friendActivityBeacons().isEmpty,
                      "a fully successful fetch+decode must never fire the client-error beacon")
    }

    // MARK: 4 — the true-empty state must be distinguishable from a fetch failure

    func test_fetchFriendActivity_trueEmptyState_on200_doesNotFireBeacon() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"friends_active": [], "check_in_candidates": []}"#.data(using: .utf8)!

        let feed = try await NetworkService.shared.fetchFriendActivity(userId: "user-123")

        XCTAssertEqual(feed, FSFriendActivityFeed.empty)

        try await waitForFireAndForgetBeacon()
        XCTAssertTrue(friendActivityBeacons().isEmpty,
                      "a real user with no friends must never trigger the fetch-failure beacon -- " +
                      "only an actual thrown error should (see test 1/2), otherwise the beacon " +
                      "would be noise rather than a real distinguishing signal")
    }

    // MARK: 5 — end to end through DashboardViewModel.load() with the real NetworkService

    func test_dashboardViewModelLoad_realFetchFailure_fallsBackToEmpty_sameAsTrueEmpty_butBeaconDistinguishesThem() async throws {
        StubURLProtocol.stubStatusCode = 404
        StubURLProtocol.stubBody = #"{"detail": "Friend not found"}"#.data(using: .utf8)!

        let vm = DashboardViewModel()
        await vm.load(service: NetworkService.shared, userId: freshUserId())

        // On-screen outcome is unchanged by this fix: CheckInRow still stays
        // hidden exactly as it did before (DashboardView's
        // `if let checkIn = vm.checkInPick` correctly omits it),
        // indistinguishable at the UI layer from a real "no friends" empty
        // state -- this fix does not (and per the architecture step, cannot
        // by itself) change that.
        XCTAssertEqual(vm.friendActivity, FSFriendActivityFeed.empty)
        XCTAssertFalse(vm.isLoading)

        // What's new: the failure is now visible via the beacon, even though
        // the on-screen result is identical to test 4's genuine empty state.
        try await waitForFireAndForgetBeacon()
        XCTAssertEqual(friendActivityBeacons().count, 1,
                        "load()'s real call path (DashboardViewModel -> NetworkService.fetchFriendActivity) " +
                        "must beacon a fetch failure end to end, not just when NetworkService is called directly")
    }

    // MARK: 6 — data minimization carries over unchanged

    func test_fetchFriendActivity_fetchFailureBeacon_neverCarriesRawResponseBody() async throws {
        StubURLProtocol.stubStatusCode = 404
        StubURLProtocol.stubBody = #"{"detail": "Friend not found"}"#.data(using: .utf8)!

        _ = try? await NetworkService.shared.fetchFriendActivity(userId: "user-123")

        try await waitForFireAndForgetBeacon()
        guard let beacon = friendActivityBeacons().first else {
            XCTFail("expected exactly one beacon")
            return
        }
        let allowedKeys: Set<String> = ["endpoint", "client_app_version", "error_summary", "http_status"]
        let actualKeys: Set<String> = Set(beacon.bodyJSON?.keys.map { $0 } ?? [])
        XCTAssertTrue(actualKeys.isSubset(of: allowedKeys),
                      "beacon body must not carry any field beyond the documented minimal set, got keys: \(actualKeys)")
        // The summary legitimately describes the thrown AppError (whose own
        // message is itself derived from the server's `detail` field, same
        // as throwIfError()'s existing mapping) -- that's the intended
        // "what failed" signal, not a leak. What must never happen is the
        // beacon forwarding the raw response body/JSON structure verbatim.
        if let bodyData = beacon.bodyData, let bodyString = String(data: bodyData, encoding: .utf8) {
            XCTAssertFalse(bodyString.contains("\"detail\""),
                            "the beacon must never relay the raw response JSON structure, only the derived typed-error summary")
        }
    }
}
