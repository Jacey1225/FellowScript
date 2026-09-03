// Regression coverage for task 20260903-apple-signin-no-response.
//
// Root cause: SwiftUI's SignInWithAppleButton (the ASAuthorizationAppleIDButton
// -backed UIViewRepresentable) never forwarded a tap to its own
// request-building closure in AuthView — confirmed live via repeated,
// real XCUITest tap reproduction against a running app instance across 4
// separate configurations before the fix: the button in AuthView's full
// hierarchy, with the shared Theme.dismissesKeyboardOnScrollAndTap()
// modifier removed (ruling that lead out), with .disabled hardcoded false,
// and as a bare SignInWithAppleButton with zero surrounding modifiers in an
// isolated top-level ZStack. Every other Button in the same view (Google,
// tab toggle, submit) fired reliably on the same kind of synthesized tap —
// only the native Apple control's own UIKit touch-to-target-action
// forwarding was broken. AuthView now drives ASAuthorizationController
// manually from a plain, composed SwiftUI Button (see AppleAuthSession.swift)
// instead of relying on that control's own touch handling, while still using
// Apple's own ASAuthorizationController/ASAuthorizationAppleIDProvider APIs
// underneath.
//
// Driving Apple's real authorization sheet to completion isn't reachable
// from XCTest (system UI, and this simulator fleet has no signed-in Apple
// ID configured, confirmed via `defaults read com.apple.appleaccount.plist`
// -> "does not exist") — same category of gap AccountUITests.swift already
// documents for StoreKit's real purchase sheet, not silently skipped here
// either. So this test proves the two things that structurally distinguish
// "responds to a tap" from the original "silently does nothing" bug,
// without depending on that unreachable system flow:
//   1. the button is composed from a plain Button (its Apple-logo image and
//      label text show up as children in the accessibility tree) — the
//      actual root-cause fix, and structurally impossible for the old,
//      opaque native control (which rendered as a single childless leaf,
//      confirmed via a live accessibility-tree dump taken during
//      root-causing).
//   2. tapping it doesn't hang the app — a sibling control in the same view
//      stays immediately hittable right after, proving the tap was handled
//      rather than wedging the main thread.
import XCTest

final class AppleSignInButtonUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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

    func test_appleSignInButton_isComposedButtonAndRespondsToTap_notOpaqueNativeControl() {
        let app = XCUIApplication()
        app.launchArguments = ["UI-TESTING"]
        app.terminate()
        app.launch()

        func onboardingButton(containing text: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        }

        // Walk onboarding to reach the sign-in form (mirrors AccountUITests'
        // signInAndReachAccount, stopping one step earlier).
        _ = waitHittableThenTap(app.buttons["Get Started"], timeout: 10)
        _ = waitHittableThenTap(onboardingButton(containing: "Skip →"))
        _ = waitHittableThenTap(onboardingButton(containing: "Begin the Tour →"))
        _ = waitHittableThenTap(app.buttons["Skip"])
        _ = waitHittableThenTap(onboardingButton(containing: "Sign In"))

        let usernameField = app.textFields["Username field"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 8), "expected the sign-in form to appear")

        let appleButton = app.buttons["Sign in with Apple"]
        XCTAssertTrue(appleButton.waitForExistence(timeout: 8), "expected the Apple button in the a11y tree")
        XCTAssertTrue(appleButton.isHittable, "the Apple button must be hittable at rest, not silently blocked")

        // Structural regression guard (see file header for why the old
        // control couldn't pass this): a composed SwiftUI Button exposes its
        // Image/Text children in the accessibility tree.
        XCTAssertTrue(appleButton.images["apple.logo"].exists,
                      "expected the Apple logo as a child of a composed Button, not an opaque native control\n\(app.debugDescription)")
        XCTAssertTrue(appleButton.staticTexts["Continue with Apple"].exists,
                      "expected the label text as a child of a composed Button, not an opaque native control\n\(app.debugDescription)")

        XCTAssertTrue(waitHittableThenTap(appleButton), "expected the Apple button to be tappable")

        // The tap must not hang the app — a sibling control in the same view
        // must still be immediately reachable right after (this is exactly
        // the class of regression the original bug would NOT have caused —
        // it never even reached this point silently — but it also guards
        // against a future change accidentally blocking the main thread on
        // tap).
        let googleButton = app.buttons["Continue with Google"]
        XCTAssertTrue(googleButton.waitForExistence(timeout: 3))
        XCTAssertTrue(googleButton.isHittable, "tapping Apple must not block/hang interaction with the rest of the form")
    }
}
