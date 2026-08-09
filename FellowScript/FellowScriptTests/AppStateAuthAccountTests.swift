// AppStateAuthAccountTests.swift — regression coverage for
// task: 20260808-ios-backend-integration-audit, step 3 (frontend) auth/account
// domain fixes, driven by backend step 2's route/error-handling audit.
//
// Three findings were fixed in that step and are proven here:
//
// 1. HIGH — AppState.signOut() never called POST /logout, so a device
//    "sign out" only cleared local UserDefaults while the server-side session
//    cookie stayed valid for up to 30 days. Fixed by having signOut() fire
//    NetworkService.logout() (via the injected DataServiceProtocol) as a
//    best-effort side effect alongside the existing unconditional local clear.
//
// 2. MEDIUM — AppState.acceptTerms() did `try? await service.acceptTerms(...)`
//    then unconditionally cleared `termsReacceptRequired` regardless of
//    outcome — the same try?-plus-unconditional-success shape as the already
//    fixed AccountView.saveProfile() bug (task 20260808-timezone-not-persisting).
//    Fixed by making acceptTerms() `async throws` and only clearing the gate
//    on confirmed success.
//
// 3. HIGH, broadly-impactful — NetworkService.get() (the shared helper behind
//    nearly every fetch* method, including fetchUser — the exact call path
//    incident #2, 20260808-timezone-display-stale-utc, lives in) never called
//    throwIfError, so any HTTP error silently became a blank/empty default
//    instead of a thrown error. Covered in NetworkServiceGetErrorHandlingTests
//    below using a stubbed URLProtocol, since this lives in the real
//    NetworkService (not the Mock), which is the layer that actually talks to
//    URLSession.

import XCTest
@testable import FellowScript

// MARK: - Configurable test double

/// A DataServiceProtocol conformer that forwards everything to
/// `MockDataService.shared` (so it has full, realistic behavior for methods
/// this test suite doesn't care about) except `logout`, `acceptTerms`, and
/// `fetchUser`, which are made independently controllable (return a
/// configured error, or succeed) and independently observable (was it
/// called, and with what argument), so tests can assert on AppState's
/// reaction to each outcome without depending on real network I/O.
final class ThrowingTestDataService: DataServiceProtocol {
    var apiBase: String { MockDataService.shared.apiBase }
    // Overridable (task 20260808-ios-backend-integration-audit, step 10) so
    // ChatWebSocketReconnectRegressionTests can point ChatThreadViewModel's
    // WebSocket connection at a local test listener instead of the real
    // wss://fellowscript.com/api — needed to exercise the reconnect/backoff
    // path from backend step 8 / frontend step 9 without live network access.
    var wsBaseOverride: String?
    var wsBase: String { wsBaseOverride ?? MockDataService.shared.wsBase }

    // ── Controllable / observable seams for this test suite ────────────────

    var logoutError: Error?
    private(set) var logoutCallCount = 0

    var acceptTermsError: Error?
    private(set) var acceptTermsCallCount = 0
    private(set) var lastAcceptTermsUserId: String?

    func logout() async throws {
        logoutCallCount += 1
        if let logoutError { throw logoutError }
    }

    func acceptTerms(userId: String) async throws {
        acceptTermsCallCount += 1
        lastAcceptTermsUserId = userId
        if let acceptTermsError { throw acceptTermsError }
    }

    func fetchUser(userId: String) async throws -> FSUser {
        return try await MockDataService.shared.fetchUser(userId: userId)
    }

    // ── Everything else: forward to MockDataService.shared unchanged ───────

    func signIn(username: String, password: String) async throws -> FSUser {
        return try await MockDataService.shared.signIn(username: username, password: password)
    }

    func signUp(username: String, email: String, password: String, termsAccepted: Bool) async throws -> FSUser {
        return try await MockDataService.shared.signUp(username: username, email: email, password: password, termsAccepted: termsAccepted)
    }

    func signInWithGoogle(credential: String, termsAccepted: Bool) async throws -> FSUser {
        return try await MockDataService.shared.signInWithGoogle(credential: credential, termsAccepted: termsAccepted)
    }

