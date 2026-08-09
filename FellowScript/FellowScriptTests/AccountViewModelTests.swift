// AccountViewModelTests.swift — regression coverage for
// task: 20260808-timezone-display-stale-utc.
//
// The intake spec's root-cause diagnosis draws a specific line: the ViewModel
// side (`AccountViewModel.load` populating `vm.profileData` from a real
// backend fetch) was ALWAYS correct; the bug was entirely in AccountView's
// `.task` block reading a stale, pre-fetch `appState.currentUser` snapshot
// instead of that freshly-fetched `vm.profileData`. These unit tests prove
// the ViewModel half of that story directly and fast (no simulator UI
// needed): `load()` must end up with `profileData.timezone` set to the
// backend's real, freshly-fetched value — not whatever pre-fetch snapshot
// was passed in as the `user:` argument. This is exactly the value
// AccountView's `.task` now reads from (see AccountUITests.swift's
// `test_timezoneRow_showsFreshlyFetchedValue_notStalePreFetchSnapshot` for
// the end-to-end proof that the View itself displays it correctly).

import XCTest
@testable import FellowScript

@MainActor
final class AccountViewModelTests: XCTestCase {

    /// MockDataService.fetchUser intentionally returns a different timezone
    /// (`mockFetchedTimezone`, "America/Los_Angeles") than `mockUser`'s
    /// Codable default ("UTC") — the same seam AccountUITests relies on to
    /// distinguish "the stale pre-fetch snapshot" from "the freshly-fetched
    /// profile" for this exact bug.
    func test_load_populatesProfileData_withFreshlyFetchedTimezone_notPreFetchSnapshot() async {
        let vm = AccountViewModel()

        // The pre-fetch snapshot handed to `load(user:)` — mirrors
        // `appState.currentUser` on a cold launch: username/email are real,
        // but timezone is still at the Codable placeholder default because
        // it was never refreshed from the backend.
        let preFetchSnapshot = FSUser(
            user_id: MockDataService.mockUser.user_id,
            username: MockDataService.mockUser.username,
            email: MockDataService.mockUser.email
        )
        XCTAssertEqual(preFetchSnapshot.timezone, "UTC",
                        "sanity check: the pre-fetch snapshot must start at the Codable default, matching a real cold-launch appState.currentUser")

        await vm.load(service: MockDataService.shared, user: preFetchSnapshot)

        XCTAssertEqual(vm.profileData?.timezone, MockDataService.mockFetchedTimezone,
                        "vm.profileData must be populated from the real, freshly-fetched profile (MockDataService.fetchUser), not left at the pre-fetch snapshot's default")
        XCTAssertNotEqual(vm.profileData?.timezone, preFetchSnapshot.timezone,
                           "the freshly-fetched timezone must differ from (and take priority over) the stale pre-fetch snapshot's value")

        // Regression guard: username/email must still come through correctly
        // alongside the timezone fix.
        XCTAssertEqual(vm.profileData?.username, MockDataService.mockUser.username)
        XCTAssertEqual(vm.profileData?.email, MockDataService.mockUser.email)
    }
}
