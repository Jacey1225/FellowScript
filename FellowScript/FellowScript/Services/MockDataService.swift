// SOURCE: frontend/src/context/AuthContext.jsx, all hooks
// DEPENDENCY: Models.swift
// Provides realistic stub data so the UI renders without a live backend.
// Conforms to DataServiceProtocol so NetworkService can replace it transparently.

import Foundation

// ── Protocol ─────────────────────────────────────────────────────────────────

protocol DataServiceProtocol {
    var apiBase: String { get }
    var wsBase:  String { get }

    // Auth
    func signIn(username: String, password: String) async throws -> FSUser
    func signUp(username: String, email: String, password: String, termsAccepted: Bool) async throws -> FSUser
    func signInWithGoogle(credential: String, termsAccepted: Bool) async throws -> FSUser
    func signInWithApple(identityToken: String, fullName: String?, email: String?, termsAccepted: Bool) async throws -> FSUser
    func acceptTerms(userId: String) async throws
    func logout() async throws

    // Two-factor authentication
    func verifyMfaLogin(userId: String, code: String) async throws -> FSUser
    func mfaEnable() async throws
    func mfaConfirm(code: String) async throws
    func mfaDisable(password: String) async throws

    // Password reset
    func requestPasswordReset(email: String) async throws

    // User
    func fetchUser(userId: String) async throws -> FSUser
    func updateUser(userId: String, body: [String: String]) async throws -> FSUser
    func deleteUser(userId: String) async throws

    // Notes (read)
    func fetchNotes(userId: String) async throws -> [String: FSNote]
    func fetchGroupNotes(userId: String, groupId: String) async throws -> [String: FSNote]

    // Notes (write)
    func saveNote(_ note: FSNote, editingId: String?, userId: String) async throws -> String
    func deleteNote(noteId: String, userId: String) async throws

    // Highlights
    func fetchHighlights(userId: String) async throws -> [String: String]
    func saveHighlight(userId: String, book: String, chapter: Int, verse: Int, color: String) async throws
    func clearHighlight(userId: String, key: String) async throws

    // Bookmarks
    func fetchBookmarks(userId: String) async throws -> [String: String]
    func saveBookmark(userId: String, book: String, chapter: Int, label: String) async throws
    func removeBookmark(userId: String, key: String) async throws

    // Agents (read)
    func fetchAgents(userId: String) async throws -> [FSAgent]
    func fetchAgentMessages(userId: String, agentId: String) async throws -> [FSAgentMessage]
    func fetchHeartbeats(userId: String, agentId: String) async throws -> [FSHeartbeat]

    // Agents (write)
    func createAgent(userId: String, role: String) async throws -> FSAgent
    func updateAgent(userId: String, agentId: String, enabled: Bool) async throws
    func renameAgent(userId: String, agentId: String, name: String) async throws
    func deleteAgent(userId: String, agentId: String) async throws
    func addHeartbeat(userId: String, agentId: String, heartbeat: FSHeartbeat) async throws
    func deleteHeartbeat(userId: String, agentId: String, heartbeatId: String) async throws
    func updateHeartbeat(userId: String, heartbeatId: String, heartbeat: FSHeartbeat) async throws
    func commitHeartbeat(userId: String, agentId: String, heartbeatId: String, prompt: String) async throws -> [String: String]
    func summarizeSession(userId: String, agentId: String, session: FSSession, groupId: String) async throws

    // Contacts + messages
    func fetchContacts(userId: String) async throws -> ([FSContact], [String: FSGroup])
    func fetchFriendMessages(userId: String, friendId: String) async throws -> [FSMessage]
    func fetchGroupMessages(userId: String, groupId: String) async throws -> [FSMessage]

    // Friends
    func fetchFriendRequests(userId: String) async throws -> [(id: String, username: String)]
    func sendFriendRequest(userId: String, username: String) async throws
    func acceptFriendRequest(userId: String, username: String) async throws
    func removeFriend(userId: String, friendId: String) async throws