    func signInWithApple(identityToken: String, fullName: String?, email: String?, termsAccepted: Bool) async throws -> FSUser {
        return try await MockDataService.shared.signInWithApple(identityToken: identityToken, fullName: fullName, email: email, termsAccepted: termsAccepted)
    }

    func verifyMfaLogin(userId: String, code: String) async throws -> FSUser {
        return try await MockDataService.shared.verifyMfaLogin(userId: userId, code: code)
    }

    func mfaEnable() async throws {
        try await MockDataService.shared.mfaEnable()
    }

    func mfaConfirm(code: String) async throws {
        try await MockDataService.shared.mfaConfirm(code: code)
    }

    func mfaDisable(password: String) async throws {
        try await MockDataService.shared.mfaDisable(password: password)
    }

    func requestPasswordReset(email: String) async throws {
        try await MockDataService.shared.requestPasswordReset(email: email)
    }

    func updateUser(userId: String, body: [String: String]) async throws -> FSUser {
        return try await MockDataService.shared.updateUser(userId: userId, body: body)
    }

    func deleteUser(userId: String) async throws {
        try await MockDataService.shared.deleteUser(userId: userId)
    }

    func fetchNotes(userId: String) async throws -> [String: FSNote] {
        return try await MockDataService.shared.fetchNotes(userId: userId)
    }

    func fetchGroupNotes(userId: String, groupId: String) async throws -> [String: FSNote] {
        return try await MockDataService.shared.fetchGroupNotes(userId: userId, groupId: groupId)
    }

    func saveNote(_ note: FSNote, editingId: String?, userId: String) async throws -> String {
        return try await MockDataService.shared.saveNote(note, editingId: editingId, userId: userId)
    }

    func deleteNote(noteId: String, userId: String) async throws {
        try await MockDataService.shared.deleteNote(noteId: noteId, userId: userId)
    }

    func fetchHighlights(userId: String) async throws -> [String: String] {
        return try await MockDataService.shared.fetchHighlights(userId: userId)
    }

    // Controllable / observable — used by NotesHighlightsViewModelTests (step 7,
    // 20260808-ios-backend-integration-audit) to prove NotesViewModel /
    // BibleViewModel revert their optimistic mutation and surface saveError
    // when the write actually fails, now that saveHighlight/saveBookmark use
    // checkedRequestRaw (throws) instead of the unchecked requestRaw.
    var saveHighlightError: Error?
    private(set) var saveHighlightCallCount = 0
    var clearHighlightError: Error?
    private(set) var clearHighlightCallCount = 0
    var saveBookmarkError: Error?
    private(set) var saveBookmarkCallCount = 0
    var removeBookmarkError: Error?
    private(set) var removeBookmarkCallCount = 0

    func saveHighlight(userId: String, book: String, chapter: Int, verse: Int, color: String) async throws {
        saveHighlightCallCount += 1
        if let saveHighlightError { throw saveHighlightError }
        try await MockDataService.shared.saveHighlight(userId: userId, book: book, chapter: chapter, verse: verse, color: color)
    }

    func clearHighlight(userId: String, key: String) async throws {
        clearHighlightCallCount += 1
        if let clearHighlightError { throw clearHighlightError }
        try await MockDataService.shared.clearHighlight(userId: userId, key: key)
    }

    func fetchBookmarks(userId: String) async throws -> [String: String] {
        return try await MockDataService.shared.fetchBookmarks(userId: userId)
    }

    func saveBookmark(userId: String, book: String, chapter: Int, label: String) async throws {
        saveBookmarkCallCount += 1
        if let saveBookmarkError { throw saveBookmarkError }
        try await MockDataService.shared.saveBookmark(userId: userId, book: book, chapter: chapter, label: label)
    }

    func removeBookmark(userId: String, key: String) async throws {
        removeBookmarkCallCount += 1
        if let removeBookmarkError { throw removeBookmarkError }
        try await MockDataService.shared.removeBookmark(userId: userId, key: key)
    }

    func fetchAgents(userId: String) async throws -> [FSAgent] {
        return try await MockDataService.shared.fetchAgents(userId: userId)
    }

    func fetchAgentMessages(userId: String, agentId: String) async throws -> [FSAgentMessage] {
        return try await MockDataService.shared.fetchAgentMessages(userId: userId, agentId: agentId)
    }

