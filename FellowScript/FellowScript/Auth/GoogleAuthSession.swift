import AuthenticationServices
import Foundation

enum GoogleAuthSession {

    private static let clientID   = "667477247503-plvi16hhr4gpigqudkpsc3epsu6edbgq.apps.googleusercontent.com"
    private static let redirectURI = "com.fellowscript.app:/oauth2redirect"

    // Retain the session until the completion handler fires.
    private static var activeSession: ASWebAuthenticationSession?

    /// Opens a Google OAuth implicit-flow sheet and returns the raw id_token string,
    /// or nil if the user cancelled or the token could not be extracted.
    @MainActor
    static func signIn() async -> String? {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "response_type", value: "id_token"),
            URLQueryItem(name: "scope",         value: "email profile"),
            URLQueryItem(name: "nonce",         value: nonce),
        ]

        guard let authURL = comps.url else { return nil }

        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "com.fellowscript.app"
            ) { callbackURL, error in
                activeSession = nil
                guard error == nil, let url = callbackURL else {
                    continuation.resume(returning: nil)
                    return
                }
                // Token arrives in the URL fragment: #id_token=...&token_type=Bearer&...
                let fragment = url.fragment ?? ""
                var params: [String: String] = [:]
                for pair in fragment.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        params[String(kv[0])] = String(kv[1])
                            .removingPercentEncoding ?? String(kv[1])
                    }
                }
                continuation.resume(returning: params["id_token"])
            }
            session.presentationContextProvider = PresentationAnchorProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            session.start()
        }
    }
}

// MARK: - Presentation context

private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationAnchorProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? UIWindow()
    }
}