    // Reports / Blocks (Guideline 1.2)
    func reportUser(reportedUserId: String, reason: String, detail: String) async throws
    func blockUser(userId: String, blockedId: String) async throws
    func unblockUser(userId: String, blockedId: String) async throws
    func fetchBlockedUsers(userId: String) async throws -> [FSBlockedUser]

    // Groups
    func createGroup(userId: String, groupId: String, title: String, users: [String]) async throws
    func updateGroup(userId: String, groupId: String, title: String, users: [String]) async throws
    func leaveGroup(userId: String, groupId: String) async throws

    // Sessions / Devotions
    func fetchSessionsForContact(contactId: String) async throws -> [FSSession]
    func createSession(userId: String, devotion: FSSession, contactId: String) async throws -> String
    func updateSession(userId: String, sessionId: String, devotion: FSSession) async throws
    func deleteSession(userId: String, sessionId: String, devotion: FSSession) async throws
    func joinSession(userId: String, sessionId: String) async throws
    func leaveSession(userId: String, sessionId: String) async throws

    // Notifications
    func fetchNotifications(userId: String) async throws -> [FSNotification]
    func createNotification(userId: String, name: String, prompt: String, timestamps: [String?]) async throws -> FSNotification
    func updateNotification(userId: String, notifId: String, name: String, prompt: String, timestamps: [String?]) async throws
    func deleteNotification(userId: String, notifId: String) async throws
    func registerDeviceToken(userId: String, token: String) async throws
    func triggerNotification(userId: String, notifId: String) async throws -> [String: String]

    // Chime calls
    func joinCall(userId: String, sessionId: String) async throws -> ChimeJoinResponse

    // Subscriptions
    func fetchUsage(userId: String) async throws -> FSUsage?
    func fetchUserSubscription(userId: String) async throws -> FSSubscription?
    func startSubscription(userId: String, memberCount: Int, billing: FSBillingInfo?) async throws -> String
    func updateSubscriptionSeats(subscriptionId: String, memberCount: Int) async throws
    func cancelSubscription(subscriptionId: String) async throws
    func fetchSubMembers(subscriptionId: String) async throws -> [FSSubMember]
    func removeSubMember(subscriptionId: String, userId: String) async throws
    func fetchSubRequests(subscriptionId: String) async throws -> [FSSubMember]
    func fetchMySubRequests(userId: String) async throws -> [FSSubRequest]
    func requestJoinSubscription(subscriptionId: String, fromUserId: String) async throws
    func acceptSubRequest(subscriptionId: String, fromUserId: String) async throws
    func declineSubRequest(subscriptionId: String, fromUserId: String) async throws
    func syncAppleSubscription(userId: String, jws: String) async throws -> FSSubscription?
}

// ── Mock data ─────────────────────────────────────────────────────────────────

final class MockDataService: DataServiceProtocol {
    static let shared = MockDataService()
    private init() {}

    let apiBase = "https://fellowscript.com/api"
    let wsBase  = "wss://fellowscript.com/api"

    // ── Static stubs ──────────────────────────────────────────────────────────

    static let mockUser = FSUser(
        user_id:  "60aa9553-b147-4e09-9a6e-b3e3abcf57f0",
        username: "jacob",
        email:    "jacob@example.com",
        friends:  ["friend-001", "friend-002"],
        groups:   ["group-abc"],
        notes:    [:],
        highlights: [:]
    )

    // The timezone `fetchUser` returns — deliberately different from
    // `mockUser.timezone` (Codable default "UTC"), which is what `signIn`
    // returns and what a cold-launch `appState.currentUser` snapshot is seeded
    // with. This mirrors a real account that has previously saved a non-UTC
    // timezone: the backend/fetch path has that real value, while a pre-fetch
    // snapshot only ever has the placeholder default. Lets tests distinguish
    // "the stale pre-fetch snapshot" from "the freshly-fetched profile" — the
    // exact distinction at the heart of the 20260808-timezone-display-stale-utc
    // regression (AccountView's `.task` used to seed its Timezone row from the
    // former instead of the latter).
    static let mockFetchedTimezone = "America/Los_Angeles"

