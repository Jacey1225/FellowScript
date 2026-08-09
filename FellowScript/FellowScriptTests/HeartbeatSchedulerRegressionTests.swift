// HeartbeatSchedulerRegressionTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, backend step 11 finding #1 /
// frontend step 12 fix — likely the audit's single highest-impact finding.
//
// Before the fix, HeartbeatScheduler.checkAndFire (Account/HeartbeatScheduler.swift)
// did `let result = try? await service.commitHeartbeat(...)` then
// `guard result != nil else { continue }`. The backend's commit_hb_response
// always returns HTTP 200 whether the heartbeat actually fired or not —
// {"success": "..."} on a real fire, but {"error": "..."} (LLM/JSON failure)
// or {"skipped": "..."} (already claimed within the last 2 minutes) are
// equally valid all-string dicts that decode fine into [String: String]. A
// bare `result != nil` check treated all three as success, which both
// suppressed any retry (by marking the event as fired in UserDefaults) AND
// fired a false "Event Response Saved" local notification even though
// nothing was actually saved.
//
// The fix changed the guard to `result?["success"] != nil`.
//
// This proves, using the ThrowingTestDataService controllable seam
// (commitHeartbeatResult / commitHeartbeatError), that:
//   1. A {"success": ...} result marks the event as fired (a second
//      checkAndFire call for the same still-due event does NOT call
//      commitHeartbeat again).
//   2. A {"error": ...} result does NOT mark the event as fired (a second
//      checkAndFire call retries — commitHeartbeat is called again).
//   3. A {"skipped": ...} result also does NOT mark the event as fired.
//   4. A thrown network error (the `try?` still swallows this, matching the
//      pre-fix behavior for genuine transport failures, which is correct —
//      only a decoded-but-non-"success" body is the bug this fix targets)
//      likewise does not mark the event fired.
//
// UserDefaults.standard is the real backing store HeartbeatScheduler uses
// (`fs_hb_last_fired`); each test clears that key before and after to avoid
// cross-test/cross-run pollution.
//
// Verified here via `swiftc -parse` only — no Xcode/simulator available in
// this environment (xcodebuild/xcrun simctl absent, same constraint noted by
// steps 3/4/6/7/9/10/12). Run with `xcodebuild test` once Xcode is available.

import XCTest
@testable import FellowScript

final class HeartbeatSchedulerRegressionTests: XCTestCase {

    private let lastFiredKey = "fs_hb_last_fired"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: lastFiredKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: lastFiredKey)
        super.tearDown()
    }

    /// A heartbeat event whose most recent scheduled fire time (yesterday at
    /// noon UTC) is always in the past relative to "now", regardless of what
    /// time this test happens to run — avoids flakiness near local midnight
    /// that a "today" timestamp would risk.
    private func makeDueEvent() -> FSHeartbeat {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let yesterday = utcCal.date(byAdding: .day, value: -1, to: Date())!
        let day = utcCal.component(.day, from: yesterday)

        var timestamps: [String?] = Array(repeating: nil, count: 31)
        timestamps[day - 1] = "12:00"

        return FSHeartbeat(id: "hb-\(UUID().uuidString)", agent_id: "agent-1",
                            user_id: "user-1", timestamps: timestamps, prompt: "Reflect on today.")
    }

    // MARK: 1 — {"success": ...} marks the event fired (no duplicate call)

    func test_successResult_marksEventFired_secondCheckDoesNotRetry() async {
        let service = ThrowingTestDataService()
        service.commitHeartbeatResult = ["success": "saved note"]
        let event = makeDueEvent()

        await HeartbeatScheduler.checkAndFire(userId: "user-1", events: [event], service: service)
        XCTAssertEqual(service.commitHeartbeatCallCount, 1, "first check should fire the due event exactly once")

        // Second check for the same still-due event must NOT retry — success
        // marks the event fired.
        await HeartbeatScheduler.checkAndFire(userId: "user-1", events: [event], service: service)
        XCTAssertEqual(service.commitHeartbeatCallCount, 1,
                        "a successfully-fired event must not be retried on a subsequent check")
    }

    // MARK: 2 — {"error": ...} does NOT mark fired (bug this fix targets)

    func test_errorResult_doesNotMarkEventFired_retriesOnNextCheck() async {
        let service = ThrowingTestDataService()
        service.commitHeartbeatResult = ["error": "invalid response"]
        let event = makeDueEvent()

        await HeartbeatScheduler.checkAndFire(userId: "user-1", events: [event], service: service)
        XCTAssertEqual(service.commitHeartbeatCallCount, 1)

        // Before the fix: `result != nil` was true even for {"error": ...},
        // so the event got marked fired and this second call would NOT have
        // retried. After the fix: not marked fired -> retries.
        await HeartbeatScheduler.checkAndFire(userId: "user-1", events: [event], service: service)
        XCTAssertEqual(service.commitHeartbeatCallCount, 2,
                        "an {\"error\": ...} result must not suppress retry — before the fix, " +
                        "`result != nil` treated this as success and silently blocked the next attempt " +
                        "until the following scheduled day")
    }

    // MARK: 3 — {"skipped": ...} does NOT mark fired

    func test_skippedResult_doesNotMarkEventFired_retriesOnNextCheck() async {
        let service = ThrowingTestDataService()
        service.commitHeartbeatResult = ["skipped": "already fired recently"]
        let event = makeDueEvent()

        await HeartbeatScheduler.checkAndFire(userId: "user-1", events: [event], service: service)
        XCTAssertEqual(service.commitHeartbeatCallCount, 1)

        await HeartbeatScheduler.checkAndFire(userId: "user-1", events: [event], service: service)
        XCTAssertEqual(service.commitHeartbeatCallCount, 2,
                        "a {\"skipped\": ...} result must not be treated as a successful fire either")
    }

    // MARK: 4 — a thrown network error also does not mark fired (regression guard)

    func test_thrownError_doesNotMarkEventFired() async {
        let service = ThrowingTestDataService()
        service.commitHeartbeatError = AppError.networkError("offline")
        let event = makeDueEvent()

        await HeartbeatScheduler.checkAndFire(userId: "user-1", events: [event], service: service)
        XCTAssertEqual(service.commitHeartbeatCallCount, 1)

        await HeartbeatScheduler.checkAndFire(userId: "user-1", events: [event], service: service)
        XCTAssertEqual(service.commitHeartbeatCallCount, 2,
                        "a genuine network failure must not mark the event fired either — this was " +
                        "already correct pre-fix (try? -> nil -> guard fails) and must not regress")
    }
}
