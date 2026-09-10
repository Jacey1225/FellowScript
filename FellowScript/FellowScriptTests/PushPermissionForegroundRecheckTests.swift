// PushPermissionForegroundRecheckTests.swift — regression coverage for task
// 20260909-push-permission-late-enable (frontend, single-gate Lightweight
// task).
//
// Symptom: a user who declines push permission at signup and later flips it
// on in iOS Settings never receives push, because nothing re-invoked
// AppState.requestPushNotifications() -- it was only ever called from the
// five auth-flow entry points (signIn/signUp/signInWithGoogle/
// signInWithApple/completeMfaLogin), never on the app returning to the
// foreground.
//
// Fix (frontend step): FellowScriptApp now reads `@Environment(\.scenePhase)`
// at the App level (mirroring ChatThreadView.swift's existing per-view
// scenePhase idiom) and calls `appState.requestPushNotifications()` whenever
// scenePhase becomes `.active`.
//
// Why source-pinning, not a live simulated permission transition: the actual
// wiring lives in `FellowScriptApp`'s `Scene` body (`WindowGroup.onChange(of:
// scenePhase)`), which XCTest cannot instantiate/drive the way it can a plain
// class -- the same constraint SessionPushNotificationsAppStateTests.swift's
// test 6 already documents for AppDelegate's `didReceive response:`. On top
// of that, `requestPushNotifications()`'s own branching reads
// `UNNotificationSettings.authorizationStatus`, and `UNNotificationSettings`
// has no public initializer Apple exposes for tests to fabricate a `.denied`
// or `.authorized` instance with -- there is no seam available to actually
// simulate a `.denied` -> `.authorized` transition without a broader
// UNUserNotificationCenter-abstraction refactor, which is out of scope for
// this narrow lifecycle-hook fix (the spec calls for changing
// requestPushNotifications() itself only if the re-check surfaces a defect;
// it doesn't). Instead, this pins the source of both the new wiring and the
// pre-existing (unchanged) switch it re-invokes, so a future edit that
// silently drops the foreground call, fires it on the wrong phase, or
// changes the switch's no-duplicate-prompt/no-op behavior breaks a test.
//
// Proves:
//   1. FellowScriptApp declares a scenePhase environment property, and its
//      Scene attaches an onChange(of: scenePhase) handler.
//   2. That handler calls appState.requestPushNotifications() specifically
//      when phase == .active -- not on every phase change (which would fire
//      needlessly on the transient .inactive dip too).
//   3. requestPushNotifications()'s existing switch is unchanged: .notDetermined
//      prompts once, .authorized/.provisional/.ephemeral re-registers, and
//      .denied is a genuine no-op -- so re-invoking it on every foreground
//      doesn't spam a re-prompt or silently start ignoring .denied.

import XCTest
@testable import FellowScript

final class PushPermissionForegroundRecheckTests: XCTestCase {

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    // MARK: 1/2 — the new foreground hook exists and only fires on .active

    func test_fellowScriptApp_scenePhaseActive_callsRequestPushNotifications() throws {
        let source = try readSource("FellowScript/FellowScriptApp.swift")

        XCTAssertTrue(source.contains("@Environment(\\.scenePhase) private var scenePhase"),
                      "FellowScriptApp must read scenePhase to detect the app returning to the foreground, "
                      + "mirroring ChatThreadView.swift's existing idiom")

        guard let onChangeRange = source.range(of: ".onChange(of: scenePhase)") else {
            XCTFail("no onChange(of: scenePhase) handler found on the app's Scene")
            return
        }
        let end = source.range(of: "\n    }", range: onChangeRange.upperBound..<source.endIndex)?.lowerBound
            ?? source.endIndex
        let body = String(source[onChangeRange.upperBound..<end])

        XCTAssertTrue(body.contains("phase == .active"),
                      "must gate on .active specifically -- not .inactive, which also fires for transient "
                      + "states (Control Center, a permission overlay, the app switcher) that never actually "
                      + "left the app")
        XCTAssertTrue(body.contains("appState.requestPushNotifications()"),
                      "must re-invoke requestPushNotifications() on foreground so a permission flipped on "
                      + "later in iOS Settings is picked up without requiring sign-out/sign-in or reinstall")
    }

    // MARK: 3 — the pre-existing switch this hook re-invokes is unchanged

    func test_requestPushNotifications_switch_stillHandlesEveryAuthorizationStatus_withNoSpam() throws {
        let source = try readSource("FellowScript/Services/AppState.swift")

        guard let methodRange = source.range(of: "func requestPushNotifications()") else {
            XCTFail("requestPushNotifications() not found")
            return
        }
        let end = source.range(of: "\n    }\n", range: methodRange.upperBound..<source.endIndex)?.lowerBound
            ?? source.endIndex
        let body = String(source[methodRange.upperBound..<end])

        XCTAssertTrue(body.contains(".notDetermined"),
                      "must still only prompt (requestAuthorization) while genuinely undecided")
        XCTAssertTrue(body.contains("requestAuthorization"),
                      "must still request authorization for the .notDetermined case")
        XCTAssertTrue(body.contains(".authorized, .provisional, .ephemeral"),
                      "must still refresh the token for every already-granted status")
        XCTAssertTrue(body.contains("registerForRemoteNotifications()"),
                      "must still call registerForRemoteNotifications() once authorized -- the actual "
                      + "call this whole task exists to get re-invoked on a late permission grant")
        XCTAssertTrue(body.contains("case .denied:"),
                      "must still have a distinct .denied case")

        // No-duplicate-prompt-spam guard: .denied must stay a genuine no-op
        // (not itself calling requestAuthorization or registerForRemoteNotifications),
        // since this switch is now re-invoked on every foreground, not just
        // the five original auth-flow call sites.
        guard let deniedRange = body.range(of: "case .denied:") else {
            XCTFail("case .denied: not found")
            return
        }
        let deniedEnd = body.range(of: "\n            case", range: deniedRange.upperBound..<body.endIndex)?.lowerBound
            ?? (body.range(of: "\n            @unknown", range: deniedRange.upperBound..<body.endIndex)?.lowerBound ?? body.endIndex)
        let deniedBody = String(body[deniedRange.upperBound..<deniedEnd])
        XCTAssertFalse(deniedBody.contains("requestAuthorization"),
                       ".denied must not re-prompt -- would spam the user every time they foreground the app")
        XCTAssertFalse(deniedBody.contains("registerForRemoteNotifications"),
                       ".denied must not attempt registration -- there is no permission to register with")
    }
}