    static let mockNotes: [String: FSNote] = {
        let n1 = FSNote(
            id: "note-001", user: mockUser.user_id,
            title: "Sunday Service 06/28",
            text: "Pastor Ed spoke on the courage of faith — David's inquiry before battle showed complete dependence on God.",
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-06-28 20:10:22",
            verses: [[.string("1 Samuel"), .int(23), .int(2)]], replies: []
        )
        let n2 = FSNote(
            id: "note-002", user: mockUser.user_id,
            title: "Psalm 23 Reflection",
            text: "<b>The Lord is my shepherd</b> — what does it mean to lack nothing?",
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-06-22 09:30:00",
            verses: [[.string("Psalms"), .int(23), .int(1)]], replies: []
        )
        let n3 = FSNote(
            id: "note-003", user: mockUser.user_id,
            title: "Grace and Truth",
            text: "John opens with the Word becoming flesh. Grace and truth came through Jesus Christ.",
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-06-15 18:45:00",
            verses: [[.string("John"), .int(1), .int(14)]], replies: []
        )
        // Group note — visible in the Community Activity widget
        let n4 = FSNote(
            id: "note-grp-001", user: mockUser.user_id,
            title: "Romans 8 Study Notes",
            text: "<p>Walking by the Spirit — what does it mean to set the mind on the Spirit?</p>",
            public: true, group_id: "group-abc", is_reply: false,
            timestamp: "2026-07-08T10:15:00Z",
            verses: [[.string("Romans"), .int(8), .int(1)]], replies: []
        )
        return ["note-001": n1, "note-002": n2, "note-003": n3, "note-grp-001": n4]
    }()

    static let mockHighlights: [String: String] = [
        "John-1-1": "#F5E642",
        "John-1-14": "#7EB8E0",
        "Psalms-23-1": "#6DBF7E",
        "1 Samuel-23-2": "#B07EE0",
        "Genesis-1-1": "#F5E642",
    ]

    static let mockBookmarks: [String: String] = [
        "John-1": "Gospel of John",
        "Psalms-23": "The Shepherd's Psalm",
        "Genesis-1": "",
    ]

    static let mockAgents: [FSAgent] = [
        FSAgent(
            id: "agent-001", user_id: mockUser.user_id,
            role: "You are a spiritual mentor focused on New Testament theology.",
            enabled: true, chats: []
        )
    ]

    static let mockContacts: [FSContact] = [
        FSContact(id: "friend-001", name: "Sarah",  type: .friend, preview: "See you at Bible study!"),
        FSContact(id: "friend-002", name: "Marcus", type: .friend, preview: "Romans 8 is incredible"),
        FSContact(id: "group-abc",  name: "Wednesday Night Study", type: .group,
                  preview: "Session tomorrow at 7pm",
                  toUsers: [mockUser.user_id, "friend-001", "friend-002"],
                  memberNames: ["Sarah", "Marcus"]),
    ]

    static let mockMessages: [FSMessage] = [
        FSMessage(id: "m1", text: "Did everyone finish the Psalm 23 reading?",          mine: false, sender: "Sarah",  timestamp: "2026-06-28T09:00:00"),
        FSMessage(id: "m2", text: "Yes! Verse 4 really stood out to me this time.",     mine: true,  sender: "",       timestamp: "2026-06-28T09:05:00"),
        FSMessage(id: "m3", text: "The valley of the shadow of death — walking through, not camping there.", mine: false, sender: "Marcus", timestamp: "2026-06-28T09:08:00"),
        FSMessage(id: "m4", text: "That's such a good point Marcus. See everyone Wednesday.", mine: true, sender: "", timestamp: "2026-06-28T09:12:00"),
    ]

    static let mockAgentMessages: [FSAgentMessage] = [
        FSAgentMessage(id: "am1", text: "Welcome! I'm here to help you explore Scripture. What are you studying today?", mine: false, timestamp: "2026-06-27T08:00:00"),
        FSAgentMessage(id: "am2", text: "I'm going through John chapter 1 and want to understand the concept of the Logos.", mine: true, timestamp: "2026-06-27T08:01:00"),
        FSAgentMessage(id: "am3", text: "The Logos in John 1 draws on both Jewish Wisdom tradition and Greek philosophical thought. John brilliantly redeems this concept by declaring that this eternal Word became flesh (v.14).", mine: false, timestamp: "2026-06-27T08:02:00"),
    ]

