// NetworkServiceReportSummarizeFailureBeaconTests.swift -- testing-gate coverage for
// task 20260915-session-summary-min-transcript-and-error-classes (fix 3).
// NetworkService.reportSummarizeFailure must POST /monitoring/client-error with
// kind="summarize" and only fixed strings (stage + errorClass), never user content.

import XCTest
@testable import FellowScript

final class NetworkServiceReportSummarizeFailureBeaconTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        try await Task.sleep(nanoseconds: 700_000_000)
        StubURLProtocol.resetRequestLog()
    }

    private func beaconRequests() -> [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requestLog.filter { $0.path.contains("/monitoring/client-error") }
    }

    private func waitForBeacon(timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while beaconRequests().isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func test_reportSummarizeFailure_postsSummarizeKindWithFixedStrings() async throws {
        StubURLProtocol.stubStatusCode = 204
        StubURLProtocol.stubBody = Data()

        NetworkService.shared.reportSummarizeFailure(
            stage: "summarize-request", errorClass: "no-summarizable-content-422")

        await waitForBeacon()
        let beacons = beaconRequests()
        XCTAssertEqual(beacons.count, 1, "exactly one beacon per reported failure")
        let body = beacons.first?.bodyJSON
        XCTAssertEqual(beacons.first?.method, "POST")
        XCTAssertEqual(body?["kind"] as? String, "summarize",
                       "THE FIX: summarize failures carry kind=summarize so the server logs CLIENT_SUMMARIZE_FAILURE, not a decode failure")
        XCTAssertEqual(body?["endpoint"] as? String, "POST /agent/{user_id}/{agent_id}/summarize")
        XCTAssertEqual(body?["error_summary"] as? String,
                       "stage=summarize-request errorClass=no-summarizable-content-422")
        let allowed: Set<String> = ["endpoint", "client_app_version", "error_summary", "http_status", "kind"]
        XCTAssertTrue(Set(body?.keys.map { $0 } ?? []).isSubset(of: allowed),
                      "no field beyond the minimal documented set may be sent")
    }

    func test_reportSummarizeFailure_serverRejection_neverThrowsOrCrashes() async throws {
        StubURLProtocol.stubStatusCode = 429
        StubURLProtocol.stubBody = #"{"detail":"rate limited"}"#.data(using: .utf8)!
        NetworkService.shared.reportSummarizeFailure(stage: "resolve-agent", errorClass: "URLError")
        await waitForBeacon()
        XCTAssertEqual(beaconRequests().count, 1, "fire-and-forget: a failing beacon is simply dropped")
    }
}
