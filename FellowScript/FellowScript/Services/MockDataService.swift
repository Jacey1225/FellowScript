// SOURCE: frontend/src/context/AuthContext.jsx, all hooks
// DEPENDENCY: Models.swift
// Provides realistic stub data so the UI renders without a live backend.
// Conforms to DataServiceProtocol so NetworkService can replace it transparently.

import Foundation

// ── Notes pagination ─────────────────────────────────────────────────────────

/// One backend-capped (15-per-request) keyset-paginated page of notes, as
/// returned by GET /notes/{userId} and GET /{userId}/{groupId}/notes.
/// `nextCursorCreatedAt`/`nextCursorId` anchor the following page to this
/// page's last row's own (created_at, _id) rather than a row *position* --
/// pass them straight back as the next call's cursor params. `hasMore` is
/// true iff this page came back full (== NOTES_PAGE_SIZE rows); false means
/// the true end of the list, so the caller should stop paging even though a
/// cursor may still be present.
struct NotesPage {
    var notes:               [String: FSNote]
    var nextCursorCreatedAt: String?
    var nextCursorId:        String?
    var hasMore:             Bool
}

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

    // Notes (read) -- every GET-notes call is capped server-side (SQL LIMIT,
    // not client-side slicing) at NOTES_PAGE_SIZE (15) and keyset-paginated;
    // pass a previous page's nextCursorCreatedAt/nextCursorId back to fetch
    // the following page, or nil/nil for the first page. There is no
    // unpaginated full-fetch mode -- fetchNotesCount below is the dedicated
    // path for callers that only need a total.
    func fetchNotes(userId: String, cursorCreatedAt: String?, cursorId: String?) async throws -> NotesPage
    func fetchGroupNotes(userId: String, groupId: String, cursorCreatedAt: String?, cursorId: String?) async throws -> NotesPage
    func fetchNotesCount(userId: String) async throws -> Int

    // Notes (keyword search) -- task 20260903-notes-keyword-search. Segment-
    // scoped exactly like fetchNotes/fetchGroupNotes above (Personal vs a
    // specific group), matching title/text. Unlike those, this is bounded
    // by the query itself rather than a keyset page, so it returns every
    // match in one flat dict -- no cursor, no hasMore.
    func searchNotes(userId: String, query: String) async throws -> [String: FSNote]
    func searchGroupNotes(userId: String, groupId: String, query: String) async throws -> [String: FSNote]

    // Notes (single fetch by id) -- task 20260903-friend-activity-note-navigation.
    // Backs the Friend Activity hero card's note-preview tap target: fetches
    // one note the caller may not own (a friend's shared group note), so
    // unlike the segment-scoped reads above this is permission-checked
    // server-side per-call (GET /notes/{user_id}/note/{note_id}, `user_id`
    // is the *viewer*) rather than merely scoped to the caller's own notes.
    // Throws AppError.networkError with the identical user-facing message
    // for both a missing note and one the viewer can no longer see -- the
    // server returns the identical response for both, so the client can't
    // and shouldn't try to distinguish them either.
    func fetchNote(userId: String, noteId: String) async throws -> FSNote

    // Notes (write)
    func saveNote(_ note: FSNote, editingId: String?, userId: String) async throws -> String
    func deleteNote(noteId: String, userId: String) async throws

    // Notes (replies) -- NoteDetailView's Option A reply section. Route to
    // the group or personal replies endpoint depending on whether groupId
    // is empty (pass note.group_id straight through). reply.user in
    // postReply must be the authenticated caller (the backend 403s
    // otherwise); callers append the returned id locally rather than
    // refetching, mirroring saveNote's optimistic id-swap pattern above.
    func fetchReplies(userId: String, noteId: String, groupId: String) async throws -> [FSNote]
    func postReply(_ reply: FSNote, noteId: String) async throws -> String

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
    // Always a forced/manual fire server-side (see NetworkService's
    // implementation) — the only caller is the "execute now" trigger, which
    // per task 20260901-heartbeat-manual-force-fire must succeed regardless
    // of any earlier fire today. A successful call returns {"success": ...};
    // a skip now only means the narrower same-instant concurrent-forced-fire
    // race, e.g. {"skipped": "a forced fire for this event is already in
    // progress"} — it can no longer mean "already fired today".
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
    // Dashboard's Friend Activity hero card -- friend-only, block-respecting
    // read of each friend's most recent public note + a "check in" nudge
    // candidate. See FSFriendActivityFeed for the response shape.
    func fetchFriendActivity(userId: String) async throws -> FSFriendActivityFeed

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

    // Notifications (device-token registration + push delivery only — the
    // user-authored notification CRUD/trigger surface was removed in
    // 20260826-ios-notification-ui-removal, matching the backend removal in
    // 20260826-activity-based-notifications)
    func registerDeviceToken(userId: String, token: String) async throws

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
        // Long personal note (task 20260829-note-detail-toolbar-edge-blur,
        // testing gate): a dedicated long-body fixture, newest timestamp so
        // it sorts to the top of the Notes list, purely so
        // NoteDetailToolbarEdgeBlurUITests has a body tall enough to actually
        // reach the top of the ScrollView underneath NoteDetailView's
        // feathered toolbar scrim -- none of the four notes above are long
        // enough to exercise the anti-scroll-collision guard this task's
        // acceptance criteria requires confirming live. Additive only: no
        // existing test asserts on MockDataService.mockNotes' count or this
        // note's absence (checked: the "Pastor Ed"/"Sunday Service" fixtures
        // referenced by DashboardEmptyStateTests/NoteResumeCardContinueIslandTests
        // construct their own independent FSNote literals, not this dictionary).
        let n5 = FSNote(
            id: "note-long-001", user: mockUser.user_id,
            title: "Long-Form Study Notes",
            text: Array(repeating:
                "Pastor Ed continued the study on the courage of faith, walking verse by verse through the passage and drawing out how complete dependence on God shaped every decision David made before the battle. ",
                count: 40).joined(),
            public: false, group_id: "", is_reply: false,
            timestamp: "2026-08-29 08:00:00",
            verses: [[.string("1 Samuel"), .int(23), .int(2)]], replies: []
        )
        // Group note authored by someone else (screenshot pass for tasks
        // 20260829-notes-edit-author-gate and 20260829-notes-first-reply-
        // empty-state -- neither task ever got a retained on-device
        // screenshot). The only pre-existing group note (note-grp-001) is
        // authored by the current mock user with `username` left unset
        // entirely, which only ever exercises NotesListView.isAuthor /
        // NoteDetailView.canEdit's deny-by-default "undecoded author"
        // fallback -- never the genuine "someone else's note" comparison
        // branch those gates exist for. This fixture is explicitly authored
        // by a different mock user (Sarah) so both gates render their real,
        // intended state live: no Edit/Delete affordance in NotesListView's
        // swipe/context-menu or NoteDetailView's toolbar. It also has zero
        // replies (absent from mockReplies below), covering the first-reply
        // empty-state fixture need with the same note. Additive only, same
        // reasoning as note-long-001 above -- no existing test asserts on
        // MockDataService.mockNotes' count or this note's absence.
        let n6 = FSNote(
            id: "note-grp-002", user: "friend-001", username: "Sarah",
            title: "Wednesday Group Reflections",
            text: "<p>What stood out to everyone from this week's passage?</p>",
            public: true, group_id: "group-abc", is_reply: false,
            timestamp: "2026-08-20T09:00:00Z",
            verses: [[.string("Romans"), .int(8), .int(6)]], replies: []
        )
        return ["note-001": n1, "note-002": n2, "note-003": n3, "note-grp-001": n4, "note-long-001": n5, "note-grp-002": n6]
    }()

    // Keyed by parent note id. Exercises NoteDetailView's Option A reply
    // section in previews/UI tests: two authored replies plus one
    // author-less reply (empty username -- a real backend state, not
    // hypothetical, per FSNote.username's doc comment) so the card's
    // omit-monogram-and-name fallback gets covered without a live backend.
    static let mockReplies: [String: [FSNote]] = [
        "note-grp-001": [
            FSNote(id: "reply-001", user: "friend-001", username: "Sarah",
                   title: "", text: "This really convicted me this week — I keep defaulting to a flesh mindset without even noticing it.",
                   public: true, group_id: "group-abc", is_reply: true,
                   timestamp: "2026-07-08T11:02:00Z"),
            FSNote(id: "reply-002", user: "friend-002", username: "Marcus",
                   title: "", text: "Good breakdown. I think verse 6 ties right back into this too.",
                   public: true, group_id: "group-abc", is_reply: true,
                   timestamp: "2026-07-08T13:40:00Z"),
            FSNote(id: "reply-003", user: "", username: "",
                   title: "", text: "Amen to this.",
                   public: true, group_id: "group-abc", is_reply: true,
                   timestamp: "2026-07-08T15:00:00Z"),
        ],
    ]

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

    // Mirrors the mockup's placeholder copy ("Sarah wrote a note today" /
    // "Check in with Sarah · It's been 6 days"), sourced from mock friends
    // "friend-001"/"friend-002" (Sarah/Marcus) so the Dashboard preview reads
    // identically to the finalized Editorial Hero design.
    static let mockFriendActivity = FSFriendActivityFeed(
        friends_active: [
            FSFriendActivityEntry(
                friend_id: "friend-001", username: "Sarah",
                last_active_at: "2026-08-26T09:14:00Z",
                activity_type: "note_created",
                note_preview: FSFriendNotePreview(
                    note_id: "note-sarah-001", title: "Morning reflection",
                    text: "Started reading Psalm 23 again this morning. Reminded me how much I need to slow down and actually listen instead of just reading…",
                    timestamp: "2026-08-26T09:14:00Z"
                ),
                highlight_preview: nil
            ),
            // Task 20260904-friend-activity-push-triggers: demonstrates the
            // new verse_highlighted entry shape (real verse content via
            // highlight_preview, Round 2's friendship-alone visibility
            // widening) in previews/mock-mode rather than only note-backed
            // entries.
            FSFriendActivityEntry(
                friend_id: "friend-002", username: "Marcus",
                last_active_at: "2026-08-24T18:40:00Z",
                activity_type: "verse_highlighted",
                note_preview: nil,
                highlight_preview: FSFriendHighlightPreview(
                    book: "Romans", chapter: 8, verse: 28,
                    color: "#5B9BD5",
                    verse_text: "And we know that in all things God works for the good of those who love him, who have been called according to his purpose.",
                    timestamp: "2026-08-24T18:40:00Z"
                )
            ),
        ],
        check_in_candidates: [
            FSCheckInCandidate(friend_id: "friend-001", username: "Sarah", days_since_contact: 6),
            FSCheckInCandidate(friend_id: "friend-002", username: "Marcus", days_since_contact: 12),
        ]
    )

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

    // Demo Events (heartbeat) fixture — task 20260902-onboarding-tour-real-
    // screenshots. AccountView's Events section (vm.events, populated from
    // fetchHeartbeats) previously always rendered empty ("No events yet.")
    // under MockDataService, which is a real gap for the onboarding tour's
    // EVENTS step: its screenshot must show populated, representative
    // content, not an empty state. One-off seeding only, per the intake
    // spec's explicitly in-scope allowance ("Any one-off seeding of a demo/
    // sample account's content ... a scheduled event ... purely so the
    // screenshots look populated") — not a durable feature change. All 31
    // timestamps slots filled so `scheduleSummary` reads "Every day",
    // matching the daily-devotional framing already used by the tour's
    // (now-deleted) hand-drawn MockHeartbeat mock.
    static let mockHeartbeat = FSHeartbeat(
        id: "heartbeat-001", agent_id: mockAgents[0].id, user_id: mockUser.user_id,
        timestamps: Array(repeating: "13:00", count: 31),
        prompt: "Reflect on a Psalm and how God's faithfulness applies to my day.",
        group_id: nil
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

    // Notes -- the mock fixture set is well under one page, so every mock
    // "page" is the whole (small) collection with hasMore false, regardless
    // of the cursor passed in.
    func fetchNotes(userId: String, cursorCreatedAt: String?, cursorId: String?) async throws -> NotesPage {
        NotesPage(notes: Self.mockNotes, nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
    }
    func fetchGroupNotes(userId: String, groupId: String, cursorCreatedAt: String?, cursorId: String?) async throws -> NotesPage {
        NotesPage(notes: [:], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
    }
    func fetchNotesCount(userId: String) async throws -> Int { Self.mockNotes.count }

    // Keyword search over the same small mock fixture set -- case-insensitive
    // substring match against title/text, mirroring the backend's ILIKE
    // behavior closely enough for previews/tests that run against this mock.
    func searchNotes(userId: String, query: String) async throws -> [String: FSNote] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [:] }
        return Self.mockNotes.filter { _, note in
            note.title.lowercased().contains(q) || note.text.lowercased().contains(q)
        }
    }
    func searchGroupNotes(userId: String, groupId: String, query: String) async throws -> [String: FSNote] { [:] }

    // Mirrors the real endpoint's IDOR-safe contract: a missing/unknown id
    // throws the same AppError.notFound a not-visible-to-this-viewer note
    // would, so previews/tests exercising the tap-to-open flow's error path
    // don't need a second mock fixture set to simulate "denied" separately
    // from "doesn't exist" -- the server never lets the client tell them
    // apart either.
    func fetchNote(userId: String, noteId: String) async throws -> FSNote {
        guard let note = Self.mockNotes[noteId] else {
            throw AppError.networkError("That note is no longer available.")
        }
        return note
    }

    func saveNote(_ note: FSNote, editingId: String?, userId: String) async throws -> String {
        editingId ?? note.id
    }

    func deleteNote(noteId: String, userId: String) async throws {}

    func fetchReplies(userId: String, noteId: String, groupId: String) async throws -> [FSNote] {
        Self.mockReplies[noteId] ?? []
    }

    func postReply(_ reply: FSNote, noteId: String) async throws -> String {
        UUID().uuidString
    }

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

    func fetchHeartbeats(userId: String, agentId: String) async throws -> [FSHeartbeat] {
        agentId == Self.mockHeartbeat.agent_id ? [Self.mockHeartbeat] : []
    }

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
    func fetchFriendActivity(userId: String) async throws -> FSFriendActivityFeed { Self.mockFriendActivity }

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
    func registerDeviceToken(userId: String, token: String) async throws {}

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
            "notes":        FSUsageResource(unlimited: true, used: 0, limit: 10, remaining: nil),
            "agent_events": FSUsageResource(unlimited: true, used: 0, limit: 1,  remaining: nil),
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
            case "notes":        name = "notes"
            case "agent_events": name = "agent events"
            default:             name = resource
            }
            return "You've reached your free plan limit for \(name) (max \(limit)). "
                 + "Upgrade to a Group plan for unlimited access."
        case .notFound:            return "Resource not found."
        }
    }
}