    static let mockSession = FSSession(
        id: "sess-001", title: "Wednesday Night Study",
        time_start: "2026-07-02T19:00:00", time_end: "2026-07-02T20:30:00",
        verses: ["John-1-1", "John-1-14"],
        prompts: ["What does it mean that the Word became flesh?"],
        recurring: true, summarize: true, group_id: "group-abc",
        creator_id: mockUser.user_id, participants: [mockUser.user_id]
    )

    // ── Protocol conformance ──────────────────────────────────────────────────

    // Auth
    func signIn(username: String, password: String) async throws -> FSUser {
        try await Task.sleep(nanoseconds: 600_000_000)
        guard username == "jacob" && password == "password" else {
            throw AppError.authFailed("Invalid username or password.")
        }
        return Self.mockUser
    }

    func signUp(username: String, email: String, password: String, termsAccepted: Bool) async throws -> FSUser {
        try await Task.sleep(nanoseconds: 600_000_000)
        guard termsAccepted else { throw AppError.authFailed("You must accept the Terms of Service to create an account.") }
        return FSUser(user_id: UUID().uuidString, username: username, email: email)
    }

    func signInWithGoogle(credential: String, termsAccepted: Bool) async throws -> FSUser {
        try await Task.sleep(nanoseconds: 600_000_000)
        return FSUser(user_id: UUID().uuidString, username: "google_user", email: "google@example.com")
    }

    func signInWithApple(identityToken: String, fullName: String?, email: String?, termsAccepted: Bool) async throws -> FSUser {
        try await Task.sleep(nanoseconds: 600_000_000)
        return FSUser(user_id: UUID().uuidString,
                      username: fullName ?? "apple_user",
                      email: email ?? "apple@example.com")
    }

    func acceptTerms(userId: String) async throws {}
    func logout() async throws {}

    func verifyMfaLogin(userId: String, code: String) async throws -> FSUser {
        try await Task.sleep(nanoseconds: 600_000_000)
        guard code == "123456" else { throw AppError.authFailed("Invalid or expired code.") }
        return Self.mockUser
    }
    func mfaEnable() async throws {}
    func mfaConfirm(code: String) async throws {}
    func mfaDisable(password: String) async throws {}

    func requestPasswordReset(email: String) async throws {}

    // User
    func fetchUser(userId: String) async throws -> FSUser {
        var freshUser = Self.mockUser
        freshUser.timezone = Self.mockFetchedTimezone
        return freshUser
    }
    func updateUser(userId: String, body: [String: String]) async throws -> FSUser { Self.mockUser }
    func deleteUser(userId: String) async throws {}

    // Notes
    func fetchNotes(userId: String) async throws -> [String: FSNote] { Self.mockNotes }
    func fetchGroupNotes(userId: String, groupId: String) async throws -> [String: FSNote] { [:] }

    func saveNote(_ note: FSNote, editingId: String?, userId: String) async throws -> String {
        editingId ?? note.id
    }

    func deleteNote(noteId: String, userId: String) async throws {}

    // Highlights
    func fetchHighlights(userId: String) async throws -> [String: String] { Self.mockHighlights }
    func saveHighlight(userId: String, book: String, chapter: Int, verse: Int, color: String) async throws {}
    func clearHighlight(userId: String, key: String) async throws {}

    // Bookmarks
    func fetchBookmarks(userId: String) async throws -> [String: String] { Self.mockBookmarks }
    func saveBookmark(userId: String, book: String, chapter: Int, label: String) async throws {}
    func removeBookmark(userId: String, key: String) async throws {}

    // Agents
    func fetchAgents(userId: String) async throws -> [FSAgent] { Self.mockAgents }

    func fetchAgentMessages(userId: String, agentId: String) async throws -> [FSAgentMessage] {
        Self.mockAgentMessages
    }

    func fetchHeartbeats(userId: String, agentId: String) async throws -> [FSHeartbeat] { [] }

