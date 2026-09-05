// HeartbeatTimezoneDuplicateBugsRegressionTests.swift — regression coverage
// for task 20260905-heartbeat-timezone-duplicate-bugs, testing step 5
// (frontend steps 3-4: EventSetupSheet.swift's iOS-side fixes for both bugs).
//
// Bug 1 (timezone mismatch): EventSetupSheet.swift's `buildTimestamps()`
// (save) and `prefill(from:)` (edit-reload) used to hardcode
// `TimeZone(identifier: "UTC")`, causing a locally-picked wall-clock time to
// be authored/read as if it were UTC -- the exact mismatch that made a 9:00
// AM pick fire hours off, since the backend (since
// 20260901-heartbeat-backend-scheduling) already interprets `timestamps` as
// literal local time in the owning user's `users.timezone`. The fix removes
// both UTC overrides in favor of `TimeZone.current`. `buildTimestamps()` and
// `prefill(from:)` are private methods on a SwiftUI View struct with no
// ViewInspector dependency in this project, so direct unit invocation isn't
// available -- this suite proves the fix two ways, matching this project's
// existing precedent (InteractionPolishSharedMechanismsTests.swift) for
// verifying SwiftUI view internals that can't be driven directly:
//
//   1. A source-scan confirming EventSetupSheet.swift's actual save/reload
//      code paths no longer construct `TimeZone(identifier: "UTC")`
//      anywhere, and both `buildTimestamps()` and `prefill(from:)` are
//      wired to `TimeZone.current` instead -- a regression back to the old
//      hardcoded UTC override would fail this test immediately.
//   2. A mechanism test reproducing the EXACT DateFormatter configuration
//      (`"HH:mm"` + `TimeZone.current`) the fixed code now uses, proving the
//      underlying round-trip (Date -> "HH:mm" string -> Date) preserves the
//      picked wall-clock digits with no drift -- the same guarantee
//      `prefill(from:)` relies on to redisplay a saved time unchanged.
//
// Bug 2 (duplicate rows): `EventSetupSheet`'s Save/Update action now gates
// on a new `isSaving` in-flight flag and threads a freshly generated
// `idempotencyKey` (one UUID per Save tap) through `onSave` ->
// `AccountViewModel.createEvent` -> `DataServiceProtocol.addHeartbeat`, per
// the server-side idempotency_key + UNIQUE index guarantee added in backend
// step 2. This suite proves:
//
//   3. A source-scan confirming the in-flight guard (`guard !isSaving else
//      { return }` before dispatching `onSave`, and `.disabled(isSaving...)`
//      on the button) is actually present at the real Save/Update call
//      site -- not just described in a comment.
//   4. A source-scan confirming a fresh `UUID().uuidString` is generated
//      once per Save tap and passed as the final `onSave` argument -- not a
//      fixed/reused token.
//   5. `AccountViewModel.createEvent(idempotencyKey:)` forwards whatever key
//      it's given all the way to `DataServiceProtocol.addHeartbeat`
//      unchanged (using ThrowingTestDataService's
//      `lastAddHeartbeatIdempotencyKey` capture seam from
//      AppStateAuthAccountTests.swift) -- proving the plumbing from the
//      ViewModel down to the network layer is intact, which is the one
//      link in the chain a pure source-scan can't verify.
//   6. Omitting `idempotencyKey` (the default parameter) forwards `nil` to
//      the service, not a ViewModel-invented placeholder -- confirming
//      EventSetupSheet's per-tap UUID is the ONLY source of this token, so
//      two independent Save dispatches can never accidentally coincide on
//      the same key via some shared ViewModel-level default.

import XCTest
@testable import FellowScript

