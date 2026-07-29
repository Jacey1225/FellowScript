// SOURCE: frontend/src/context/AuthContext.jsx
// DEPENDENCY: Models.swift, MockDataService.swift
// Global EnvironmentObject — replaces React's AuthContext.
// Mirrors signIn / signOut / updateUser from AuthContext.jsx.
// To use the live backend: change `MockDataService.shared` → `NetworkService.shared`.

import SwiftUI
import Combine
import UserNotifications

struct BibleNavTarget: Equatable {
    let book: String
    let chapter: Int
    let verse: Int
}

@MainActor
final class AppState: ObservableObject {

    @Published var currentUser: FSUser?
    @Published var isAuthenticated = false
    @Published var pendingBibleNav: BibleNavTarget? = nil
    @Published var pendingChatContact: FSContact? = nil   // set to open a chat from another tab
    // Set when the account predates a material Terms of Service change (e.g.
    // the Guideline 1.2 zero-tolerance rewrite) — the UI should block on a
    // re-consent screen until acceptTerms() is called.
    @Published var termsReacceptRequired = false

    // Persisted across launches via UserDefaults (mirrors localStorage in AuthContext.jsx)
    @AppStorage("fs_user_id")        private var storedUserId:   String = ""
    @AppStorage("fs_username")       private var storedUsername:  String = ""
    @AppStorage("fs_email")          private var storedEmail:     String = ""

    let service: DataServiceProtocol

    init(service: DataServiceProtocol = MockDataService.shared) {
        self.service = service
        restoreSession()
    }

    private func restoreSession() {
        guard !storedUserId.isEmpty else { return }
        currentUser     = FSUser(user_id: storedUserId, username: storedUsername, email: storedEmail)
        isAuthenticated = true
    }

    func signIn(username: String, password: String) async throws {
        let user = try await service.signIn(username: username, password: password)
        persist(user)
        requestPushNotifications()
    }

    func signUp(username: String, email: String, password: String, termsAccepted: Bool) async throws {
        let user = try await service.signUp(username: username, email: email, password: password, termsAccepted: termsAccepted)
        persist(user)
        requestPushNotifications()
    }

    func signInWithGoogle(credential: String, termsAccepted: Bool) async throws {
        let user = try await service.signInWithGoogle(credential: credential, termsAccepted: termsAccepted)
        persist(user)
        requestPushNotifications()
    }

    func signInWithApple(identityToken: String, fullName: String?, email: String?, termsAccepted: Bool) async throws {
        let user = try await service.signInWithApple(
            identityToken: identityToken, fullName: fullName, email: email, termsAccepted: termsAccepted
        )
        persist(user)
        requestPushNotifications()
    }

    /// Completes a login paused by signIn() throwing `.mfaRequired` — verifies
    /// the emailed code and finishes signing in exactly as a normal login would.
    func completeMfaLogin(userId: String, code: String) async throws {
        let user = try await service.verifyMfaLogin(userId: userId, code: code)
        persist(user)
        requestPushNotifications()
    }

    /// Records acceptance of the current Terms after a re-consent gate was shown.
    func acceptTerms() async {
        guard let uid = currentUser?.user_id else { return }
        try? await service.acceptTerms(userId: uid)
        termsReacceptRequired = false
    }

    func signOut() {
        storedUserId    = ""
        storedUsername  = ""
        storedEmail     = ""
        currentUser     = nil
        isAuthenticated = false
        // Wipe cached data so the next account never sees the previous user's notes,
        // groups, highlights, messages, or account info.
        Task { await DiskCache.shared.clear() }
    }

    func updateUser(_ patch: FSUser) {
        storedUserId   = patch.user_id
        storedUsername = patch.username
        storedEmail    = patch.email
        currentUser    = patch
    }

    private func persist(_ user: FSUser) {
        storedUserId   = user.user_id
        storedUsername = user.username
        storedEmail    = user.email
        currentUser    = user
        isAuthenticated = true
        termsReacceptRequired = user.terms_reaccept_required
    }

    func requestPushNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // First time — show the system permission dialog
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    guard granted else { return }
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            case .authorized, .provisional, .ephemeral:
                // Already granted — just refresh the token
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            default:
                break
            }
        }
    }

    func registerDeviceToken(_ token: String) {
        guard let uid = currentUser?.user_id else { return }
        Task { try? await service.registerDeviceToken(userId: uid, token: token) }
    }
}