    func createAgent(userId: String, role: String) async throws -> FSAgent {
        FSAgent(id: UUID().uuidString, user_id: userId, role: role, enabled: true, chats: [])
    }

    func updateAgent(userId: String, agentId: String, enabled: Bool) async throws {}
    func renameAgent(userId: String, agentId: String, name: String) async throws {}
    func deleteAgent(userId: String, agentId: String) async throws {}

    func addHeartbeat(userId: String, agentId: String, heartbeat: FSHeartbeat) async throws {}
    func deleteHeartbeat(userId: String, agentId: String, heartbeatId: String) async throws {}
    func updateHeartbeat(userId: String, heartbeatId: String, heartbeat: FSHeartbeat) async throws {}

    func commitHeartbeat(userId: String, agentId: String, heartbeatId: String, prompt: String) async throws -> [String: String] {
        ["success": "saved note"]
    }

    func summarizeSession(userId: String, agentId: String, session: FSSession, groupId: String) async throws {}

    // Contacts + messages
    func fetchContacts(userId: String) async throws -> ([FSContact], [String: FSGroup]) {
        let group = FSGroup(id: "group-abc", title: "Wednesday Night Study",
                           users: [userId, "friend-001", "friend-002"])
        return (Self.mockContacts, ["group-abc": group])
    }

    func fetchFriendMessages(userId: String, friendId: String) async throws -> [FSMessage] {
        Self.mockMessages
    }

    func fetchGroupMessages(userId: String, groupId: String) async throws -> [FSMessage] {
        Self.mockMessages
    }

    // Friends
    func fetchFriendRequests(userId: String) async throws -> [(id: String, username: String)] { [] }
    func sendFriendRequest(userId: String, username: String) async throws {}
    func acceptFriendRequest(userId: String, username: String) async throws {}
    func removeFriend(userId: String, friendId: String) async throws {}

    // Reports / Blocks (Guideline 1.2)
    func reportUser(reportedUserId: String, reason: String, detail: String) async throws {}
    func blockUser(userId: String, blockedId: String) async throws {}
    func unblockUser(userId: String, blockedId: String) async throws {}
    func fetchBlockedUsers(userId: String) async throws -> [FSBlockedUser] { [] }

    // Groups
    func createGroup(userId: String, groupId: String, title: String, users: [String]) async throws {}
    func updateGroup(userId: String, groupId: String, title: String, users: [String]) async throws {}
    func leaveGroup(userId: String, groupId: String) async throws {}

    // Sessions
    func fetchSessionsForContact(contactId: String) async throws -> [FSSession] { [Self.mockSession] }

    func createSession(userId: String, devotion: FSSession, contactId: String) async throws -> String {
        UUID().uuidString
    }

    func updateSession(userId: String, sessionId: String, devotion: FSSession) async throws {}
    func deleteSession(userId: String, sessionId: String, devotion: FSSession) async throws {}
    func joinSession(userId: String, sessionId: String) async throws {}
    func leaveSession(userId: String, sessionId: String) async throws {}

    // Notifications
    func fetchNotifications(userId: String) async throws -> [FSNotification] { [] }

    func createNotification(userId: String, name: String, prompt: String, timestamps: [String?]) async throws -> FSNotification {
        FSNotification(id: UUID().uuidString, user_id: userId, name: name, prompt: prompt, timestamps: timestamps)
    }

    func updateNotification(userId: String, notifId: String, name: String, prompt: String, timestamps: [String?]) async throws {}
    func deleteNotification(userId: String, notifId: String) async throws {}
    func registerDeviceToken(userId: String, token: String) async throws {}
    func triggerNotification(userId: String, notifId: String) async throws -> [String: String] {
        ["name": "FellowScript", "content": "This is a sample notification."]
    }

    func joinCall(userId: String, sessionId: String) async throws -> ChimeJoinResponse {
        throw AppError.networkError("Calls are not available in preview mode.")
    }