@MainActor
final class HeartbeatTimezoneDuplicateBugsRegressionTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func makeProfile() -> FSUser {
        FSUser(user_id: MockDataService.mockUser.user_id,
               username: MockDataService.mockUser.username,
               email: MockDataService.mockUser.email)
    }

    // MARK: Bug 1 — 1. No hardcoded UTC override remains anywhere in the file

    func test_eventSetupSheet_noLongerHardcodesUTCTimeZone() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertFalse(
            source.contains(#"TimeZone(identifier: "UTC")"#),
            "EventSetupSheet.swift must not construct a hardcoded UTC TimeZone anywhere -- "
            + "that was the exact double-conversion bug (task 20260905-heartbeat-timezone-duplicate-bugs); "
            + "timestamps must be authored/read as the device's own local wall-clock time"
        )
    }

    // MARK: Bug 1 — 2. buildTimestamps() and prefill(from:) both use TimeZone.current

    func test_buildTimestamps_and_prefill_bothUseDeviceLocalTimeZone() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        guard let buildRange = source.range(of: "private func buildTimestamps() -> [String?] {"),
              let prefillRange = source.range(of: "private func prefill(from hb: FSHeartbeat) {") else {
            XCTFail("could not locate buildTimestamps()/prefill(from:) in EventSetupSheet.swift")
            return
        }
        // Each function's body is a short, self-contained block -- slicing a
        // generous fixed window after each declaration is enough to capture
        // its own `f.timeZone = ...` assignment without accidentally reading
        // into an unrelated function.
        let buildBody = source[buildRange.lowerBound...].prefix(1200)
        let prefillBody = source[prefillRange.lowerBound...].prefix(1200)

        XCTAssertTrue(buildBody.contains("f.timeZone = TimeZone.current"),
                      "buildTimestamps() must format the picked time using the device's own "
                      + "local TimeZone.current, matching the backend's local-to-users.timezone interpretation")
        XCTAssertTrue(prefillBody.contains("f.timeZone = TimeZone.current"),
                      "prefill(from:) must parse the stored 'HH:mm' string using TimeZone.current "
                      + "so an edited/reloaded event redisplays the same local wall-clock time it was saved with")
    }

    // MARK: Bug 1 — 3. Mechanism round-trip: the exact DateFormatter recipe
    // the fixed code now uses preserves wall-clock digits with no drift.

    func test_localTimeZoneHHmmRoundTrip_preservesWallClockDigitsWithNoDrift() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current

        for (hour, minute) in [(9, 0), (0, 0), (23, 59), (13, 45)] {
            var comps = DateComponents()
            comps.year = 2026; comps.month = 9; comps.day = 15
            comps.hour = hour; comps.minute = minute
            guard let original = Calendar.current.date(from: comps) else {
                XCTFail("failed to construct fixture date for \(hour):\(minute)")
                continue
            }
            // Save: Date -> "HH:mm" string (what buildTimestamps() now does).
            let stored = formatter.string(from: original)
            let expected = String(format: "%02d:%02d", hour, minute)
            XCTAssertEqual(stored, expected,
                           "authoring \(hour):\(minute) must store the literal local digits unchanged")

            // Reload: "HH:mm" string -> Date -> re-extracted wall-clock components
            // (what prefill(from:) now does, followed by the DatePicker reading it back).
            guard let reparsed = formatter.date(from: stored) else {
                XCTFail("failed to reparse stored value '\(stored)'")
                continue
            }
            let reparsedComps = Calendar.current.dateComponents([.hour, .minute], from: reparsed)
            XCTAssertEqual(reparsedComps.hour, hour,
                           "reloading '\(stored)' must redisplay hour \(hour) with no drift")
            XCTAssertEqual(reparsedComps.minute, minute,
                           "reloading '\(stored)' must redisplay minute \(minute) with no drift")
        }
    }

    // MARK: Bug 2 — 4. In-flight guard is present at the real Save/Update call site

    func test_eventSetupSheet_hasInFlightSaveGuard() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains("guard !isSaving else { return }"),
                      "the Save/Update action must bail out immediately if a save is already "
                      + "in flight for this attempt, so a rapid double-tap can't dispatch onSave twice")
        XCTAssertTrue(source.contains("isSaving = true"),
                      "the Save/Update action must set isSaving before dispatching onSave")
        XCTAssertTrue(source.contains(".disabled(isSaving"),
                      "the Save/Update PillButton must be disabled while isSaving is true, "
                      + "as a visible complementary guard alongside the guard-return above")
    }

    // MARK: Bug 2 — 5. A fresh idempotency token is generated once per Save tap

    func test_eventSetupSheet_generatesFreshIdempotencyKeyPerSaveTap() throws {
        let source = try readSource("FellowScript/Account/EventSetupSheet.swift")
        XCTAssertTrue(source.contains("let idempotencyKey = UUID().uuidString"),
                      "a fresh UUID must be generated once per Save tap and threaded through onSave -- "
                      + "not a fixed/reused token, and not regenerated on every internal recomputation")
        // The generated key must actually be passed as the trailing onSave argument,
        // not merely computed and discarded.
        guard let onSaveCallRange = source.range(of: "onSave(selectedAgentId,") else {
            XCTFail("could not locate the real onSave(...) dispatch call site")
            return
        }
        let onSaveCallSite = source[onSaveCallRange.lowerBound...].prefix(400)
        XCTAssertTrue(onSaveCallSite.contains("idempotencyKey)"),
                      "the generated idempotencyKey must be passed as the final onSave argument")
    }

    // MARK: Bug 2 — 6. ViewModel plumbing: createEvent forwards idempotencyKey unchanged

    func test_createEvent_forwardsIdempotencyKeyUnchangedToService() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        vm.service = service

        let key = UUID().uuidString
        await vm.createEvent(agentId: "agent-1", prompt: "Reflect on today.",
                              timestamps: Array(repeating: nil, count: 31), idempotencyKey: key)

        XCTAssertEqual(service.lastAddHeartbeatIdempotencyKey, key,
                       "createEvent must forward the exact idempotencyKey it was given, unchanged, "
                       + "all the way to DataServiceProtocol.addHeartbeat")
        XCTAssertEqual(vm.events.count, 1, "a successful create must still append exactly one event")
    }

    // MARK: Bug 2 — 7. Omitting idempotencyKey forwards nil, not an invented placeholder

    func test_createEvent_omittedIdempotencyKey_forwardsNilNotAnInventedDefault() async {
        let vm = AccountViewModel()
        vm.profileData = makeProfile()
        let service = ThrowingTestDataService()
        vm.service = service

        await vm.createEvent(agentId: "agent-1", prompt: "Reflect on today.",
                              timestamps: Array(repeating: nil, count: 31))
        // idempotencyKey omitted entirely -- default parameter.

        XCTAssertNil(service.lastAddHeartbeatIdempotencyKey,
                     "omitting idempotencyKey must forward nil to the service, never a ViewModel-"
                     + "invented placeholder -- EventSetupSheet's per-Save-tap UUID is meant to be "
                     + "the ONLY source of this token")
    }
}
