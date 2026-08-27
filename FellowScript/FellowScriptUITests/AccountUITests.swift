// AccountUITests.swift — end-to-end regression coverage for the warm-bloom /
// glass-card / gradient-and-ghost-pill redesign of AccountView.swift
// (task: 20260807-account-page-implementation).
//
// The redesign was explicitly appearance-only: the List(.insetGrouped) became
// a ScrollView of glassCard() sections, but every state binding, disabled
// condition, and async flow across all 14 sections had to keep working
// exactly as before. These tests drive the real, running app (via the
// UI-TESTING launch argument -> MockDataService, same pattern as
// NoteEditorUITests) through the highest-value/highest-risk preserved
// surfaces called out in the task: the Danger Zone username-match delete
// gate, Sign Out, and the Agents/Events toggle + empty-state gating.
//
// Subscription purchase/restore was evaluated but intentionally NOT driven
// through a real StoreKit purchase in these tests: FellowScript.storekit is
// only wired into the scheme's LaunchAction, not its TestAction, so a
// UI-test-launched app process is not guaranteed to have a local StoreKit
// Test session attached, and driving Product.purchase()/AppStore.sync()
// without one can hang indefinitely on a real Apple ID sign-in sheet in a
// clean simulator (no way to safely dismiss that from XCUITest). Instead,
// test_subscriptionSection_noPlanState_showsStartFlow_withoutTriggeringPurchase
// proves the state-dependent Subscription UI (Start pill, member Stepper,
// Restore Purchases pill) renders and is enabled per vm.subLoading/vm.subBusy
// for the MockDataService "no active plan" case, without tapping Start /
// Restore Purchases — that gap is analogous to NoteEditorUITests' documented
// isReadOnly gap (not reachable/safe to automate, not silently skipped).

import XCTest

