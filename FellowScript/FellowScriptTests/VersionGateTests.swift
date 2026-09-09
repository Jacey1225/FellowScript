// VersionGateTests.swift — regression coverage for
// task: 20260909-ios-version-gate-popup, testing step (3), covering frontend
// step 1's VersionGateService.swift + StartupCoordinator.swift wiring and
// security step 2's trusted-store-host hardening.
//
// Per the write-tests skill ("test only manager/service logic — not UI
// layout") and this repo's existing StartupCoordinatorTests.swift precedent
// (which tests `isReady` as the proxy for "mainTabView shown", never
// ContentView's actual SwiftUI body), this file tests the two pieces of
// STATE that drive whether UpdateNudgeView is ever presented:
//   - VersionGateService.checkForUpdate()'s return value (nil vs.
//     AppUpdateInfo), exercised against the real service via a stubbed
//     URLSession (matching NetworkServiceGetErrorHandlingTests.swift's
//     StubURLProtocol convention) rather than mocking the service away —
//     the bug class this guards against lives in VersionGateService's own
//     parsing/comparison/trust logic, not in a mock.
//   - StartupCoordinator.updateAvailable, which ContentView's
//     `.sheet(item:)` binds to directly (see ContentView.swift) — proven via
//     `start()`'s injectable `versionCheck` closure, the same DI seam
//     `service:` already uses for notesVM/bibleVM/chatVM.
//
// Covers the three acceptance criteria from intake-spec.md's regression-test
// bullet:
//   1. Current/up-to-date version -> no popup (updateAvailable stays nil).
//   2. Outdated version -> popup shown (updateAvailable populated).
//   3. Check failure/timeout -> never blocks or crashes launch (isReady
//      still flips on schedule, updateAvailable simply stays nil).
// Plus VersionGateService's own fail-open contract at every failure mode
// (offline/error, non-200, empty results, malformed JSON, untrusted store
// host) and StartupCoordinator's dismiss/reset lifecycle for the nudge.

import XCTest
@testable import FellowScript

// MARK: - VersionGateService: real parsing/comparison/trust logic against a stubbed network

/// Intercepts only requests to itunes.apple.com. Registered per-test on an
/// isolated `URLSessionConfiguration` (via VersionGateService.checkForUpdate's
/// injectable `session:` parameter) rather than globally with
/// `URLProtocol.registerClass`, so this can never interfere with
/// NetworkServiceGetErrorHandlingTests.swift's own StubURLProtocol (scoped to
/// fellowscript.com) or any other test's networking.
final class ITunesLookupStubURLProtocol: URLProtocol {
    static var stubStatusCode = 200
    static var stubBody: Data = Data()
    static var stubError: Error?

    static func reset() {
        stubStatusCode = 200
        stubBody = Data()
        stubError = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "itunes.apple.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stubError = Self.stubError {
            client?.urlProtocol(self, didFailWithError: stubError)
            return
        }
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

/// A `Bundle` double exposing only the two properties
/// VersionGateService.checkForUpdate() actually reads (`bundleIdentifier`,
/// `infoDictionary`'s `CFBundleShortVersionString`) — this is exactly the
/// seam frontend step 1 added the `bundle:` parameter for (see
/// VersionGateService.swift's doc comment), so both the "current version"
/// and "outdated version" scenarios can be driven deterministically without
/// depending on whatever MARKETING_VERSION this test target happens to ship
/// with.
private final class FakeAppBundle: Bundle {
    private let fakeBundleId: String?
    private let fakeVersion: String?

    init(bundleId: String?, version: String?) {
        self.fakeBundleId = bundleId
        self.fakeVersion = version
        super.init()
    }

    override var bundleIdentifier: String? { fakeBundleId }

    override var infoDictionary: [String: Any]? {
        guard let fakeVersion else { return [:] }
        return ["CFBundleShortVersionString": fakeVersion]
    }
}

private func stubbedLookupSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ITunesLookupStubURLProtocol.self]
    return URLSession(configuration: config)
}

