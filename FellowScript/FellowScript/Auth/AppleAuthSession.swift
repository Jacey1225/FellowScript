import AuthenticationServices
import UIKit

// Bridges ASAuthorizationController's delegate-based API to async/await —
// same withCheckedContinuation + presentation-anchor pattern GoogleAuthSession
// already uses for ASWebAuthenticationSession, so both providers follow one
// established convention rather than two.
//
// Why this exists instead of SwiftUI's built-in SignInWithAppleButton (task
// 20260903-apple-signin-no-response): live, repeated XCUITest reproduction on
// a real running app instance showed SignInWithAppleButton's own
// ASAuthorizationAppleIDButton-backed touch handling never invoked its
// request-building closure on tap — confirmed across 4 separate
// configurations (in AuthView's full hierarchy, with the shared
// dismissesKeyboardOnScrollAndTap() modifier removed, with .disabled forced
// false, and as a bare button with zero surrounding modifiers), while every
// other SwiftUI Button in the same view fired reliably on the same kind of
// tap. That isolates the bug to the native control's own UIKit
// touch-to-target-action forwarding — not AuthView's layout, gestures, or
// state — so the fix keeps Apple's own ASAuthorizationController/
// ASAuthorizationAppleIDProvider APIs (per this task's Security Posture
// preference to favor mature native auth providers) but triggers them from a
// plain, proven-reliable Button instead of the broken wrapped control.
enum AppleAuthSession {

    // Retains the delegate/presentation-context-provider until the callback
    // fires — ASAuthorizationController does not retain them itself.
    private static var activeCoordinator: AppleAuthorizationCoordinator?

    @MainActor
    static func signIn(requestedScopes: [ASAuthorization.Scope]) async -> Result<ASAuthorization, Error> {
        await withCheckedContinuation { continuation in
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = requestedScopes

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let coordinator = AppleAuthorizationCoordinator { result in
                activeCoordinator = nil
                continuation.resume(returning: result)
            }
            activeCoordinator = coordinator
            controller.delegate = coordinator
            controller.presentationContextProvider = coordinator
            controller.performRequests()
        }
    }
}

private final class AppleAuthorizationCoordinator: NSObject, ASAuthorizationControllerDelegate,
                                                     ASAuthorizationControllerPresentationContextProviding {
    private let completion: (Result<ASAuthorization, Error>) -> Void

    init(completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.completion = completion
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        completion(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(error))
    }

    // Mirrors GoogleAuthSession.swift's PresentationAnchorProvider exactly —
    // same key-window lookup, same fallback.
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? UIWindow()
    }
}
