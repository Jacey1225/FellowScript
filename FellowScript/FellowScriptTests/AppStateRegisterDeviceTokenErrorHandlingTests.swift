// AppStateRegisterDeviceTokenErrorHandlingTests.swift — regression coverage
// for task 20260808-ios-backend-integration-audit, step 17 (backend) / step
// 18 (frontend).
//
// register_device_token (POST /notification/{user_id}/device-token) already
// had correct backend error handling (try/except -> log + rollback +
// HTTPException 500, no false-success — verified by backend step 17), but
// the iOS side had the same class of gap as the rest of this domain:
//   1. NetworkService.registerDeviceToken used unchecked `requestRaw` (no
//      throwIfError), so a real 500 from the server would never surface as
//      a thrown Swift error.
//   2. AppState.registerDeviceToken called it with `try?`, discarding any
//      failure outright.
//
// There is no UI surface at all for this background sync (nothing polls "is
// my token registered?"), so the achievable fix (frontend step 18) was:
// switch to checkedRequestRaw + do/catch with a log line on failure
// (matching the existing "APNs registration failed: ..." convention already
// used elsewhere in this app for the OS-level registration call), rather
// than leaving a failed registration to vanish outright with zero trace.
//
// This test proves registerDeviceToken is actually invoked with the right
// arguments and that a failure does not crash/hang the fire-and-forget Task
// — the ThrowingTestDataService seam's call-count/error-injection exactly
// models what checkedRequestRaw now produces post-fix (throws instead of
// silently returning on a server rejection).

import XCTest
@testable import FellowScript

@MainActor
final class AppStateRegisterDeviceTokenErrorHandlingTests: XCTestCase {

    private func makeSignedInAppState(service: ThrowingTestDataService) -> AppState {
        let appState = AppState(service: service)
        appState.currentUser = FSUser(user_id: "user-123", username: "alice", email: "alice@example.com")
        appState.isAuthenticated = true
        return appState
    }

    /// Happy path: registerDeviceToken(_:) must actually call through to the
    /// service with the signed-in user's id and the given token.
    func test_registerDeviceToken_callsService_withCorrectArgs() async throws {
        let service = ThrowingTestDataService()
        let appState = makeSignedInAppState(service: service)

        appState.registerDeviceToken("apns-token-abc")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(service.registerDeviceTokenCallCount, 1)
        XCTAssertEqual(service.lastRegisterDeviceTokenArgs?.userId, "user-123")
        XCTAssertEqual(service.lastRegisterDeviceTokenArgs?.token, "apns-token-abc")
    }

    /// A rejected/failed registration (the now-checked path) must not crash
    /// or hang the app — the fire-and-forget Task's do/catch must absorb it.
    /// Before the fix, `try?` did the same "don't crash" job but with zero
    /// trace whatsoever; after the fix there's at least a log line, but the
    /// key regression-guard behavior a unit test can assert is that calling
    /// this with a failing service completes cleanly and still recorded the
    /// attempt (proving the call wasn't skipped).
    func test_registerDeviceToken_doesNotCrash_whenServerCallFails() async throws {
        let service = ThrowingTestDataService()
        service.registerDeviceTokenError = AppError.networkError("Failed to save token")
        let appState = makeSignedInAppState(service: service)

        appState.registerDeviceToken("apns-token-xyz")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(service.registerDeviceTokenCallCount, 1,
                        "the failing registration attempt must still have been made, not skipped")
        XCTAssertEqual(service.lastRegisterDeviceTokenArgs?.token, "apns-token-xyz")
        // No crash/hang reaching this point is itself the assertion that
        // matters most for a fire-and-forget path with no UI surface.
    }

    /// Guard clause regression: with no signed-in user, registerDeviceToken
    /// must be a no-op and never call the service.
    func test_registerDeviceToken_isNoOp_whenNotSignedIn() async throws {
        let service = ThrowingTestDataService()
        let appState = AppState(service: service)
        appState.currentUser = nil

        appState.registerDeviceToken("apns-token-should-not-send")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(service.registerDeviceTokenCallCount, 0)
    }
}