private let trustedStoreURL = "https://apps.apple.com/us/app/fellowscript/id123456789"

final class VersionGateServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ITunesLookupStubURLProtocol.reset()
    }

    // MARK: 1 — up-to-date installed version: no popup

    func test_checkForUpdate_installedVersionMatchesLatest_returnsNil() async {
        ITunesLookupStubURLProtocol.stubStatusCode = 200
        ITunesLookupStubURLProtocol.stubBody = #"""
        {"results": [{"version": "2.9.1", "trackViewUrl": "\#(trustedStoreURL)"}]}
        """#.data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "installed == latest must never report an update -- this is the 'no popup on current version' acceptance criterion")
    }

    func test_checkForUpdate_installedVersionAheadOfLatest_returnsNil() async {
        // Defensive: a TestFlight/beta build ahead of what's live on the
        // Store must not be told to "update" to an older version.
        ITunesLookupStubURLProtocol.stubStatusCode = 200
        ITunesLookupStubURLProtocol.stubBody = #"""
        {"results": [{"version": "2.9.0", "trackViewUrl": "\#(trustedStoreURL)"}]}
        """#.data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update)
    }

    // MARK: 2 — outdated installed version: popup shown

    func test_checkForUpdate_installedVersionBehindLatest_returnsUpdateInfo() async {
        ITunesLookupStubURLProtocol.stubStatusCode = 200
        ITunesLookupStubURLProtocol.stubBody = #"""
        {"results": [{"version": "3.0.0", "trackViewUrl": "\#(trustedStoreURL)"}]}
        """#.data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertEqual(update?.latestVersion, "3.0.0", "an outdated installed version must report the confirmed newer version -- this is the 'popup shown' acceptance criterion")
        XCTAssertEqual(update?.storeURL.absoluteString, trustedStoreURL, "storeURL must come straight from the Lookup API's own trackViewUrl")
    }

    // MARK: 3 — check failure/timeout: fails open, never throws/crashes

    func test_checkForUpdate_networkError_failsOpen_returnsNil() async {
        ITunesLookupStubURLProtocol.stubError = URLError(.notConnectedToInternet)
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "offline must fail open (nil), never throw uncaught or crash")
    }

    func test_checkForUpdate_timeout_failsOpen_returnsNil() async {
        ITunesLookupStubURLProtocol.stubError = URLError(.timedOut)
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "a timed-out lookup must fail open (nil), never throw uncaught or crash")
    }

    func test_checkForUpdate_non200Status_failsOpen_returnsNil() async {
        ITunesLookupStubURLProtocol.stubStatusCode = 500
        ITunesLookupStubURLProtocol.stubBody = #"{"detail": "Internal Server Error"}"#.data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "a non-200 response must fail open (nil), not throw or crash")
    }

    func test_checkForUpdate_malformedJSON_failsOpen_returnsNil() async {
        ITunesLookupStubURLProtocol.stubStatusCode = 200
        ITunesLookupStubURLProtocol.stubBody = "not json at all".data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "an unparseable body must fail open (nil), not throw or crash")
    }

    func test_checkForUpdate_emptyResults_failsOpen_returnsNil() async {
        ITunesLookupStubURLProtocol.stubStatusCode = 200
        ITunesLookupStubURLProtocol.stubBody = #"{"results": []}"#.data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "an empty results array (e.g. bundle id not found on the Store) must fail open, not crash on results.first!")
    }

    func test_checkForUpdate_missingBundleIdentifier_failsOpen_returnsNil() async {
        ITunesLookupStubURLProtocol.stubStatusCode = 200
        ITunesLookupStubURLProtocol.stubBody = #"""
        {"results": [{"version": "3.0.0", "trackViewUrl": "\#(trustedStoreURL)"}]}
        """#.data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: nil, version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "a missing bundle identifier must fail open before ever making a request, not crash")
    }

    // MARK: Security hardening (security step 2) — untrusted trackViewUrl host

    func test_checkForUpdate_untrustedStoreHost_failsOpen_returnsNil() async {
        // A malformed/unexpected response claims a newer version is
        // available, but points "Update Now" at a non-Apple host --
        // isTrustedStoreURL must reject this before AppUpdateInfo is ever
        // constructed, so UpdateNudgeView's openURL(update.storeURL) can
        // never be steered off Apple's own domains.
        ITunesLookupStubURLProtocol.stubStatusCode = 200
        ITunesLookupStubURLProtocol.stubBody = #"""
        {"results": [{"version": "3.0.0", "trackViewUrl": "https://evil.example.com/app"}]}
        """#.data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "an untrusted trackViewUrl host must fail open (nil) rather than surface a popup pointing off Apple's domains")
    }

    func test_checkForUpdate_nonHTTPSStoreURL_failsOpen_returnsNil() async {
        ITunesLookupStubURLProtocol.stubStatusCode = 200
        ITunesLookupStubURLProtocol.stubBody = #"""
        {"results": [{"version": "3.0.0", "trackViewUrl": "http://apps.apple.com/us/app/fellowscript/id123456789"}]}
        """#.data(using: .utf8)!
        let bundle = FakeAppBundle(bundleId: "com.fellowscript.app", version: "2.9.1")

        let update = await VersionGateService.checkForUpdate(session: stubbedLookupSession(), bundle: bundle)

        XCTAssertNil(update, "a non-https trackViewUrl must fail open (nil), even on an otherwise-trusted host")
    }

    // MARK: isNewer — pure dotted-version comparison

    func test_isNewer_higherMinorVersion_isTrue() {
        XCTAssertTrue(VersionGateService.isNewer("2.10.0", than: "2.9.1"))
    }

    func test_isNewer_sameVersion_isFalse() {
        XCTAssertFalse(VersionGateService.isNewer("2.9.1", than: "2.9.1"))
    }

    func test_isNewer_lowerVersion_isFalse() {
        XCTAssertFalse(VersionGateService.isNewer("2.9.0", than: "2.9.1"))
    }

    func test_isNewer_differingComponentCounts_padsWithZero() {
        XCTAssertTrue(VersionGateService.isNewer("3.0", than: "2.9.1"))
        XCTAssertFalse(VersionGateService.isNewer("2.9", than: "2.9.0.1"))
    }
}

// MARK: - StartupCoordinator wiring: updateAvailable is what ContentView's sheet(item:) binds to

@MainActor
final class StartupCoordinatorVersionGateTests: XCTestCase {

    private func freshUserId() -> String { "user-\(UUID().uuidString)" }

    private func waitUntilReady(_ coordinator: StartupCoordinator, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if coordinator.isReady { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return coordinator.isReady
    }

    private func waitUntilUpdateAvailable(_ coordinator: StartupCoordinator, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if coordinator.updateAvailable != nil { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return coordinator.updateAvailable != nil
    }

    // MARK: 1 — outdated version: updateAvailable populated (popup shown)

    func test_start_versionCheckReportsUpdate_populatesUpdateAvailable() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()
        let update = AppUpdateInfo(latestVersion: "3.0.0", storeURL: URL(string: trustedStoreURL)!)

        coordinator.start(service: service, userId: freshUserId(), versionCheck: { update })

        let gotUpdate = await waitUntilUpdateAvailable(coordinator, timeout: 3)
        XCTAssertTrue(gotUpdate, "a confirmed newer version must populate updateAvailable -- ContentView's .sheet(item:) binds to exactly this")
        XCTAssertEqual(coordinator.updateAvailable?.latestVersion, "3.0.0")
    }

    // MARK: 2 — current version: updateAvailable stays nil (no popup)

    func test_start_versionCheckReportsNoUpdate_updateAvailableStaysNil() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()

        coordinator.start(service: service, userId: freshUserId(), versionCheck: { nil })

        _ = await waitUntilReady(coordinator, timeout: 3)
        // The version check is deliberately not part of the readiness race
        // (see StartupCoordinator.start()) -- give its own independent Task
        // a moment to actually run before asserting it never set anything.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(coordinator.updateAvailable, "an up-to-date installed version must never populate updateAvailable -- no popup must appear")
    }

    // MARK: 3 — check failure/hang: never blocks readiness, never crashes, no popup

    func test_start_versionCheckHangs_doesNotBlockReadiness_andShowsNoPopup() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()

        // Long enough that it could never win the readiness race if it were
        // (wrongly) coupled to it -- mirrors VersionGateService.checkForUpdate's
        // own fail-open contract for a stalled/hung lookup.
        coordinator.start(service: service, userId: freshUserId(), versionCheck: {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return nil
        })

        let becameReady = await waitUntilReady(coordinator, timeout: 3)

        XCTAssertTrue(becameReady, "a slow/hung version check must never delay isReady -- it runs in its own independent Task, not the readiness race")
        XCTAssertNil(coordinator.updateAvailable, "while the version check hasn't resolved yet, no popup must be shown")
    }

    // MARK: Dismiss / reset lifecycle

    func test_dismissUpdateNudge_clearsUpdateAvailable() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()
        let update = AppUpdateInfo(latestVersion: "3.0.0", storeURL: URL(string: trustedStoreURL)!)

        coordinator.start(service: service, userId: freshUserId(), versionCheck: { update })
        _ = await waitUntilUpdateAvailable(coordinator, timeout: 3)
        XCTAssertNotNil(coordinator.updateAvailable)

        coordinator.dismissUpdateNudge()

        XCTAssertNil(coordinator.updateAvailable, "dismissUpdateNudge() (Update Now / Not Now / swipe-away, all routed through ContentView's sheet binding) must clear the nudge")
    }

    func test_reset_clearsUpdateAvailable() async {
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()
        let update = AppUpdateInfo(latestVersion: "3.0.0", storeURL: URL(string: trustedStoreURL)!)

        coordinator.start(service: service, userId: freshUserId(), versionCheck: { update })
        _ = await waitUntilUpdateAvailable(coordinator, timeout: 3)
        XCTAssertNotNil(coordinator.updateAvailable)

        coordinator.reset()

        XCTAssertNil(coordinator.updateAvailable, "reset() (sign-out) must clear any pending update nudge along with the rest of startup state")
    }

    func test_start_calledTwice_secondVersionCheckNeverRuns() async {
        // Mirrors StartupCoordinatorTests.swift's existing
        // test_start_calledTwice_doesNotRefetch -- the version check must
        // respect the same `started` idempotency guard as notes/bible/chat:
        // the second start() call's versionCheck closure must never even
        // run (the `guard !started else { return }` returns before any
        // Task, including the version-check one, is spawned).
        let service = ThrowingTestDataService()
        let coordinator = StartupCoordinator()
        let userId = freshUserId()
        let firstUpdate = AppUpdateInfo(latestVersion: "3.0.0", storeURL: URL(string: trustedStoreURL)!)

        coordinator.start(service: service, userId: userId, versionCheck: { firstUpdate })
        // If the guard ever regressed and let a second start() re-run,
        // returning a DIFFERENT update here would either overwrite
        // updateAvailable or (once XCTFail fires) prove it ran at all.
        coordinator.start(service: service, userId: userId, versionCheck: {
            XCTFail("a second start() call while already started must not run the version check again")
            return nil
        })

        _ = await waitUntilUpdateAvailable(coordinator, timeout: 3)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(coordinator.updateAvailable?.latestVersion, "3.0.0",
                        "only the first start() call's version check must have run")
    }
}