    func fetchHeartbeats(userId: String, agentId: String) async throws -> [FSHeartbeat] {
        return try await MockDataService.shared.fetchHeartbeats(userId: userId, agentId: agentId)
    }

    func createAgent(userId: String, role: String) async throws -> FSAgent {
        return try await MockDataService.shared.createAgent(userId: userId, role: role)
    }

    func updateAgent(userId: String, agentId: String, enabled: Bool) async throws {
        try await MockDataService.shared.updateAgent(userId: userId, agentId: agentId, enabled: enabled)
    }

    func renameAgent(userId: String, agentId: String, name: String) async throws {
        try await MockDataService.shared.renameAgent(userId: userId, agentId: agentId, name: name)
    }

    func deleteAgent(userId: String, agentId: String) async throws {
        try await MockDataService.shared.deleteAgent(userId: userId, agentId: agentId)
    }

    func addHeartbeat(userId: String, agentId: String, heartbeat: FSHeartbeat) async throws {
        try await MockDataService.shared.addHeartbeat(userId: userId, agentId: agentId, heartbeat: heartbeat)
    }

    func deleteHeartbeat(userId: String, agentId: String, heartbeatId: String) async throws {
        try await MockDataService.shared.deleteHeartbeat(userId: userId, agentId: agentId, heartbeatId: heartbeatId)
    }

    func updateHeartbeat(userId: String, heartbeatId: String, heartbeat: FSHeartbeat) async throws {
        try await MockDataService.shared.updateHeartbeat(userId: userId, heartbeatId: heartbeatId, heartbeat: heartbeat)
    }

    // Controllable / observable (task 20260808-ios-backend-integration-audit,
    // step 13) — used by HeartbeatSchedulerRegressionTests to prove
    // HeartbeatScheduler.checkAndFire (backend step 11 finding #1's fix)
    // only marks an event fired / posts its "saved" notification when the
    // result actually contains a "success" key, not on any all-string dict
    // (e.g. {"error": ...} or {"skipped": ...}) that used to decode fine into
    // [String: String] and pass a bare `result != nil` check.
    var commitHeartbeatResult: [String: String] = ["success": "saved note"]
    var commitHeartbeatError: Error?
    private(set) var commitHeartbeatCallCount = 0

    func commitHeartbeat(userId: String, agentId: String, heartbeatId: String, prompt: String) async throws -> [String: String] {
        commitHeartbeatCallCount += 1
        if let commitHeartbeatError { throw commitHeartbeatError }
        return commitHeartbeatResult
    }

    func summarizeSession(userId: String, agentId: String, session: FSSession, groupId: String) async throws {
        try await MockDataService.shared.summarizeSession(userId: userId, agentId: agentId, session: session, groupId: groupId)
    }

    func fetchContacts(userId: String) async throws -> ([FSContact], [String: FSGroup]) {
        return try await MockDataService.shared.fetchContacts(userId: userId)
    }

    func fetchFriendMessages(userId: String, friendId: String) async throws -> [FSMessage] {
        return try await MockDataService.shared.fetchFriendMessages(userId: userId, friendId: friendId)
    }

    func fetchGroupMessages(userId: String, groupId: String) async throws -> [FSMessage] {
        return try await MockDataService.shared.fetchGroupMessages(userId: userId, groupId: groupId)
    }

    func fetchFriendRequests(userId: String) async throws -> [(id: String, username: String)] {
        return try await MockDataService.shared.fetchFriendRequests(userId: userId)
    }

    func sendFriendRequest(userId: String, username: String) async throws {
        try await MockDataService.shared.sendFriendRequest(userId: userId, username: username)
    }

    func acceptFriendRequest(userId: String, username: String) async throws {
        try await MockDataService.shared.acceptFriendRequest(userId: userId, username: username)
    }

    func removeFriend(userId: String, friendId: String) async throws {
        try await MockDataService.shared.removeFriend(userId: userId, friendId: friendId)
    }

    func reportUser(reportedUserId: String, reason: String, detail: String) async throws {
        try await MockDataService.shared.reportUser(reportedUserId: reportedUserId, reason: reason, detail: detail)
    }

    func blockUser(userId: String, blockedId: String) async throws {
        try await MockDataService.shared.blockUser(userId: userId, blockedId: blockedId)
    }