final class AccountUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Scroll-until-hittable helper (AccountView is a single long
    // ScrollView now, not a List — sections below the fold need scrolling
    // into view before they're tappable). Uses .slow swipes plus an explicit
    // settle delay: SwiftUI ScrollView deceleration can leave an element
    // transiently "hittable" mid-momentum, and a tap synthesized right then
    // can land on whatever settles underneath instead of the intended
    // control — the extra settle avoids that class of flake.
    //
    // Bug fix (task: 20260818-account-uitests-failures, item #1): every
    // iteration of these retry loops now also calls
    // dismissSystemAlertIfPresent(app). Previously that helper (added by task
    // 20260810-note-editor-tests-signin-not-hittable) was only polled inside
    // signInAndReachAccount()'s post-submit wait loop, which exits as soon as
    // app.buttons["Home"].exists — but iOS's Password AutoFill "Save
    // Password?" sheet is not guaranteed to render synchronously with sign-in
    // completing, and can appear after that loop has already returned. A
    // real, reproduced run of test_dangerZone_confirmedDelete_deletesAccountAndSignsOut
    // (the longest, most scroll-heavy post-sign-in flow in this file, giving
    // the delayed sheet the most opportunity to appear mid-test) showed
    // exactly that: the sheet appeared after Home was already up, sat there
    // blocking all hit-testing, and "jacob" TextField never became hittable
    // within 25.0s. Dismissing on every scroll-helper iteration (not just
    // during the initial post-sign-in window) protects any test's later
    // interactions, whenever the sheet happens to appear.

    private func scrollToAndTap(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                if element.exists && element.isHittable {
                    element.tap()
                    return
                }
            }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTFail("\(element) never became hittable within \(timeout)s\n\(app.debugDescription)")
    }

    private func scrollUntilExists(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if element.exists { return }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTFail("\(element) never appeared within \(timeout)s\n\(app.debugDescription)")
    }

    /// Like `scrollUntilExists`, but waits for `isHittable` (with a settle
    /// delay) rather than mere tree membership, and does NOT tap. Use this
    /// immediately before any direct `.tap()`/`.typeText()` call that isn't
    /// already routed through `scrollToAndTap`/`tapUntil` — merely-existing
    /// elements can still be off-screen or mid-scroll-deceleration, and a
    /// bare `.tap()` on one throws "not hittable" rather than retrying.
    /// (Needed here because checking a second, further-down element's
    /// existence — e.g. scrolling down to confirm the Delete button is
    /// present — can nudge an earlier element like the confirm TextField
    /// just out of the hittable region before it's tapped.)
    private func scrollUntilHittable(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                if element.exists && element.isHittable { return }
            }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTFail("\(element) never became hittable within \(timeout)s\n\(app.debugDescription)")
    }

    /// Dismisses the keyboard via its Return key so a control positioned
    /// right below a just-typed-into TextField (e.g. Danger Zone's Delete
    /// button, directly under the username-confirm field) isn't covered by
    /// the keyboard when subsequently tapped.
    private func dismissKeyboardIfPresent(_ app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.exists {
            returnKey.tap()
        } else {
            app.keyboards.buttons["return"].firstMatch.tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    /// Taps `tapTarget` and waits for `successElement` to appear, retrying the
    /// tap a few times if it doesn't. Observed empirically: an occasional
    /// synthesized tap on a destructive/state-changing control (Danger Zone's
    /// Delete button, a context menu's destructive Delete item) gets silently
    /// absorbed — most likely by XCUITest's own pre-tap "check for interrupting
    /// elements" pass racing a just-dismissed push-notification permission
    /// alert from sign-in — without the underlying SwiftUI action firing.
    /// Re-tapping is harmless here since both actions are idempotent no-ops
    /// once already applied (showDeleteAlert = true; agent already removed).
    private func tapUntil(_ tapTarget: XCUIElement, successElement: XCUIElement, app: XCUIApplication,
                          attempts: Int = 3, perAttemptTimeout: TimeInterval = 4) {
        for _ in 0..<attempts {
            if tapTarget.exists && tapTarget.isHittable {
                tapTarget.tap()
            }
            if successElement.waitForExistence(timeout: perAttemptTimeout) {
                return
            }
        }
        XCTFail("expected \(successElement) to appear after tapping \(tapTarget)\n\(app.debugDescription)")
    }

    /// Waits for `element` to exist AND be hittable (with a settle delay)
    /// before tapping — used throughout onboarding/sign-in instead of a bare
    /// `waitForExistence` + `.tap()`, since an element can exist in the
    /// accessibility tree mid-transition (fading/sliding in) before it's
    /// actually hittable; tapping too early throws "not hittable" rather
    /// than retrying. Returns false (without tapping) if the element never
    /// becomes hittable — callers use this the same way they previously used
    /// `waitForExistence` as an `if`-guarded optional step.
    @discardableResult
    private func waitHittableThenTap(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                if element.exists && element.isHittable {
                    element.tap()
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    // MARK: - Shared flow: onboarding + sign-in, then land on the Account tab
    // (mirrors NoteEditorUITests.signInAndReachDashboard, routed to Account).

    /// - Parameter extraLaunchArguments: additive launch arguments appended
    ///   after "UI-TESTING" — e.g. "UI-TESTING-SUBSCRIBED" (task:
    ///   20260814-subscription-benefits-detail) so a test can drive
    ///   MockDataService's active-subscriber branch. Defaults to none, so
    ///   every pre-existing call site keeps launching exactly as before.
    @discardableResult
    private func signInAndReachAccount(extraLaunchArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()

        addUIInterruptionMonitor(withDescription: "System permission alerts") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }

        // Route the app at MockDataService instead of the live backend, and
        // force a real cold launch so every test starts from clean, in-memory
        // MockDataService state (agents/subscription/etc. reset each launch).
        app.launchArguments = ["UI-TESTING"] + extraLaunchArguments
        app.terminate()
        app.launch()

        if !app.buttons["Home"].waitForExistence(timeout: 5) {
            // Bug fix (task: 20260810-note-editor-tests-signin-not-hittable):
            // "Skip →", "Begin the Tour →", and the CTA's "Sign In" are
            // standalone Text labels styled with .textCase(.uppercase) in
            // OnboardingView.swift (no accessibilityLabel override), so their
            // real accessibility label is the rendered, upper-cased string —
            // confirmed live via a real Simulator's captured accessibility
            // hierarchy. Exact mixed-case string queries never matched, so
            // these taps always silently no-op'd. Match case-insensitively,
            // same as this file already does below for "sign in button".
            func onboardingButton(containing text: String) -> XCUIElement {
                app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
            }

            // ── Onboarding (welcome -> survey -> bridge -> tour -> cta) ────
            waitHittableThenTap(app.buttons["Get Started"], timeout: 10)
            waitHittableThenTap(onboardingButton(containing: "Skip →"))
            waitHittableThenTap(onboardingButton(containing: "Begin the Tour →"))
            waitHittableThenTap(app.buttons["Skip"])
            waitHittableThenTap(onboardingButton(containing: "Sign In"))

            let usernameField = app.textFields["Username field"]
            XCTAssertTrue(usernameField.waitForExistence(timeout: 8), "expected the sign-in form's username field")
            XCTAssertTrue(waitHittableThenTap(usernameField), "expected the username field to become hittable")
            usernameField.typeText("jacob")

            let passwordField = app.secureTextFields["Password field"]
            XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
            XCTAssertTrue(waitHittableThenTap(passwordField), "expected the password field to become hittable")
            passwordField.typeText("password")

            let submitButton = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "sign in button")
            ).firstMatch
            XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
            XCTAssertTrue(waitHittableThenTap(submitButton), "expected the sign-in submit button to become hittable")

            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                dismissSystemAlertIfPresent(app)
                if app.buttons["Home"].exists { break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }

        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 15), "expected Dashboard tab bar after sign-in")

        let accountTab = app.buttons["Account"]
        XCTAssertTrue(accountTab.waitForExistence(timeout: 5), "FloatingTabBar's Account destination")
        accountTab.tap()

        // Confirms AccountView actually loaded (profile header renders the
        // signed-in user's username, per vm.load()/profileHeader).
        let usernameText = app.staticTexts["jacob"]
        XCTAssertTrue(usernameText.waitForExistence(timeout: 15), "expected AccountView's profile header to show the signed-in username")

        return app
    }

    private func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists {
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
        }
        // Bug fix (task: 20260810-note-editor-tests-signin-not-hittable): iOS's
        // Password AutoFill "Save Password?" sheet appears after a genuinely
        // successful manual sign-in and, being a same-process Sheet rather
        // than a springboard alert, fully blocks the Dashboard underneath
        // until dismissed. See NoteEditorUITests.swift's matching fix.
        let notNow = app.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
    }

    /// Taps `field` then types `text` into it, re-checked against the
    /// Password AutoFill "Save Password?" sheet immediately before each of
    /// the two actions. Needed because a snapshot-based XCUITest action
    /// (`.tap()`/`.typeText()`) on an element that has stopped existing
    /// throws a hard, unrecoverable test failure under `continueAfterFailure
    /// = false` — reproduced for real by
    /// test_dangerZone_confirmedDelete_deletesAccountAndSignsOut, where the
    /// sheet slipped in during the brief gap between `scrollUntilHittable`
    /// returning (which itself already dismisses the sheet on every retry
    /// iteration, but not after its final check) and the very next
    /// `.tap()`/`.typeText()` pair, leaving `.typeText()` unable to find any
    /// TextField at all. Since a failure there can't be caught and retried
    /// (the test method's execution is aborted at that point), the only
    /// reliable guard is re-dismissing and re-checking existence/hittability
    /// immediately before each action, not retrying after one fails.
    private func safeTypeText(_ field: XCUIElement, text: String, app: XCUIApplication, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemAlertIfPresent(app)
            if field.exists && field.isHittable {
                field.tap()
                dismissSystemAlertIfPresent(app)
                if field.exists && field.isHittable {
                    field.typeText(text)
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("expected \(field) to accept typed text (\"\(text)\") within \(timeout)s\n\(app.debugDescription)")
    }

    // MARK: - Danger Zone: username-match gate (highest-risk preserved surface)

    func test_dangerZone_deleteButtonStaysDisabledUntilUsernameMatches() {
        let app = signInAndReachAccount()

        let confirmField = app.textFields["Type your username to confirm deletion"]
        scrollUntilExists(confirmField, app: app)

        let deleteButton = app.buttons["Delete account button"]
        scrollUntilExists(deleteButton, app: app)

        // Gate must start disabled: no text entered yet (deleteConfirm == "").
        XCTAssertFalse(deleteButton.isEnabled, "Delete My Account must start disabled with an empty confirmation field")

        // Re-settle on confirmField: scrolling down to confirm deleteButton's
        // existence above may have nudged confirmField just out of the
        // hittable region.
        scrollUntilHittable(confirmField, app: app)
        safeTypeText(confirmField, text: "not-jacob", app: app)
        XCTAssertFalse(deleteButton.isEnabled, "Delete My Account must stay disabled while the typed text does not match the username exactly")

        // Clear and type the exact username ("jacob", MockDataService.mockUser).
        dismissSystemAlertIfPresent(app)
        if let currentValue = confirmField.value as? String, !currentValue.isEmpty {
            let deleteAll = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            confirmField.typeText(deleteAll)
        }
        dismissSystemAlertIfPresent(app)
        confirmField.typeText("jacob")
        XCTAssertTrue(deleteButton.isEnabled, "Delete My Account must become enabled once the field exactly matches the signed-in username")

        // The keyboard is up from typing and can cover the Delete button
        // (directly below the confirm field) — dismiss it before tapping,
        // same as a real user would before reaching for a control beneath
        // the keyboard.
        dismissKeyboardIfPresent(app)
        // Scroll it into view first (without tapping yet — tapUntil below
        // owns the actual tap-and-retry).
        scrollUntilExists(deleteButton, app: app)

        // Tapping now must raise the destructive confirmation alert rather than
        // deleting immediately — proves showDeleteAlert is still gated behind
        // the button tap, not fired as a side effect of typing.
        let alert = app.alerts["Delete Account"]
        tapUntil(deleteButton, successElement: alert, app: app)
        XCTAssertTrue(alert.staticTexts["This will permanently delete your account and all data. This cannot be undone."].exists)

        // Cancelling must leave the account intact and the user still signed in.
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts["Delete Account"].exists)
        XCTAssertTrue(app.buttons["Delete account button"].exists, "Account screen must still be showing (Cancel must not delete or sign out)")
    }

    func test_dangerZone_confirmedDelete_deletesAccountAndSignsOut() {
        let app = signInAndReachAccount()

        let confirmField = app.textFields["Type your username to confirm deletion"]
        scrollUntilHittable(confirmField, app: app)
        safeTypeText(confirmField, text: "jacob", app: app)

        // Settle before reading isEnabled: the disabled-state binding update
        // (deleteConfirm != vm.username) needs a SwiftUI render pass after
        // typeText's last keystroke, and checking immediately with zero
        // settle is a race — this test's own sibling,
        // test_dangerZone_deleteButtonStaysDisabledUntilUsernameMatches,
        // reads the same isEnabled state after a `RunLoop`-yielding
        // multi-keystroke exchange (typing a wrong value, then clearing and
        // retyping), which happens to give SwiftUI enough real wall-clock
        // time to catch up; this test's single, immediate `typeText` call
        // doesn't have that same natural buffer.
        let deleteButton = app.buttons["Delete account button"]
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 1) && deleteButton.isEnabled,
                      "Delete My Account must become enabled once the confirm field matches the signed-in username (\"jacob\")\n\(app.debugDescription)")

        dismissKeyboardIfPresent(app)
        scrollUntilExists(deleteButton, app: app)

        let alert = app.alerts["Delete Account"]
        tapUntil(deleteButton, successElement: alert, app: app)
        alert.buttons["Delete"].tap()

        // deleteUser(...) + signOut() (both async, MockDataService.deleteUser
        // is a no-op success) must return the app to the signed-out Auth flow.
        let deadline = Date().addingTimeInterval(15)
        var signedOut = false
        while Date() < deadline {
            if app.buttons["Sign In"].exists || app.textFields["Username field"].exists || app.buttons["Get Started"].exists {
                signedOut = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(signedOut, "expected the destructive Delete confirmation to sign the user out back to the Auth flow\n\(app.debugDescription)")
    }

    // MARK: - Sign Out (kept as its own neutral, non-danger-tinted card)

    func test_signOutButton_signsUserOut() {
        let app = signInAndReachAccount()

        let signOutButton = app.buttons["Sign out of your account"]
        scrollToAndTap(signOutButton, app: app)

        let deadline = Date().addingTimeInterval(10)
        var signedOut = false
        while Date() < deadline {
            if app.buttons["Sign In"].exists || app.textFields["Username field"].exists || app.buttons["Get Started"].exists {
                signedOut = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(signedOut, "tapping Sign Out must call appState.signOut() and return to the Auth flow\n\(app.debugDescription)")
    }

    // MARK: - Timezone row reflects the freshly-fetched profile, not the
    // stale pre-fetch snapshot (task: 20260808-timezone-display-stale-utc)
    //
    // Root cause (see intake spec): AccountView's `.task` used to seed the
    // local `timezone` @State from the `user` snapshot captured before
    // `vm.load(...)` awaited — i.e. from `appState.currentUser`, which is
    // populated at sign-in/session-restore and defaults `timezone` to "UTC"
    // — instead of from `vm.profileData`, the value `vm.load()` actually
    // fetches from the backend. MockDataService.fetchUser deliberately
    // returns a *different* timezone (`mockFetchedTimezone`,
    // "America/Los_Angeles") than `signIn`/`mockUser` (Codable default
    // "UTC") specifically so this distinction is observable here — mirroring
    // a real account that has previously saved a non-UTC timezone: the
    // pre-fetch snapshot only ever has the placeholder default, but the
    // freshly-fetched profile has the real, saved value. Before the fix this
    // test fails (the row shows "Timezone: UTC" instead).
    func test_timezoneRow_showsFreshlyFetchedValue_notStalePreFetchSnapshot() {
        let app = signInAndReachAccount()

        // The freshly-fetched profile's real value (vm.profileData.timezone,
        // populated by MockDataService.fetchUser) must be what's shown.
        let freshRow = app.buttons["Timezone: America/Los_Angeles"]
        scrollUntilExists(freshRow, app: app)
        XCTAssertTrue(freshRow.exists, "Timezone row must reflect vm.profileData's freshly-fetched timezone, not the pre-fetch appState.currentUser snapshot\n\(app.debugDescription)")

        // The stale pre-fetch snapshot's default ("UTC", from MockDataService's
        // signIn/mockUser) must never be what's displayed once the fetch has
        // completed — that's the exact bug this task fixed.
        XCTAssertFalse(app.buttons["Timezone: UTC"].exists,
                        "Timezone row must not show the stale pre-fetch snapshot's default 'UTC' once the profile fetch has completed\n\(app.debugDescription)")

        // Regression guard (acceptance criterion 3): username/email seeding
        // in the same `.task` block must be unaffected by the fix.
        let usernameField = app.textFields["Username field"]
        scrollUntilExists(usernameField, app: app)
        XCTAssertEqual(usernameField.value as? String, "jacob",
                        "Username field must still seed correctly from the freshly-fetched profile")

        let emailField = app.textFields["Email field"]
        scrollUntilExists(emailField, app: app)
        XCTAssertEqual(emailField.value as? String, "jacob@example.com",
                        "Email field must still seed correctly from the freshly-fetched profile")
    }

    // MARK: - Agents: toggle enable/disable, and Events' agents-empty disabled gate

    func test_agentToggle_flipsEnabledState_andPersistsAcrossToggle() {
        let app = signInAndReachAccount()

        // MockDataService.mockAgents seeds one enabled agent whose displayLabel
        // resolves to "Spiritual Guide" (role has the default "You are a
        // spiritual..." prefix -> FSAgent.displayLabel). The row is exposed as
        // a combined-children accessibility element with type .switch (not
        // .other) because it contains the interactive Toggle; the real,
        // independently-tappable Toggle control underneath keeps its own
        // narrower "Disable agent"/"Enable agent" switch, confirmed via a live
        // accessibility-tree dump.
        let enabledToggle = app.switches["Disable agent"]
        scrollUntilExists(enabledToggle, app: app)
        XCTAssertEqual(enabledToggle.value as? String, "1", "the seeded mock agent starts enabled")

        scrollToAndTap(enabledToggle, app: app)

        let disabledToggle = app.switches["Enable agent"]
        XCTAssertTrue(disabledToggle.waitForExistence(timeout: 5), "tapping the toggle must flip vm.toggleAgent's underlying enabled state")
        XCTAssertEqual(disabledToggle.value as? String, "0")
        XCTAssertTrue(app.switches["Agent: Spiritual Guide. Disabled."].waitForExistence(timeout: 5),
                      "the row's combined accessibilityLabel must reflect the new disabled state")

        // Flip back — proves it's a real two-way binding, not one-shot.
        scrollToAndTap(disabledToggle, app: app)
        let reenabledToggle = app.switches["Disable agent"]
        XCTAssertTrue(reenabledToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(reenabledToggle.value as? String, "1")
        XCTAssertTrue(app.switches["Agent: Spiritual Guide. Enabled."].waitForExistence(timeout: 5))
    }

    // FIXED (task: 20260818-account-uitests-failures, item #2): this test used
    // to crash the app process (Array._checkSubscript out-of-bounds inside
    // SwiftUI's ToggleState/Binding machinery) when deleting the only agent
    // via the context menu, because agentsSection's `ForEach($vm.agents)` held
    // an index-derived Binding into an array that the same context menu's
    // own destructive action then mutated out from under it — a well-known
    // SwiftUI `ForEach($array)` footgun, worst when the removed element was
    // the last one (array becomes empty), exactly this test's scenario. The
    // bug predated the appearance-redesign (confirmed via `git show` to be
    // byte-for-byte identical logic beforehand) and is now fixed structurally
    // in AccountView.swift: agentsSection iterates `ForEach(vm.agents)`
    // (stable values, not an index-keyed array Binding) and the row Toggle
    // sources its binding from `agentEnabledBinding(id:)`, an id-keyed
    // `Binding(get:set:)` re-resolved against vm.agents on every access.
    func test_eventsSection_newEventDisabled_whenNoAgents_reenabledAfterCreatingAgent() {
        let app = signInAndReachAccount()

        let newEventButton = app.buttons["Create new event"]
        scrollUntilExists(newEventButton, app: app)
        XCTAssertTrue(newEventButton.isEnabled, "with the seeded mock agent present, New Event must start enabled")

        // Delete the only agent via its long-press context menu (Rename/Delete
        // moved off the row per the redesign) so vm.agents becomes empty. The
        // combined row element (type .switch, per the live accessibility-tree
        // dump) is still the correct long-press target — contextMenu is
        // attached to the whole row's contentShape underneath.
        let agentRow = app.switches["Agent: Spiritual Guide. Enabled."]
        scrollUntilExists(agentRow, app: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let emptyState = app.staticTexts["No agents yet. Tap + to create one."]
        let deleteMenuItem = app.buttons["Delete"]
        // Long-press to open the context menu and tap Delete, retrying the
        // whole open->tap sequence a couple of times: occasionally the first
        // synthesized tap on the menu's destructive item gets absorbed by its
        // own dismiss animation without vm.deleteAgent firing (same class of
        // flake as the Danger Zone delete button — see tapUntil's doc comment).
        for attempt in 0..<3 {
            if !emptyState.exists {
                agentRow.press(forDuration: 1.2)
                if deleteMenuItem.waitForExistence(timeout: 5) {
                    deleteMenuItem.tap()
                }
            }
            if emptyState.waitForExistence(timeout: 4) { break }
            if attempt == 2 {
                XCTFail("expected the agent list to become empty after deleting the only agent via its context menu\n\(app.debugDescription)")
            }
        }

        // Events' "+ New Event" must now be disabled — gated on vm.agents.isEmpty,
        // unchanged by the visual restyle into the ghost-label-pill family.
        let newEventAfterDelete = app.buttons["Create new event"]
        scrollUntilExists(newEventAfterDelete, app: app)
        XCTAssertFalse(newEventAfterDelete.isEnabled, "New Event must be disabled once the agents list is empty")

        // Recreate an agent -> New Event must re-enable.
        let newAgentButton = app.buttons["Create new agent"]
        scrollToAndTap(newAgentButton, app: app)

        let createButton = app.buttons["Create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "expected the New Agent sheet's Create toolbar button")
        createButton.tap()

        let newEventAfterCreate = app.buttons["Create new event"]
        scrollUntilExists(newEventAfterCreate, app: app, timeout: 15)
        XCTAssertTrue(newEventAfterCreate.isEnabled, "New Event must re-enable once an agent exists again")
    }

    // MARK: - Subscription: no-plan state renders correctly (purchase/restore
    // themselves intentionally not driven — see file header note).

    // MARK: - Friend Requests: card width matches sibling sections in the empty
    // state (task: 20260807-friend-requests-width-fix)
    //
    // Root cause (see intake spec): friendRequestsSection's empty-state branch
    // renders only a short, non-wrapping Text with no width-forcing sibling, so
    // its VStack/glassCard shrank to fit that string instead of the section's
    // full available width, unlike every other section. The fix added
    // `.frame(maxWidth: .infinity, alignment: .leading)` to the section's outer
    // VStack. This test proves the empty-state card (MockDataService.
    // fetchFriendRequests always returns [], matching the current live default
    // reported in the bug) renders at essentially the same width as the
    // ScrollView's available content width, rather than shrink-wrapping around
    // the short "No pending friend requests." string.
    //
    // The populated branch (list of requests, each row an HStack{...Spacer()...})
    // already forces full width independently of this fix and is unchanged by
    // it (confirmed by code review, not re-driven here) — MockDataService has
    // no seam to seed a non-empty friend-requests list without adding new mock
    // infrastructure, which would be disproportionate to this narrow,
    // single-line layout fix per the task's explicit scope.
    func test_friendRequestsSection_emptyState_matchesAvailableContentWidth() {
        let app = signInAndReachAccount()

        let emptyStateText = app.staticTexts["No pending friend requests."]
        scrollUntilExists(emptyStateText, app: app)

        let card = app.otherElements["Friend Requests card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "expected the accessibilityIdentifier hook on friendRequestsSection's outer VStack to be queryable\n\(app.debugDescription)")

        let availableWidth = app.scrollViews.firstMatch.frame.width
        XCTAssertGreaterThan(availableWidth, 0, "sanity-check the ScrollView reports a real frame")

        // The section content sits inside 20pt of horizontal padding on each
        // side (AccountView.swift's outer VStack(spacing: 20).padding(.horizontal,
        // 20)), so a truly full-width card is ~availableWidth - 40. Allow a
        // little slack for safe-area/measurement rounding, but the key
        // assertion is the large margin below: before the fix, an empty-state
        // card shrink-wrapped around "No pending friend requests." (well under
        // 300pt on any current device), so this threshold cleanly separates
        // "fixed" from "regressed" without depending on exact pixel math.
        XCTAssertGreaterThan(card.frame.width, availableWidth - 60,
                              "Friend Requests card must span essentially the full available width like its sibling sections, not shrink-wrap around the empty-state text\n\(app.debugDescription)")
        XCTAssertGreaterThan(card.frame.width, 300,
                              "Friend Requests card width regressed to a shrink-to-fit size around the short empty-state string\n\(app.debugDescription)")
    }

    func test_subscriptionSection_noPlanState_showsStartFlow_withoutTriggeringPurchase() {
        let app = signInAndReachAccount()

        // MockDataService.fetchUserSubscription always returns nil -> the
        // "no active plan" branch of subscriptionSection renders: the free
        // trial caption, the member-count Stepper, and the "Start" pill.
        let trialCaption = app.staticTexts["Start with a free 1-month trial — you won't be billed until it ends."]
        scrollUntilExists(trialCaption, app: app)

        let startButton = app.buttons["Start"]
        XCTAssertTrue(startButton.exists, "expected the gradient-pill Start CTA")
        XCTAssertTrue(startButton.isEnabled, "Start must not be disabled while vm.subBusy/store.purchasing are both false")

        let restoreButton = app.buttons["Restore Purchases"]
        scrollUntilExists(restoreButton, app: app)
        XCTAssertTrue(restoreButton.isEnabled, "Restore Purchases must not be disabled while vm.subBusy is false")
    }

    // MARK: - "What's included" benefits disclosure (task:
    // 20260814-subscription-benefits-detail)
    //
    // Covers both subscription states named in the task's acceptance
    // criteria. The active-subscriber case needed a new, additive,
    // opt-in-only MockDataService seam (the "UI-TESTING-SUBSCRIBED" launch
    // argument — see MockDataService.fetchUsage/fetchUserSubscription) since
    // fetchUserSubscription previously always returned nil, making
    // activePlanRow (and therefore its benefitsDisclosure call site)
    // unreachable from any UI test; that default nil behavior is preserved
    // for every other test, including the no-plan-state test directly above.

    func test_subscriptionSection_prePurchaseBenefitsDisclosure_expandsCollapses_andTracksMemberCount() {
        let app = signInAndReachAccount()

        let toggle = app.buttons["whatsIncludedToggle"]
        scrollUntilExists(toggle, app: app)

        // Collapsed by default (design-notes.md §1.2: both states default closed).
        XCTAssertFalse(app.staticTexts["Unlimited notes"].exists,
                        "benefit rows must not be visible before the disclosure is expanded\n\(app.debugDescription)")

        scrollToAndTap(toggle, app: app)

        // All four benefit rows render, with the two-decimal free-tier
        // reference numbers MockDataService.fetchUsage's default (nil)
        // leaves at benefitRow's documented static fallback (10/7/1/3,
        // mirroring api/schemas/subscription.py FREE_LIMITS/NOTES_WINDOW_DAYS).
        let notesRow = app.staticTexts["Unlimited notes"]
        XCTAssertTrue(notesRow.waitForExistence(timeout: 5), "expected the 'Unlimited notes' benefit row after expanding\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Free plan: 10 every 7 days"].exists)
        XCTAssertTrue(app.staticTexts["Unlimited agent events"].exists)
        XCTAssertTrue(app.staticTexts["Free plan: 1"].exists)

        // Pre-purchase state: benefit copy must track the live Stepper
        // selection (selectedMemberCount starts at 1), not a static blurb.
        XCTAssertTrue(app.staticTexts["Shared group access for up to 1 member"].exists,
                       "singular 'member' must be used for a member count of 1\n\(app.debugDescription)")

        // Native UIStepper (what SwiftUI's Stepper renders as) has no direct
        // XCUIElement API of its own — the standard, documented XCUITest
        // technique is tapping a coordinate near its right edge, which lands
        // on the "+" control half.
        let stepper = app.steppers.firstMatch
        scrollUntilExists(stepper, app: app)
        stepper.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()

        let twoMembersRow = app.staticTexts["Shared group access for up to 2 members"]
        XCTAssertTrue(twoMembersRow.waitForExistence(timeout: 5),
                       "incrementing the member Stepper must update the benefits row's member count live\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Shared group access for up to 1 member"].exists,
                        "the stale 1-member benefit text must be replaced, not left alongside the new one")

        // Collapsing must hide the benefit rows again.
        scrollUntilHittable(toggle, app: app)
        toggle.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(app.staticTexts["Unlimited notes"].exists,
                        "benefit rows must be hidden again after collapsing\n\(app.debugDescription)")

        // Regression guard: expanding/collapsing/incrementing must not have
        // disturbed the Start CTA this row sits directly above.
        let startButton = app.buttons["Start"]
        scrollUntilExists(startButton, app: app)
        XCTAssertTrue(startButton.isEnabled, "Start must remain enabled after interacting with the benefits disclosure\n\(app.debugDescription)")
    }

    func test_subscriptionSection_activeSubscriberBenefitsDisclosure_showsPlanMemberCount() {
        // MockDataService.mockActiveSubscription (max_members: 3, host ==
        // signed-in user) via the additive "UI-TESTING-SUBSCRIBED" seam.
        let app = signInAndReachAccount(extraLaunchArguments: ["UI-TESTING-SUBSCRIBED"])

        // Sanity check we actually landed on the active-subscriber branch
        // (activePlanRow), not the no-plan branch this file's other
        // subscription test covers.
        let planLabel = app.staticTexts["Group Plan"]
        scrollUntilExists(planLabel, app: app)
        XCTAssertFalse(app.staticTexts["Start with a free 1-month trial — you won't be billed until it ends."].exists,
                        "the subscribed seed must render activePlanRow, not the no-plan trial caption\n\(app.debugDescription)")

        let toggle = app.buttons["whatsIncludedToggle"]
        scrollUntilExists(toggle, app: app)
        XCTAssertFalse(app.staticTexts["Unlimited notes"].exists, "collapsed by default in the active-subscriber state too")

        scrollToAndTap(toggle, app: app)

        XCTAssertTrue(app.staticTexts["Unlimited notes"].waitForExistence(timeout: 5),
                       "expected benefit rows in the active-subscriber state\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Unlimited agent events"].exists)

        // memberCount comes from plan.max_members (3) here, not a Stepper
        // selection — proves activePlanRow's call site wires the real plan
        // size through, matching design-notes.md §2.3.
        XCTAssertTrue(app.staticTexts["Shared group access for up to 3 members"].exists,
                       "expected the plan's real max_members (3) reflected in the benefits row, plural 'members'\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Unlimited usage is shared across everyone on the plan"].exists)

        // Regression guard: existing active-plan controls below the new
        // disclosure (Manage Subscription for an Apple-provider plan is not
        // reachable here since MockDataService seeds provider: "" / Stripe
        // path — Cancel Plan is the host branch instead) must still be
        // present and enabled after expanding the disclosure.
        // Matched by CONTAINS (not an exact label) since the button's default
        // accessibility label combines its SF Symbol ("trash") and "Cancel
        // Plan" text child views — same defensive pattern this file already
        // uses for onboarding/sign-in buttons above.
        let cancelButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Cancel Plan")).firstMatch
        scrollUntilExists(cancelButton, app: app)
        XCTAssertTrue(cancelButton.isEnabled, "Cancel Plan must remain enabled after interacting with the benefits disclosure\n\(app.debugDescription)")
    }
}
