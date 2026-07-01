// SOURCE: frontend/src/context/AuthContext.jsx, all hooks
// DEPENDENCY: Models.swift
// Provides realistic stub data so the UI renders without a live backend.
// Conforms to DataServiceProtocol so a real NetworkService can replace it.

import Foundation

protocol DataServiceProtocol {
    func signIn(username: String, password: String) async throws -> FSUser
    func signUp(username: String, email: String, password: String) async throws -> FSUser
    func fetchNotes(userId: String) async throws -> [String: FSNote]
    func fetchHighlights(userId: String) async throws -> [String: String]
    func fetchBookmarks(userId: String) async throws -> [String: String]
    func fetchAgents(userId: String) async throws -> [FSAgent]
    func fetchContacts(userId: String) async throws -> ([FSContact], [String: FSGroup])
    func fetchMessages(contactId: String, userId: String, isGroup: Bool) async throws -> [FSMessage]
    func fetchSessions(userId: String, groupId: String) async throws -> [FSSession]
}

// ── Mock data ─────────────────────────────────────────────────────────────────

final class MockDataService: DataServiceProtocol {

    static let shared = MockDataService()
    private init() {}

    // Pre-built mock user
    static let mockUser = FSUser(
        user_id:  "60aa9553-b147-4e09-9a6e-b3e3abcf57f0",
        username: "jacob",
        email:    "jacob@example.com",
        friends:  ["friend-001", "friend-002"],
        groups:   ["group-abc"],
        notes:    [:],
        highlights: [:]
    )

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
            text: "<b>The Lord is my shepherd</b> — what does it mean to lack nothing? True provision is spiritual sufficiency, not material abundance.",
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-06-22 09:30:00",
            verses: [[.string("Psalms"), .int(23), .int(1)]], replies: []
        )
        let n3 = FSNote(
            id: "note-003", user: mockUser.user_id,
            title: "Grace and Truth",
            text: "John opens with the Word becoming flesh. Grace and truth came through Jesus Christ — two qualities that seem in tension but are perfectly unified in Him.",
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-06-15 18:45:00",
            verses: [[.string("John"), .int(1), .int(14)]], replies: []
        )
        return ["note-001": n1, "note-002": n2, "note-003": n3]
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
        FSContact(id: "group-abc",  name: "Wednesday Night Study", type: .group, preview: "Session tomorrow at 7pm", toUsers: [mockUser.user_id, "friend-001", "friend-002"]),
    ]

    static let mockMessages: [FSMessage] = [
        FSMessage(id: "m1", text: "Did everyone finish the Psalm 23 reading?", mine: false, sender: "Sarah", timestamp: "2026-06-28T09:00:00"),
        FSMessage(id: "m2", text: "Yes! Verse 4 really stood out to me this time.", mine: true, sender: "", timestamp: "2026-06-28T09:05:00"),
        FSMessage(id: "m3", text: "The valley of the shadow of death — walking through, not camping there.", mine: false, sender: "Marcus", timestamp: "2026-06-28T09:08:00"),
        FSMessage(id: "m4", text: "That's such a good point Marcus. See everyone Wednesday.", mine: true, sender: "", timestamp: "2026-06-28T09:12:00"),
    ]

    static let mockAgentMessages: [FSAgentMessage] = [
        FSAgentMessage(id: "am1", text: "Welcome! I'm here to help you explore Scripture. What are you studying today?", mine: false, timestamp: "2026-06-27T08:00:00"),
        FSAgentMessage(id: "am2", text: "I'm going through John chapter 1 and want to understand the concept of the Logos.", mine: true, timestamp: "2026-06-27T08:01:00"),
        FSAgentMessage(id: "am3", text: "The Logos in John 1 draws on both Jewish Wisdom tradition (Proverbs 8, Wisdom of Solomon) and Greek philosophical thought — particularly Stoic logos as the rational principle sustaining creation. John brilliantly redeems this concept by declaring that this eternal Word *became flesh* (v.14), grounding the abstract in the historical person of Jesus.", mine: false, timestamp: "2026-06-27T08:02:00"),
    ]

    static let mockSession = FSSession(
        id: "sess-001",
        title: "Wednesday Night Study",
        time_start: "2026-07-02T19:00:00",
        time_end:   "2026-07-02T20:30:00",
        verses: ["John-1-1", "John-1-14"],
        prompts: ["What does it mean that the Word became flesh?", "How does grace and truth operate together in Jesus?"],
        recurring: true, summarize: true, group_id: "group-abc"
    )

    // ── Protocol conformance ──────────────────────────────────────────────────

    func signIn(username: String, password: String) async throws -> FSUser {
        try await Task.sleep(nanoseconds: 600_000_000)
        guard username == "jacob" && password == "password" else {
            throw AppError.authFailed("Invalid username or password.")
        }
        return Self.mockUser
    }

    func signUp(username: String, email: String, password: String) async throws -> FSUser {
        try await Task.sleep(nanoseconds: 600_000_000)
        return FSUser(user_id: UUID().uuidString, username: username, email: email)
    }

    func fetchNotes(userId: String) async throws -> [String: FSNote] {
        return Self.mockNotes
    }

    func fetchHighlights(userId: String) async throws -> [String: String] {
        return Self.mockHighlights
    }

    func fetchBookmarks(userId: String) async throws -> [String: String] {
        return Self.mockBookmarks
    }

    func fetchAgents(userId: String) async throws -> [FSAgent] {
        return Self.mockAgents
    }

    func fetchContacts(userId: String) async throws -> ([FSContact], [String: FSGroup]) {
        let group = FSGroup(id: "group-abc", title: "Wednesday Night Study", users: [userId, "friend-001", "friend-002"])
        return (Self.mockContacts, ["group-abc": group])
    }

    func fetchMessages(contactId: String, userId: String, isGroup: Bool) async throws -> [FSMessage] {
        return Self.mockMessages
    }

    func fetchSessions(userId: String, groupId: String) async throws -> [FSSession] {
        return [Self.mockSession]
    }
}

// ── AppError ──────────────────────────────────────────────────────────────────
enum AppError: LocalizedError {
    case authFailed(String)
    case networkError(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .authFailed(let m):  return m
        case .networkError(let m): return m
        case .notFound:           return "Resource not found."
        }
    }
}
