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
    }

    func signUp(username: String, email: String, password: String) async throws {
        let user = try await service.signUp(username: username, email: email, password: password)
        persist(user)
    }

    func signOut() {
        storedUserId    = ""
        storedUsername  = ""
        storedEmail     = ""
        currentUser     = nil
        isAuthenticated = false
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
        requestPushNotifications()
    }

    func requestPushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func registerDeviceToken(_ token: String) {
        guard let uid = currentUser?.user_id else { return }
        Task { try? await service.registerDeviceToken(userId: uid, token: token) }
    }
}