    func unblockUser(userId: String, blockedId: String) async throws {
        try await MockDataService.shared.unblockUser(userId: userId, blockedId: blockedId)
    }

    func fetchBlockedUsers(userId: String) async throws -> [FSBlockedUser] {
        return try await MockDataService.shared.fetchBlockedUsers(userId: userId)
    }

    func createGroup(userId: String, groupId: String, title: String, users: [String]) async throws {
        try await MockDataService.shared.createGroup(userId: userId, groupId: groupId, title: title, users: users)
    }

    func updateGroup(userId: String, groupId: String, title: String, users: [String]) async throws {
        try await MockDataService.shared.updateGroup(userId: userId, groupId: groupId, title: title, users: users)
    }

    func leaveGroup(userId: String, groupId: String) async throws {
        try await MockDataService.shared.leaveGroup(userId: userId, groupId: groupId)
    }

    func fetchSessionsForContact(contactId: String) async throws -> [FSSession] {
        return try await MockDataService.shared.fetchSessionsForContact(contactId: contactId)
    }

    func createSession(userId: String, devotion: FSSession, contactId: String) async throws -> String {
        return try await MockDataService.shared.createSession(userId: userId, devotion: devotion, contactId: contactId)
    }

    func updateSession(userId: String, sessionId: String, devotion: FSSession) async throws {
        try await MockDataService.shared.updateSession(userId: userId, sessionId: sessionId, devotion: devotion)
    }

    func deleteSession(userId: String, sessionId: String, devotion: FSSession) async throws {
        try await MockDataService.shared.deleteSession(userId: userId, sessionId: sessionId, devotion: devotion)
    }

    func joinSession(userId: String, sessionId: String) async throws {
        try await MockDataService.shared.joinSession(userId: userId, sessionId: sessionId)
    }

    func leaveSession(userId: String, sessionId: String) async throws {
        try await MockDataService.shared.leaveSession(userId: userId, sessionId: sessionId)
    }

    func fetchNotifications(userId: String) async throws -> [FSNotification] {
        return try await MockDataService.shared.fetchNotifications(userId: userId)
    }

    func createNotification(userId: String, name: String, prompt: String, timestamps: [String?]) async throws -> FSNotification {
        return try await MockDataService.shared.createNotification(userId: userId, name: name, prompt: prompt, timestamps: timestamps)
    }

    // Controllable seam (task 20260808-ios-backend-integration-audit, step 19)
    // for AccountViewModelUpdateNotificationErrorHandlingTests — proves the
    // frontend step 18 fix: updateNotification now uses checkedRequestRaw
    // (NetworkService) and AccountViewModel.updateNotification does do/catch
    // instead of `try?`, so a server-side failure (e.g. the DB-write errors
    // notifications.py's backend step 17 fix now re-raises instead of
    // swallowing) surfaces via agentMsg and does NOT apply the edit locally.
    var updateNotificationError: Error?
    private(set) var updateNotificationCallCount = 0
    private(set) var lastUpdateNotificationArgs: (userId: String, notifId: String, name: String, prompt: String, timestamps: [String?])?

    func updateNotification(userId: String, notifId: String, name: String, prompt: String, timestamps: [String?]) async throws {
        updateNotificationCallCount += 1
        lastUpdateNotificationArgs = (userId, notifId, name, prompt, timestamps)
        if let updateNotificationError { throw updateNotificationError }
        try await MockDataService.shared.updateNotification(userId: userId, notifId: notifId, name: name, prompt: prompt, timestamps: timestamps)
    }

    func deleteNotification(userId: String, notifId: String) async throws {
        try await MockDataService.shared.deleteNotification(userId: userId, notifId: notifId)
    }

    // Controllable seam (task 20260808-ios-backend-integration-audit, step 19)
    // for AppStateRegisterDeviceTokenErrorHandlingTests — proves the frontend
    // step 18 fix: NetworkService.registerDeviceToken now uses
    // checkedRequestRaw and AppState.registerDeviceToken replaced `try?` with
    // do/catch (logging on failure), so a rejected/failed registration is no
    // longer silently discarded outright.
    var registerDeviceTokenError: Error?
    private(set) var registerDeviceTokenCallCount = 0
    private(set) var lastRegisterDeviceTokenArgs: (userId: String, token: String)?