    // Subscriptions
    //
    // UI-TESTING-SUBSCRIBED (additive test-only launch argument, task:
    // 20260814-subscription-benefits-detail): lets AccountUITests drive the
    // active-subscriber branch of subscriptionSection (activePlanRow +
    // benefitsDisclosure) end-to-end. Gated behind its own separate launch
    // argument (checked only here, in addition to the existing "UI-TESTING"
    // argument FellowScriptApp already reads to select MockDataService) so
    // every other UI/unit test — including this file's own no-active-plan
    // default — keeps getting the pre-existing `nil` behavior unless a test
    // opts in explicitly.
    private static var isUITestingSubscribed: Bool {
        ProcessInfo.processInfo.arguments.contains("UI-TESTING-SUBSCRIBED")
    }
    static let mockActiveSubscription = FSSubscription(
        id: "sub-mock-001", user_id: mockUser.user_id, plan_type: "group",
        status: "active", price_cents: 2699, max_members: 3
    )
    // Mirrors the real backend's usage_summary() shape exactly (api/backend/
    // subscription/limits.py:105-116): even for a subscribed user, `limit`
    // stays populated with the FREE_LIMITS reference number (not zeroed out)
    // alongside `unlimited: true` — that's what lets benefitRow's "Free
    // plan: N" captions read as an intentional comparison ("here's what
    // you'd be capped at without this plan"), not a stale/blank value.
    static let mockActiveUsage = FSUsage(
        subscribed: true, plan_type: "group", window_days: 7,
        resources: [
            "notes":               FSUsageResource(unlimited: true, used: 0, limit: 10, remaining: nil),
            "agent_events":        FSUsageResource(unlimited: true, used: 0, limit: 1,  remaining: nil),
            "agent_notifications": FSUsageResource(unlimited: true, used: 0, limit: 3,  remaining: nil),
        ]
    )
    func fetchUsage(userId: String) async throws -> FSUsage? {
        Self.isUITestingSubscribed ? Self.mockActiveUsage : nil
    }
    func fetchUserSubscription(userId: String) async throws -> FSSubscription? {
        Self.isUITestingSubscribed ? Self.mockActiveSubscription : nil
    }
    func startSubscription(userId: String, memberCount: Int, billing: FSBillingInfo?) async throws -> String { UUID().uuidString }
    func updateSubscriptionSeats(subscriptionId: String, memberCount: Int) async throws {}
    func cancelSubscription(subscriptionId: String) async throws {}
    func fetchSubMembers(subscriptionId: String) async throws -> [FSSubMember] { [] }
    func removeSubMember(subscriptionId: String, userId: String) async throws {}
    func fetchSubRequests(subscriptionId: String) async throws -> [FSSubMember] { [] }
    func fetchMySubRequests(userId: String) async throws -> [FSSubRequest] { [] }
    func requestJoinSubscription(subscriptionId: String, fromUserId: String) async throws {}
    func acceptSubRequest(subscriptionId: String, fromUserId: String) async throws {}
    func declineSubRequest(subscriptionId: String, fromUserId: String) async throws {}
    func syncAppleSubscription(userId: String, jws: String) async throws -> FSSubscription? { nil }
}

// ── AppError ──────────────────────────────────────────────────────────────────
enum AppError: LocalizedError {
    case authFailed(String)
    case networkError(String)
    case limitReached(resource: String, used: Int, limit: Int)
    case notFound
    // Not really an error — signIn() throws this to signal the login should
    // pause for an emailed 2FA code instead of completing. AuthView catches
    // this case specifically and navigates to the verify screen.
    case mfaRequired(userId: String)

    var errorDescription: String? {
        switch self {
        case .authFailed(let m):   return m
        case .networkError(let m): return m
        case .mfaRequired:         return "Two-factor authentication code required."
        case .limitReached(let resource, _, let limit):
            let name: String
            switch resource {
            case "notes":               name = "notes"
            case "agent_events":        name = "agent events"
            case "agent_notifications": name = "agent notifications"
            default:                    name = resource
            }
            return "You've reached your free plan limit for \(name) (max \(limit)). "
                 + "Upgrade to a Group plan for unlimited access."
        case .notFound:            return "Resource not found."
        }
    }
}
