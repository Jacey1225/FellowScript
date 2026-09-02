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

    // Controllable / observable (task 20260830-compliance-remediation, C4) --
    // used by DeleteAccountAndActionRevertRegressionTests to prove the
    // delete-account flow only signs out on confirmed success and surfaces
    // an alert (never a silent sign-out) on failure.
    var deleteUserError: Error?
    private(set) var deleteUserCallCount = 0

    func deleteUser(userId: String) async throws {
        deleteUserCallCount += 1
        if let deleteUserError { throw deleteUserError }
        try await MockDataService.shared.deleteUser(userId: userId)
    }

    // task 20260817-notes-pagination-backend: DataServiceProtocol's notes
    // read methods now take an explicit cursor and return a NotesPage
    // (notes + next cursor + has_more) instead of a bare [String: FSNote],
    // matching the backend's keyset-paginated response contract.
    //
    // Controllable/observable (used by NotesPaginationRegressionTests to
    // drive NotesViewModel.loadMoreIfNeeded through a specific sequence of
    // backend pages without touching the network): when a queue is
    // populated, each call pops and returns the next queued page instead of
    // forwarding to MockDataService; an empty queue falls back to the mock's
    // real (single-page, hasMore: false) behavior so every OTHER test suite
    // using this double is unaffected.
    var fetchNotesPageQueue: [NotesPage] = []
    private(set) var fetchNotesCallCount = 0
    private(set) var fetchNotesCursors: [(created: String?, id: String?)] = []
    // Controllable (task 20260901-dashboard-stale-reload-ui, testing step 2) --
    // lets DashboardStaleReloadRegressionTests prove DashboardViewModel.load()
    // no longer wipes already-good notes to empty on a thrown fetchNotes
    // error, mirroring the existing fetchContactsError/fetchFriendActivityError
    // seams on this same double.
    var fetchNotesError: Error?
    var fetchNotesDelayNanoseconds: UInt64?

    var fetchGroupNotesPageQueue: [NotesPage] = []
    private(set) var fetchGroupNotesCallCount = 0
    private(set) var fetchGroupNotesCursors: [(created: String?, id: String?)] = []

    var fetchNotesCountResult: Int?

    func fetchNotes(userId: String, cursorCreatedAt: String?, cursorId: String?) async throws -> NotesPage {
        fetchNotesCallCount += 1
        fetchNotesCursors.append((cursorCreatedAt, cursorId))
        if let fetchNotesDelayNanoseconds {
            try await Task.sleep(nanoseconds: fetchNotesDelayNanoseconds)
        }
        if let fetchNotesError { throw fetchNotesError }
        if !fetchNotesPageQueue.isEmpty { return fetchNotesPageQueue.removeFirst() }
        return try await MockDataService.shared.fetchNotes(userId: userId, cursorCreatedAt: cursorCreatedAt, cursorId: cursorId)
    }

    func fetchGroupNotes(userId: String, groupId: String, cursorCreatedAt: String?, cursorId: String?) async throws -> NotesPage {
        fetchGroupNotesCallCount += 1
        fetchGroupNotesCursors.append((cursorCreatedAt, cursorId))
        if !fetchGroupNotesPageQueue.isEmpty { return fetchGroupNotesPageQueue.removeFirst() }
        return try await MockDataService.shared.fetchGroupNotes(userId: userId, groupId: groupId, cursorCreatedAt: cursorCreatedAt, cursorId: cursorId)
    }

    func fetchNotesCount(userId: String) async throws -> Int {
        if let fetchNotesCountResult { return fetchNotesCountResult }
        return try await MockDataService.shared.fetchNotesCount(userId: userId)
    }

    func saveNote(_ note: FSNote, editingId: String?, userId: String) async throws -> String {
        return try await MockDataService.shared.saveNote(note, editingId: editingId, userId: userId)
    }

    // Controllable / observable (task 20260830-compliance-remediation, H6/H7)
    // -- used by DeleteAccountAndActionRevertRegressionTests to prove
    // NotesViewModel.deleteNote reverts its optimistic removal and surfaces
    // saveError on failure, matching the sibling saveHighlight/clearHighlight
    // pattern above.
    var deleteNoteError: Error?
    private(set) var deleteNoteCallCount = 0

    func deleteNote(noteId: String, userId: String) async throws {
        deleteNoteCallCount += 1
        if let deleteNoteError { throw deleteNoteError }
        try await MockDataService.shared.deleteNote(noteId: noteId, userId: userId)
    }

    // Stub conformance only (task 20260828-note-reply-continuation-ios) --
    // no test in this file exercises replies; delegates like the other
    // pass-through stubs above.
    func fetchReplies(userId: String, noteId: String, groupId: String) async throws -> [FSNote] {
        try await MockDataService.shared.fetchReplies(userId: userId, noteId: noteId, groupId: groupId)
    }

    func postReply(_ reply: FSNote, noteId: String) async throws -> String {
        try await MockDataService.shared.postReply(reply, noteId: noteId)
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

    // Controllable / observable seams for the heartbeat CRUD calls
    // (task 20260901-heartbeat-backend-scheduling, testing step: replacement
    // regression coverage for the deleted HeartbeatSchedulerRegressionTests.swift
    // — those three call sites used to also call the now-removed
    // HeartbeatScheduler.scheduleAll(events:); HeartbeatCRUDRegressionTests.swift
    // uses these seams to prove AccountViewModel's create/delete/update event
    // flows still behave correctly (optimistic update/revert, error surfacing)
    // now that call is gone.)
    var addHeartbeatError: Error?
    var deleteHeartbeatError: Error?
    var updateHeartbeatError: Error?

    func addHeartbeat(userId: String, agentId: String, heartbeat: FSHeartbeat) async throws {
        if let addHeartbeatError { throw addHeartbeatError }
        try await MockDataService.shared.addHeartbeat(userId: userId, agentId: agentId, heartbeat: heartbeat)
    }

    func deleteHeartbeat(userId: String, agentId: String, heartbeatId: String) async throws {
        if let deleteHeartbeatError { throw deleteHeartbeatError }
        try await MockDataService.shared.deleteHeartbeat(userId: userId, agentId: agentId, heartbeatId: heartbeatId)
    }

    func updateHeartbeat(userId: String, heartbeatId: String, heartbeat: FSHeartbeat) async throws {
        if let updateHeartbeatError { throw updateHeartbeatError }
        try await MockDataService.shared.updateHeartbeat(userId: userId, heartbeatId: heartbeatId, heartbeat: heartbeat)
    }

    // Controllable / observable seam for `commitHeartbeat`. Originally added
    // (task 20260808-ios-backend-integration-audit, step 13; extended by
    // 20260825-scheduled-event-duplicate-fire) to drive the now-removed
    // HeartbeatScheduler.checkAndFire (client-side heartbeat firing was moved
    // to the backend in 20260901-heartbeat-backend-scheduling, along with
    // HeartbeatSchedulerRegressionTests.swift, which exercised this seam).
    // Left in place — still valid DataServiceProtocol conformance and a
    // reusable seam for `commitHeartbeat`, though nothing in the app calls
    // it client-side anymore (firing is server-only now; see
    // scheduler.py::_fire_due_heartbeats). Testing gate's replacement
    // coverage decision: since no client-side firing logic survives to
    // regression-test, HeartbeatSchedulerRegressionTests.swift's actual
    // replacement is HeartbeatCRUDRegressionTests.swift, which proves the
    // create/delete/update event flows above (the real surviving call sites
    // that used to also call the removed HeartbeatScheduler.scheduleAll)
    // still behave correctly with that call gone.
    var commitHeartbeatResult: [String: String] = ["success": "saved note"]
    var commitHeartbeatError: Error?
    private(set) var commitHeartbeatCallCount = 0
    var commitHeartbeatResultForId: [String: [String: String]] = [:]
    private(set) var commitHeartbeatCallCountForId: [String: Int] = [:]
    var onCommitHeartbeat: ((String) -> Void)?
    // Controllable (task 20260901-heartbeat-manual-trigger-button, testing
    // step) -- forces a real suspension point (Task.sleep, same technique as
    // the existing fetchNotesDelayNanoseconds seam above) inside the mocked
    // network round-trip so a concurrent second call for the same heartbeat
    // has an actual window to run its own guard check while the first call
    // is still in flight. Without this, this fully-synchronous mock's async
    // call never truly yields the MainActor mid-flight, so two racing calls
    // just serialize end-to-end instead of overlapping -- which would make
    // AccountViewModel.fireHeartbeatNow's firingHeartbeatIds guard untestable
    // (it would "pass" even if the guard were deleted entirely).
    var commitHeartbeatDelayNanoseconds: UInt64?

    func commitHeartbeat(userId: String, agentId: String, heartbeatId: String, prompt: String) async throws -> [String: String] {
        commitHeartbeatCallCount += 1
        commitHeartbeatCallCountForId[heartbeatId, default: 0] += 1
        onCommitHeartbeat?(heartbeatId)
        if let commitHeartbeatDelayNanoseconds {
            try await Task.sleep(nanoseconds: commitHeartbeatDelayNanoseconds)
        }
        if let commitHeartbeatError { throw commitHeartbeatError }
        return commitHeartbeatResultForId[heartbeatId] ?? commitHeartbeatResult
    }

    func summarizeSession(userId: String, agentId: String, session: FSSession, groupId: String) async throws {
        try await MockDataService.shared.summarizeSession(userId: userId, agentId: agentId, session: session, groupId: groupId)
    }

    // Controllable / observable (task 20260823-app-loading-screen, testing
    // step) — used by StartupCoordinatorTests to prove the startup-readiness
    // gate (a) doesn't hang when one data source's fetch throws (NotesViewModel
    // and ChatViewModel both call fetchContacts and already swallow its error
    // via `try?`, so this should resolve to an empty/default result, not
    // propagate) and (b) really does wait on real in-flight work — a delayed
    // fetchContacts call is a shared dependency of BOTH NotesViewModel.load
    // and ChatViewModel.load, so delaying it stalls StartupCoordinator's
    // `await (notes, bible, chat)` race until either it resolves or the
    // coordinator's own timeout fires, whichever comes first.
    var fetchContactsError: Error?
    var fetchContactsDelayNanoseconds: UInt64?
    private(set) var fetchContactsCallCount = 0

    func fetchContacts(userId: String) async throws -> ([FSContact], [String: FSGroup]) {
        fetchContactsCallCount += 1
        if let fetchContactsDelayNanoseconds {
            try await Task.sleep(nanoseconds: fetchContactsDelayNanoseconds)
        }
        if let fetchContactsError { throw fetchContactsError }
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

    // Controllable/observable — used by DashboardViewModel.load() tests
    // (Dashboard's Editorial Hero Friend Activity card + check-in nudge).
    // `fetchFriendActivityResult` overrides the return value (e.g. `.empty`
    // for the "no friends"/"no recent activity" empty states); nil falls
    // back to MockDataService's populated fixture, matching every other
    // simple override seam in this double.
    var fetchFriendActivityResult: FSFriendActivityFeed?
    var fetchFriendActivityError: Error?
    var fetchFriendActivityDelayNanoseconds: UInt64?
    private(set) var fetchFriendActivityCallCount = 0

    func fetchFriendActivity(userId: String) async throws -> FSFriendActivityFeed {
        fetchFriendActivityCallCount += 1
        if let fetchFriendActivityDelayNanoseconds {
            try await Task.sleep(nanoseconds: fetchFriendActivityDelayNanoseconds)
        }
        if let fetchFriendActivityError { throw fetchFriendActivityError }
        if let fetchFriendActivityResult { return fetchFriendActivityResult }
        return try await MockDataService.shared.fetchFriendActivity(userId: userId)
    }

    func sendFriendRequest(userId: String, username: String) async throws {
        try await MockDataService.shared.sendFriendRequest(userId: userId, username: username)
    }

    func acceptFriendRequest(userId: String, username: String) async throws {
        try await MockDataService.shared.acceptFriendRequest(userId: userId, username: username)
    }

    // Controllable / observable (task 20260830-compliance-remediation, H6/H7)
    // -- used by DeleteAccountAndActionRevertRegressionTests to prove
    // ChatViewModel.removeFriend/leaveGroup and ChatRootView's
    // reportUser/blockUser revert their optimistic mutation and surface an
    // error instead of a bare `try?` no-op.
    var removeFriendError: Error?
    private(set) var removeFriendCallCount = 0
    var reportUserError: Error?
    private(set) var reportUserCallCount = 0
    var blockUserError: Error?
    private(set) var blockUserCallCount = 0

    func removeFriend(userId: String, friendId: String) async throws {
        removeFriendCallCount += 1
        if let removeFriendError { throw removeFriendError }
        try await MockDataService.shared.removeFriend(userId: userId, friendId: friendId)
    }

    func reportUser(reportedUserId: String, reason: String, detail: String) async throws {
        reportUserCallCount += 1
        if let reportUserError { throw reportUserError }
        try await MockDataService.shared.reportUser(reportedUserId: reportedUserId, reason: reason, detail: detail)
    }

    func blockUser(userId: String, blockedId: String) async throws {
        blockUserCallCount += 1
        if let blockUserError { throw blockUserError }
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

    var leaveGroupError: Error?
    private(set) var leaveGroupCallCount = 0

    func leaveGroup(userId: String, groupId: String) async throws {
        leaveGroupCallCount += 1
        if let leaveGroupError { throw leaveGroupError }
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

    func joinCall(userId: String, sessionId: String) async throws -> ChimeJoinResponse {
        return try await MockDataService.shared.joinCall(userId: userId, sessionId: sessionId)
    }

    // Observable (task 20260901-heartbeat-manual-trigger-button, testing step)
    // -- proves fireHeartbeatNow's success path really calls refreshUsage()
    // (which calls this), rather than merely assuming it from reading the
    // implementation. Behavior is unchanged (still forwards to
    // MockDataService.shared) for every pre-existing caller of this seam.
    private(set) var fetchUsageCallCount = 0

    func fetchUsage(userId: String) async throws -> FSUsage? {
        fetchUsageCallCount += 1
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
