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
    // Set when Apple created this account without a real name/email (only ever
    // supplied on the very first authorization) — blocks on a screen asking the
    // user to set them manually, since Apple can never resupply them.
    @Published var needsProfileCompletion = false

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
    /// Throws on failure so the blocking re-consent screen can stay up and show
    /// an error instead of clearing the gate — and thus letting the user past a
    /// required consent step — regardless of whether the server actually
    /// recorded the acceptance.
    func acceptTerms() async throws {
        guard let uid = currentUser?.user_id else { return }
        try await service.acceptTerms(userId: uid)
        termsReacceptRequired = false
    }

    /// Sets a real username/email after Apple sign-in created the account
    /// without them. Throws on failure so the view can show an error inline.
    func completeProfile(username: String, email: String) async throws {
        guard let uid = currentUser?.user_id else { return }
        let user = try await service.updateUser(userId: uid, body: ["username": username, "email": email])
        updateUser(user)
        needsProfileCompletion = false
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
        // Invalidate the session server-side too — best-effort. Local sign-out
        // above has already happened unconditionally (this device should never
        // stay "logged in" locally just because a network call failed), but
        // previously no call was ever made, so the server-side cookie/session
        // row stayed valid for up to 30 days after an on-device "sign out".
        Task { try? await service.logout() }
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
        needsProfileCompletion = user.needs_profile_completion
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

    /// Called when the user taps a session-created/session-reminder push
    /// (FellowScriptApp.AppDelegate's `didReceive response:` posts
    /// `.sessionPushTapped` with the push's `group_id`). Reuses the existing
    /// `pendingChatContact` cross-tab navigation (predates this task — see
    /// DashboardView.openFriendChat / ChatRootView's onChange) rather than a
    /// new mechanism.
    ///
    /// `group_id` is one of two shapes, per `DevotionManager.resolve_members`
    /// mirroring `is_authorized`'s own three-way membership split: a real
    /// group id, or a DM room key `"uidA|uidB"` (see
    /// `ChatThreadViewModel.roomKey`). A DM key resolves to the *other*
    /// user id (a DM's `FSContact.id` is the friend's id, not the room key
    /// itself) so `ChatThreadViewModel.roomKey` recomputes the same key the
    /// push's own room key already was.
    func openSession(groupId: String) {
        guard let uid = currentUser?.user_id, !groupId.isEmpty else { return }
        if groupId.contains("|") {
            guard let friendId = groupId.split(separator: "|").map(String.init).first(where: { $0 != uid }) else { return }
            pendingChatContact = FSContact(id: friendId, name: "", type: .friend)
        } else {
            pendingChatContact = FSContact(id: groupId, name: "", type: .group)
        }
    }

    func registerDeviceToken(_ token: String) {
        guard let uid = currentUser?.user_id else { return }
        // No UI surface for this background sync (nothing polls "is my token
        // registered?"), so a log line is the only signal on failure — but it
        // must not vanish outright the way `try?` let it before, since a failed
        // registration means this device silently never receives push reminders.
        Task {
            do {
                try await service.registerDeviceToken(userId: uid, token: token)
            } catch {
                print("Device token registration failed: \(error.localizedDescription)")
            }
        }
    }
}