    func registerDeviceToken(userId: String, token: String) async throws {
        registerDeviceTokenCallCount += 1
        lastRegisterDeviceTokenArgs = (userId, token)
        if let registerDeviceTokenError { throw registerDeviceTokenError }
        try await MockDataService.shared.registerDeviceToken(userId: userId, token: token)
    }

    func triggerNotification(userId: String, notifId: String) async throws -> [String: String] {
        return try await MockDataService.shared.triggerNotification(userId: userId, notifId: notifId)
    }

    func joinCall(userId: String, sessionId: String) async throws -> ChimeJoinResponse {
        return try await MockDataService.shared.joinCall(userId: userId, sessionId: sessionId)
    }

    func fetchUsage(userId: String) async throws -> FSUsage? {
        return try await MockDataService.shared.fetchUsage(userId: userId)
    }

    func fetchUserSubscription(userId: String) async throws -> FSSubscription? {
        return try await MockDataService.shared.fetchUserSubscription(userId: userId)
    }

    func startSubscription(userId: String, memberCount: Int, billing: FSBillingInfo?) async throws -> String {
        return try await MockDataService.shared.startSubscription(userId: userId, memberCount: memberCount, billing: billing)
    }

    // Controllable seam (task 20260808-ios-backend-integration-audit, step 16)
    // for AccountViewModelUpdateSeatsErrorHandlingTests — proves the frontend
    // step 15 fix (updateSubscriptionSeats now uses checkedRequestRaw, so a
    // 403/404 rejection actually throws instead of being silently discarded).
    var updateSubscriptionSeatsError: Error?
    private(set) var updateSubscriptionSeatsCallCount = 0
    private(set) var lastUpdateSubscriptionSeatsArgs: (subscriptionId: String, memberCount: Int)?

    func updateSubscriptionSeats(subscriptionId: String, memberCount: Int) async throws {
        updateSubscriptionSeatsCallCount += 1
        lastUpdateSubscriptionSeatsArgs = (subscriptionId, memberCount)
        if let updateSubscriptionSeatsError { throw updateSubscriptionSeatsError }
        try await MockDataService.shared.updateSubscriptionSeats(subscriptionId: subscriptionId, memberCount: memberCount)
    }

    func cancelSubscription(subscriptionId: String) async throws {
        try await MockDataService.shared.cancelSubscription(subscriptionId: subscriptionId)
    }

    func fetchSubMembers(subscriptionId: String) async throws -> [FSSubMember] {
        return try await MockDataService.shared.fetchSubMembers(subscriptionId: subscriptionId)
    }

    func removeSubMember(subscriptionId: String, userId: String) async throws {
        try await MockDataService.shared.removeSubMember(subscriptionId: subscriptionId, userId: userId)
    }

    func fetchSubRequests(subscriptionId: String) async throws -> [FSSubMember] {
        return try await MockDataService.shared.fetchSubRequests(subscriptionId: subscriptionId)
    }

    func fetchMySubRequests(userId: String) async throws -> [FSSubRequest] {
        return try await MockDataService.shared.fetchMySubRequests(userId: userId)
    }

    func requestJoinSubscription(subscriptionId: String, fromUserId: String) async throws {
        try await MockDataService.shared.requestJoinSubscription(subscriptionId: subscriptionId, fromUserId: fromUserId)
    }

    func acceptSubRequest(subscriptionId: String, fromUserId: String) async throws {
        try await MockDataService.shared.acceptSubRequest(subscriptionId: subscriptionId, fromUserId: fromUserId)
    }

    func declineSubRequest(subscriptionId: String, fromUserId: String) async throws {
        try await MockDataService.shared.declineSubRequest(subscriptionId: subscriptionId, fromUserId: fromUserId)
    }

    // Controllable seam (task 20260808-ios-backend-integration-audit, step 16)
    // for StoreKitManagerPurchaseSyncFailureTests — proves the frontend step 15
    // fix to the CRITICAL false-success purchase bug: StoreKitManager.purchase()
    // must NOT finish()/report success when this call throws.
    var syncAppleSubscriptionError:  Error?
    var syncAppleSubscriptionResult: FSSubscription?
    private(set) var syncAppleSubscriptionCallCount = 0
    private(set) var lastSyncAppleSubscriptionJWS: String?

