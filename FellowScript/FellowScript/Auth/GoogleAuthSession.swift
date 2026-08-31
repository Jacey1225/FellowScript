import AuthenticationServices
import CryptoKit
import Foundation

enum GoogleAuthSession {

    // iOS OAuth client (NOT the web client). Native clients must use the
    // authorization-code + PKCE flow — Google blocks the implicit id_token flow
    // for iOS clients, which is what caused the "access blocked" error.
    private static let clientID       = "667477247503-1hgf50kh24a3gi121u1eps5cptjjufds.apps.googleusercontent.com"
    private static let redirectScheme = "com.googleusercontent.apps.667477247503-1hgf50kh24a3gi121u1eps5cptjjufds"
    private static let redirectURI    = redirectScheme + ":/oauth2redirect"

    // Retain the session until the completion handler fires.
    private static var activeSession: ASWebAuthenticationSession?

    /// Runs Google sign-in (auth code + PKCE) and returns the id_token, or nil on
    /// cancel/failure.
    @MainActor
    static func signIn() async -> String? {
        let verifier  = makeCodeVerifier()
        let challenge = codeChallenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: clientID),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: "openid email profile"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = comps.url else { return nil }

        // 1. Get the authorization code from the consent sheet.
        let code: String? = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: redirectScheme
            ) { callbackURL, error in
                activeSession = nil
                guard error == nil, let url = callbackURL,
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      let code  = items.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = PresentationAnchorProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            session.start()
        }

        guard let code else { return nil }

        // 2. Exchange the code (+ PKCE verifier) for tokens and pull out id_token.
        return await exchangeCodeForIDToken(code: code, verifier: verifier)
    }

    private static func exchangeCodeForIDToken(code: String, verifier: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // iOS clients are public — no client_secret; PKCE proves the request.
        let form: [String: String] = [
            "client_id":     clientID,
            "code":          code,
            "code_verifier": verifier,
            "grant_type":    "authorization_code",
            "redirect_uri":  redirectURI,
        ]
        request.httpBody = form
            .map { "\($0.key)=\(($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // Explicit status check so a 400/401 from Google with a clear
            // error payload isn't treated identically to a transport failure
            // (dependency-errors #6).
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                print("[GoogleAuthSession] token exchange failed with HTTP \(http.statusCode)")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let idToken = json?["id_token"] as? String else {
                print("[GoogleAuthSession] token exchange response missing id_token")
                return nil
            }
            return idToken
        } catch {
            // Previously discarded with zero logging -- mirrors
            // NetworkService.decode's pattern of always logging a failure
            // instead of silently swallowing it (dependency-errors #6).
            print("[GoogleAuthSession] token exchange failed: \(error)")
            return nil
        }
    }

    // MARK: - PKCE helpers

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