    func syncAppleSubscription(userId: String, jws: String) async throws -> FSSubscription? {
        syncAppleSubscriptionCallCount += 1
        lastSyncAppleSubscriptionJWS = jws
        if let syncAppleSubscriptionError { throw syncAppleSubscriptionError }
        if let syncAppleSubscriptionResult { return syncAppleSubscriptionResult }
        return try await MockDataService.shared.syncAppleSubscription(userId: userId, jws: jws)
    }
}

// MARK: - Tests

@MainActor
final class AppStateAuthAccountTests: XCTestCase {

    private func makeSignedInAppState(service: ThrowingTestDataService) -> AppState {
        let appState = AppState(service: service)
        // Simulate a signed-in session the way restoreSession()/persist() would.
        appState.currentUser = FSUser(user_id: "user-123", username: "alice", email: "alice@example.com")
        appState.isAuthenticated = true
        return appState
    }

    // MARK: Finding 1 — signOut() must invalidate the server-side session

    /// Before the fix, AppState.signOut() never called any network method at
    /// all, so the backend's session row/cookie stayed valid for up to 30
    /// days after an on-device "sign out". This proves the server-side
    /// logout is now actually invoked as part of signing out.
    func test_signOut_invokesServerSideLogout() async throws {
        let service = ThrowingTestDataService()
        let appState = makeSignedInAppState(service: service)

        appState.signOut()
        // signOut() fires the network call as a detached best-effort Task;
        // give it a beat to run before asserting it happened.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(service.logoutCallCount, 1,
                        "signOut() must call the backend's POST /logout (service.logout()) exactly once, not zero times")
    }

    /// Local sign-out must remain unconditional even if the server-side
    /// logout call fails (e.g. the device is offline) — a user must never be
    /// stuck "signed in" locally just because a network call failed. This is
    /// the flip side of finding 1: adding the server call must not regress
    /// the pre-existing (correct) local-clear behavior.
    func test_signOut_clearsLocalSessionSynchronously_evenWhenServerLogoutFails() async throws {
        let service = ThrowingTestDataService()
        service.logoutError = AppError.networkError("offline")
        let appState = makeSignedInAppState(service: service)

        appState.signOut()

        // Local state must already be cleared by the time signOut() returns,
        // i.e. it does not wait on (or depend on the outcome of) the
        // fire-and-forget server call.
        XCTAssertNil(appState.currentUser)
        XCTAssertFalse(appState.isAuthenticated)

        // The failing server call must still have been attempted (not skipped).
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.logoutCallCount, 1)
    }

    // MARK: Finding 2 — acceptTerms() must not clear the gate on failure

    /// Before the fix: `try? await service.acceptTerms(...)` followed by an
    /// unconditional `termsReacceptRequired = false` — a failed acceptance
    /// still cleared the blocking re-consent gate, letting a user past a
    /// required ToS acceptance without the backend ever recording it.
    func test_acceptTerms_doesNotClearGate_whenServerCallFails() async {
        let service = ThrowingTestDataService()
        service.acceptTermsError = AppError.networkError("server error")
        let appState = makeSignedInAppState(service: service)
        appState.termsReacceptRequired = true

        do {
            try await appState.acceptTerms()
            XCTFail("acceptTerms() must propagate the underlying failure, not swallow it")
        } catch {
            // expected
        }

        XCTAssertTrue(appState.termsReacceptRequired,
                       "the re-consent gate must stay up when the server call failed — clearing it would let the user past required ToS acceptance without it being recorded")
        XCTAssertEqual(service.acceptTermsCallCount, 1)
    }

    /// Happy path: a successful call still clears the gate exactly as before.
    func test_acceptTerms_clearsGate_onSuccess() async throws {
        let service = ThrowingTestDataService()
        let appState = makeSignedInAppState(service: service)
        appState.termsReacceptRequired = true

        try await appState.acceptTerms()

        XCTAssertFalse(appState.termsReacceptRequired)
        XCTAssertEqual(service.acceptTermsCallCount, 1)
        XCTAssertEqual(service.lastAcceptTermsUserId, "user-123")
    }
}
