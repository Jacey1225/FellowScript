// Real network layer. Conforms to DataServiceProtocol.
// Swap into AppState.init(service:) to go live:
//   AppState(service: NetworkService.shared)
// All endpoint paths mirror frontend/src/hooks/* and frontend/src/pages/Account.jsx.

import Foundation

final class NetworkService: DataServiceProtocol {
    static let shared = NetworkService()
    private init() {}

    let apiBase = "https://fellowscript.com/api"
    let wsBase  = "wss://fellowscript.com/api"

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func url(_ path: String) -> URL {
        URL(string: apiBase + path)!
    }

    private func get(_ path: String) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url(path))
        return data
    }

    private func request(_ path: String, method: String, body: Encodable? = nil) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        try throwIfError(response, data)
        return data
    }

    private func requestRaw(_ path: String, method: String, jsonObject: Any) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    /// Like `requestRaw` but validates the HTTP status. Use for writes that must
    /// surface backend rejections (e.g. free-tier 403 limits) instead of silently
    /// swallowing them.
    private func checkedRequestRaw(_ path: String, method: String, jsonObject: Any) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        let (data, response) = try await URLSession.shared.data(for: req)
        try throwIfError(response, data)
        return data
    }

    /// Maps an error response to a typed AppError. A 403 whose `detail` is the
    /// LimitsManager gate dict becomes `.limitReached`; anything else with a
    /// string detail becomes `.networkError`.
    private func throwIfError(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode == 403, let gate = body?["detail"] as? [String: Any],
           let resource = gate["resource"] as? String {
            throw AppError.limitReached(
                resource: resource,
                used:  gate["used"]  as? Int ?? 0,
                limit: gate["limit"] as? Int ?? 0
            )
        }
        let detail = body?["detail"] as? String
        throw AppError.networkError(detail ?? "Server error \(http.statusCode)")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    /// FastAPI's `detail` is a plain string for our own `HTTPException(...)` raises,
    /// but a pydantic field_validator rejection (e.g. SignUp's terms_accepted check)
    /// surfaces as the framework's default array shape:
    /// `{"detail": [{"loc": [...], "msg": "...", "type": "..."}]}`. Handle both so
    /// the user sees the real message either way, not a generic fallback.
    private func extractErrorDetail(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = obj["detail"] as? String { return s }
        if let arr = obj["detail"] as? [[String: Any]], let msg = arr.first?["msg"] as? String { return msg }
        return nil
    }

    // ── Auth ──────────────────────────────────────────────────────────────────

    func signIn(username: String, password: String) async throws -> FSUser {
        let data = try await requestRaw("/login", method: "POST",
                                        jsonObject: ["username": username, "plain_pass": password])
        // 2FA-enabled accounts get {"mfa_required": true, "user_id": ...} instead
        // of a full user — check for that shape before attempting FSUser decode,
        // which would otherwise just fail (username/email are required fields).
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["mfa_required"] as? Bool == true, let uid = obj["user_id"] as? String {
            throw AppError.mfaRequired(userId: uid)
        }
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Sign in failed.")
        }
        return user
    }

    func signUp(username: String, email: String, password: String, termsAccepted: Bool) async throws -> FSUser {
        let data = try await requestRaw("/signup", method: "POST",
                                        jsonObject: ["username": username, "email": email, "plain_pass": password,
                                                     "terms_accepted": termsAccepted])
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Sign up failed.")
        }
        return user
    }

    func signInWithGoogle(credential: String, termsAccepted: Bool) async throws -> FSUser {
        let data = try await requestRaw("/auth/google", method: "POST",
                                        jsonObject: ["credential": credential, "terms_accepted": termsAccepted])
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Google sign-in failed.")
        }
        return user
    }

    func signInWithApple(identityToken: String, fullName: String?, email: String?, termsAccepted: Bool) async throws -> FSUser {
        var body: [String: Any] = ["identity_token": identityToken, "terms_accepted": termsAccepted]
        // fullName / email are only sent on the first authorization; omit when nil
        // so the server keeps whatever it captured the first time.
        if let fullName { body["full_name"] = fullName }
        if let email    { body["email"]     = email }
        let data = try await requestRaw("/auth/apple", method: "POST", jsonObject: body)
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Apple sign-in failed.")
        }
        return user
    }

    /// Records acceptance of the current Terms version after a `terms_reaccept_required`
    /// response — see FSUser.terms_reaccept_required.
    func acceptTerms(userId: String) async throws {
        _ = try await request("/user/\(userId)/accept-terms", method: "POST")
    }

    // ── Two-factor authentication (email code) ──────────────────────────────────

    /// Completes a login paused by signIn()'s `.mfaRequired` — verifies the
    /// emailed 6-digit code and returns the same shape a normal login would.
    func verifyMfaLogin(userId: String, code: String) async throws -> FSUser {
        let data = try await requestRaw("/auth/mfa/verify-login", method: "POST",
                                        jsonObject: ["user_id": userId, "code": code])
        guard let user = decode(FSUser.self, from: data) else {
            throw AppError.authFailed(extractErrorDetail(from: data) ?? "Invalid or expired code.")
        }
        return user
    }

    /// Starts turning 2FA on: emails a confirmation code. Does not enable 2FA
    /// yet — call mfaConfirm(code:) with it to finish.
    func mfaEnable() async throws {
        _ = try await checkedRequestRaw("/auth/mfa/enable", method: "POST", jsonObject: [:])
    }

    func mfaConfirm(code: String) async throws {
        _ = try await checkedRequestRaw("/auth/mfa/confirm", method: "POST", jsonObject: ["code": code])
    }

    /// Requires the current password so a hijacked/unattended session can't
    /// silently remove the account's second factor.
    func mfaDisable(password: String) async throws {
        _ = try await checkedRequestRaw("/auth/mfa/disable", method: "POST", jsonObject: ["plain_pass": password])
    }

    // ── Password reset ───────────────────────────────────────────────────────────

    /// Always succeeds from the caller's perspective regardless of whether the
    /// email has an account — the backend never reveals account existence.
    func requestPasswordReset(email: String) async throws {
        _ = try await requestRaw("/auth/password-reset/request", method: "POST", jsonObject: ["email": email])
    }

    // ── User ──────────────────────────────────────────────────────────────────
    // GET  /user/{userId}
    // PUT  /user/{userId}   body: {username?, email?, plain_pass?, timezone?}
    // DELETE /user/{userId}

    func fetchUser(userId: String) async throws -> FSUser {
        let data = try await get("/user/\(userId)")
        return decode(FSUser.self, from: data) ?? FSUser(user_id: userId, username: "", email: "")
    }

    func updateUser(userId: String, body: [String: String]) async throws -> FSUser {
        let data = try await requestRaw("/user/\(userId)", method: "PUT", jsonObject: body)
        guard let user = decode(FSUser.self, from: data) else {
            let detail = decode([String: String].self, from: data)?["detail"] ?? "Update failed."
            throw AppError.networkError(detail)
        }
        return user
    }

    func deleteUser(userId: String) async throws {
        _ = try await request("/user/\(userId)", method: "DELETE")
    }

    // ── Notes (read) ──────────────────────────────────────────────────────────
    // GET /notes/{userId}

    func fetchNotes(userId: String) async throws -> [String: FSNote] {
        let data = try await get("/notes/\(userId)")
        guard var dict = decode([String: FSNote].self, from: data) else { return [:] }
        for (key, var note) in dict { note.id = key; dict[key] = note }
        return dict
    }

    func fetchGroupNotes(userId: String, groupId: String) async throws -> [String: FSNote] {
        let raw = try await get("/groups/\(userId)/\(groupId)/notes")
        // Response shape: { username: { note_id: { user_id, title, text, public, group_id, is_reply, timestamp } } }
        guard let outer = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return [:] }

        var result: [String: FSNote] = [:]
        for (_, byNote) in outer {
            guard let noteMap = byNote as? [String: Any] else { continue }
            for (noteId, rawFields) in noteMap {
                guard var fields = rawFields as? [String: Any] else { continue }
                // The DB column is "user_id"; FSNote.CodingKey is "user"
                fields["user"]     = fields["user_id"] ?? ""
                fields["id"]       = noteId
                fields["group_id"] = groupId
                // Ensure these keys exist so FSNote decodes cleanly
                if fields["verses"]  == nil { fields["verses"]  = [[Any]]() }
                if fields["replies"] == nil { fields["replies"] = [Any]() }
                fields.removeValue(forKey: "user_id")
                guard let noteData = try? JSONSerialization.data(withJSONObject: fields),
                      var note = decode(FSNote.self, from: noteData) else { continue }
                note.id       = noteId
                note.group_id = groupId
                result[noteId] = note
            }
        }
        return result
    }

    // ── Notes (write) ─────────────────────────────────────────────────────────
    // POST /notes/{userId}                      body: FSNote fields
    // PUT  /notes/{userId}?note_id={id}         body: FSNote fields
    // DELETE /notes/{userId}?note_id={id}

    func saveNote(_ note: FSNote, editingId: String?, userId: String) async throws -> String {
        let path = editingId.map { "/notes/\(userId)?note_id=\(encodeURIComponent($0))" }
                 ?? "/notes/\(userId)"
        let method = editingId != nil ? "PUT" : "POST"
        let data = try await request(path, method: method, body: note)
        // Backend returns {id: "..."} on POST
        if let resp = decode([String: String].self, from: data), let id = resp["id"] { return id }
        return editingId ?? note.id
    }

    func deleteNote(noteId: String, userId: String) async throws {
        _ = try await request("/notes/\(userId)?note_id=\(encodeURIComponent(noteId))", method: "DELETE")
    }

    // ── Highlights ────────────────────────────────────────────────────────────
    // GET    /notes/highlight/{userId}
    // POST   /notes/highlight/{userId}             body: {book, chapter, verse, color}
    // DELETE /notes/highlight/{userId}/{encodedKey}

    func fetchHighlights(userId: String) async throws -> [String: String] {
        let data = try await get("/notes/highlight/\(userId)")
        return decode([String: String].self, from: data) ?? [:]
    }

    func saveHighlight(userId: String, book: String, chapter: Int, verse: Int, color: String) async throws {
        _ = try await requestRaw("/notes/highlight/\(userId)", method: "POST",
                                  jsonObject: ["book": book, "chapter": chapter, "verse": verse, "color": color])
    }

    func clearHighlight(userId: String, key: String) async throws {
        _ = try await request("/notes/highlight/\(userId)/\(encodeURIComponent(key))", method: "DELETE")
    }

    // ── Bookmarks ─────────────────────────────────────────────────────────────
    // GET    /notes/bookmark/{userId}
    // POST   /notes/bookmark/{userId}             body: {book, chapter, label}
    // DELETE /notes/bookmark/{userId}/{encodedKey}

    func fetchBookmarks(userId: String) async throws -> [String: String] {
        let data = try await get("/notes/bookmark/\(userId)")
        return decode([String: String].self, from: data) ?? [:]
    }

    func saveBookmark(userId: String, book: String, chapter: Int, label: String) async throws {
        _ = try await requestRaw("/notes/bookmark/\(userId)", method: "POST",
                                  jsonObject: ["book": book, "chapter": chapter, "label": label])
    }

    func removeBookmark(userId: String, key: String) async throws {
        _ = try await request("/notes/bookmark/\(userId)/\(encodeURIComponent(key))", method: "DELETE")
    }

    // ── Agents (read) ─────────────────────────────────────────────────────────
    // GET /agent/{userId}
    // GET /agent/{userId}/{agentId}/messages
    // GET /agent/{userId}/{agentId}/heartbeats

    func fetchAgents(userId: String) async throws -> [FSAgent] {
        let data = try await get("/agent/\(userId)")
        guard let dict = decode([String: FSAgent].self, from: data) else { return [] }
        return dict.map { key, val in
            FSAgent(id: key, user_id: val.user_id, name: val.name,
                    role: val.role, enabled: val.enabled, chats: val.chats)
        }
    }

    func fetchAgentMessages(userId: String, agentId: String) async throws -> [FSAgentMessage] {
        let data = try await get("/agent/\(userId)/\(agentId)/messages")
        // Backend returns dict keyed by message id: {msgId: {content, title, timestamp}}
        guard let dict = decode([String: RawAgentMsg].self, from: data) else { return [] }
        return dict.map { key, m in
            FSAgentMessage(id: key, text: m.content, mine: m.title == "user",
                           timestamp: m.timestamp ?? "")
        }.sorted { $0.timestamp < $1.timestamp }
    }

    func fetchHeartbeats(userId: String, agentId: String) async throws -> [FSHeartbeat] {
        let data = try await get("/agent/\(userId)/\(agentId)/heartbeats")
        return decode([FSHeartbeat].self, from: data) ?? []
    }

    // ── Agents (write) ────────────────────────────────────────────────────────
    // POST   /agent/{userId}                    body: {user_id, chats, enabled, role?}
    // PUT    /agent/{userId}/{agentId}          body: {enabled} or other fields
    // DELETE /agent/{userId}/{agentId}
    // POST   /agent/{userId}/{agentId}/heartbeat      body: FSHeartbeat
    // POST   /agent/{userId}/{agentId}/{heartbeatId}/commit_heartbeat body: {prompt}
    // POST   /agent/{userId}/{agentId}/summarize      body: {session, group_id}

    func createAgent(userId: String, role: String) async throws -> FSAgent {
        var body: [String: Any] = ["user_id": userId, "chats": [], "enabled": true]
        if !role.isEmpty { body["role"] = role }
        let data = try await requestRaw("/agent/\(userId)", method: "POST", jsonObject: body)
        if let resp = decode([String: String].self, from: data), let id = resp["id"] {
            return FSAgent(id: id, user_id: userId, role: role, enabled: true, chats: [])
        }
        return FSAgent(id: UUID().uuidString, user_id: userId, role: role, enabled: true, chats: [])
    }

    func updateAgent(userId: String, agentId: String, enabled: Bool) async throws {
        _ = try await requestRaw("/agent/\(userId)/\(agentId)", method: "PUT",
                                  jsonObject: ["enabled": enabled])
    }

    func renameAgent(userId: String, agentId: String, name: String) async throws {
        _ = try await requestRaw("/agent/\(userId)/\(agentId)", method: "PUT",
                                  jsonObject: ["name": name])
    }

    func deleteAgent(userId: String, agentId: String) async throws {
        _ = try await request("/agent/\(userId)/\(agentId)", method: "DELETE")
    }

    func addHeartbeat(userId: String, agentId: String, heartbeat: FSHeartbeat) async throws {
        let tsArray = heartbeat.timestamps.map { $0 != nil ? $0! as Any : NSNull() as Any }
        let body: [String: Any] = ["timestamps": tsArray, "prompt": heartbeat.prompt]
        // checked so a free-tier 403 surfaces as AppError.limitReached
        _ = try await checkedRequestRaw("/agent/\(userId)/\(agentId)/heartbeat", method: "POST", jsonObject: body)
    }

    func deleteHeartbeat(userId: String, agentId: String, heartbeatId: String) async throws {
        _ = try await request("/agent/\(userId)/\(agentId)/heartbeat/\(heartbeatId)", method: "DELETE")
    }

    func updateHeartbeat(userId: String, heartbeatId: String, heartbeat: FSHeartbeat) async throws {
        let tsArray = heartbeat.timestamps.map { $0 != nil ? $0! as Any : NSNull() as Any }
        let body: [String: Any] = [
            "agent_id":   heartbeat.agent_id,
            "timestamps": tsArray,
            "prompt":     heartbeat.prompt,
        ]
        _ = try await requestRaw("/agent/\(userId)/\(heartbeatId)/update_heartbeats", method: "PUT", jsonObject: body)
    }

    func commitHeartbeat(userId: String, agentId: String, heartbeatId: String, prompt: String) async throws -> [String: String] {
        let data = try await requestRaw(
            "/agent/\(userId)/\(agentId)/\(heartbeatId)/commit_heartbeat", method: "POST",
            jsonObject: ["prompt": prompt]
        )
        return decode([String: String].self, from: data) ?? [:]
    }

    func summarizeSession(userId: String, agentId: String, session: FSSession, groupId: String) async throws {
        _ = try await requestRaw("/agent/\(userId)/\(agentId)/summarize", method: "POST",
                                  jsonObject: ["session": try jsonObject(session), "group_id": groupId])
    }

    // ── Contacts ──────────────────────────────────────────────────────────────
    // GET /user/{userId}           → friends[], groups[]
    // GET /user/{friendId}         → resolve username per friend
    // GET /message/messages/{userId}/?guest_user={friendId}   → DM preview
    // GET /groups/{userId}/{groupId}                           → group info + messages

    func fetchContacts(userId: String) async throws -> ([FSContact], [String: FSGroup]) {
        let userData = try await get("/user/\(userId)")
        guard let profile = decode(FSUser.self, from: userData) else { return ([], [:]) }

        let friends: [FSContact] = await withTaskGroup(of: FSContact?.self) { group in
            for fid in profile.friends {
                group.addTask { [self] in
                    guard let d = try? await self.get("/user/\(fid)"),
                          let u = self.decode(FSUser.self, from: d) else {
                        return FSContact(id: fid, name: String(fid.prefix(8)), type: .friend)
                    }
                    // Fetch last DM for preview + timestamp
                    var preview = ""
                    var lastAt  = ""
                    if let md = try? await self.get("/message/messages/\(userId)/?guest_user=\(fid)"),
                       let resp = self.decode(RawMsgPayload.self, from: md) {
                        let all  = resp.payload?.allMsgs ?? []
                        let last = all.sorted { $0.timestamp < $1.timestamp }.last
                        preview = last?.text ?? ""
                        lastAt  = last?.timestamp ?? ""
                    }
                    return FSContact(id: fid, name: u.username, type: .friend,
                                     preview: preview, toUsers: [fid], lastMessageAt: lastAt)
                }
            }
            var result: [FSContact] = []
            for await c in group { if let c { result.append(c) } }
            return result
        }

        var groupMap: [String: FSGroup] = [:]
        var groupContacts: [FSContact]  = []
        for gid in profile.groups {
            guard let gd = try? await get("/groups/\(userId)/\(gid)"),
                  let resp = decode(RawGroupResponse.self, from: gd) else {
                groupContacts.append(FSContact(id: gid, name: String(gid.prefix(8)), type: .group))
                continue
            }
            let g = resp.group ?? RawGroup()
            let title = g.title ?? gid
            let users = g.users ?? []
            groupMap[gid] = FSGroup(id: gid, title: title, users: users)
            let allMsgs  = (resp.host_msgs ?? []) + (resp.other_msgs ?? [])
            let lastMsg  = allMsgs.sorted { $0.timestamp < $1.timestamp }.last
            let preview  = lastMsg?.text ?? ""
            // Backend `members` is the list of member usernames (excluding self).
            let memberNames = resp.members ?? []
            groupContacts.append(FSContact(id: gid, name: title, type: .group,
                                           preview: preview, toUsers: users,
                                           memberNames: memberNames,
                                           lastMessageAt: lastMsg?.timestamp ?? ""))
        }

        return (friends + groupContacts, groupMap)
    }

    // GET /friends/{userId}/{friendId}       → {host_msgs, other_msgs}
    func fetchFriendMessages(userId: String, friendId: String) async throws -> [FSMessage] {
        let data = try await get("/friends/\(userId)/\(friendId)")
        guard let resp = decode(RawChatResponse.self, from: data) else { return [] }
        let mine  = (resp.host_msgs  ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: true,  sender: "",       timestamp: m.timestamp ?? "") }
        let theirs = (resp.other_msgs ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: false, sender: m.from_user ?? "", timestamp: m.timestamp ?? "") }
        return (mine + theirs).sorted { $0.timestamp < $1.timestamp }
    }

    // GET /groups/{userId}/{groupId}         → {host_msgs, other_msgs}
    func fetchGroupMessages(userId: String, groupId: String) async throws -> [FSMessage] {
        let data = try await get("/groups/\(userId)/\(groupId)")
        guard let resp = decode(RawGroupResponse.self, from: data) else { return [] }
        let mine  = (resp.host_msgs  ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: true,  sender: "",          timestamp: m.timestamp ?? "") }
        let theirs = (resp.other_msgs ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: false, sender: m.from_user ?? "", timestamp: m.timestamp ?? "") }
        return (mine + theirs).sorted { $0.timestamp < $1.timestamp }
    }

    // ── Friends ───────────────────────────────────────────────────────────────
    // POST /friends/{userId}/request?friend_username={username}
    // POST /friends/{userId}/add?friend_username={username}
    // DELETE /friends/{userId}/{friendId}

    // GET /friends/{userId}/requests → [{user_id, username}]
    func fetchFriendRequests(userId: String) async throws -> [(id: String, username: String)] {
        let data = try await get("/friends/\(userId)/requests")
        let raw = decode([RawFriendRequest].self, from: data) ?? []
        return raw.map { (id: $0.user_id, username: $0.username) }
    }

    func sendFriendRequest(userId: String, username: String) async throws {
        _ = try await request("/friends/\(userId)/request?friend_username=\(encodeURIComponent(username))",
                              method: "POST")
    }

    func acceptFriendRequest(userId: String, username: String) async throws {
        _ = try await request("/friends/\(userId)/add?friend_username=\(encodeURIComponent(username))",
                              method: "POST")
    }

    func removeFriend(userId: String, friendId: String) async throws {
        _ = try await request("/friends/\(userId)/\(encodeURIComponent(friendId))", method: "DELETE")
    }

    // ── Reports / Blocks (Guideline 1.2) ────────────────────────────────────────
    // POST   /reports/                     body: {content_type, content_id?, reported_user_id?, reason, detail}
    // GET    /blocks/{userId}               → [{user_id, username}]
    // POST   /blocks/{userId}/{blockedId}
    // DELETE /blocks/{userId}/{blockedId}

    func reportUser(reportedUserId: String, reason: String, detail: String) async throws {
        _ = try await checkedRequestRaw("/reports/", method: "POST", jsonObject: [
            "content_type": "user",
            "reported_user_id": reportedUserId,
            "reason": reason,
            "detail": detail,
        ])
    }

    func blockUser(userId: String, blockedId: String) async throws {
        _ = try await request("/blocks/\(userId)/\(encodeURIComponent(blockedId))", method: "POST")
    }

    func unblockUser(userId: String, blockedId: String) async throws {
        _ = try await request("/blocks/\(userId)/\(encodeURIComponent(blockedId))", method: "DELETE")
    }

    func fetchBlockedUsers(userId: String) async throws -> [FSBlockedUser] {
        let data = try await get("/blocks/\(userId)")
        return decode([FSBlockedUser].self, from: data) ?? []
    }

    // ── Groups ────────────────────────────────────────────────────────────────
    // POST   /groups/{userId}         body: {group_id, title, users}
    // DELETE /groups/{userId}/{groupId}

    func createGroup(userId: String, groupId: String, title: String, users: [String]) async throws {
        _ = try await requestRaw("/groups/\(userId)", method: "POST",
                                  jsonObject: ["group_id": groupId, "title": title, "users": users])
    }

    // PUT /groups/{userId}/{groupId}   body: {group_id, title, users}
    func updateGroup(userId: String, groupId: String, title: String, users: [String]) async throws {
        _ = try await requestRaw("/groups/\(userId)/\(groupId)", method: "PUT",
                                  jsonObject: ["group_id": groupId, "title": title, "users": users])
    }

    func leaveGroup(userId: String, groupId: String) async throws {
        _ = try await request("/groups/\(userId)/\(groupId)", method: "DELETE")
    }

    // ── Sessions / Devotions ──────────────────────────────────────────────────
    // GET    /devotions/contact/{contactId}
    // POST   /devotions/                body: {devotion_id:"", user_id, devotion:{...}}
    // PUT    /devotions/                body: {devotion_id, user_id, devotion:{...}}
    // DELETE /devotions/                body: {devotion_id, user_id, devotion:{...}}
    // POST   /devotions/join?user_id=&session_id=
    // POST   /devotions/leave?user_id=&session_id=

    func fetchSessionsForContact(contactId: String) async throws -> [FSSession] {
        let data = try await get("/devotions/contact/\(encodeURIComponent(contactId))")
        return decode(RawDevotionsResponse.self, from: data)?.sessions ?? []
    }

    func createSession(userId: String, devotion: FSSession, contactId: String) async throws -> String {
        var d = devotion
        d.group_id = contactId
        d.creator_id = userId
        let body: [String: Any] = [
            "devotion_id": "",
            "user_id": userId,
            "devotion": try jsonObject(d),
        ]
        let data = try await requestRaw("/devotions/", method: "POST", jsonObject: body)
        return decode([String: String].self, from: data)?["id"] ?? UUID().uuidString
    }

    func updateSession(userId: String, sessionId: String, devotion: FSSession) async throws {
        let body: [String: Any] = [
            "devotion_id": sessionId,
            "user_id": userId,
            "devotion": try jsonObject(devotion),
        ]
        _ = try await requestRaw("/devotions/", method: "PUT", jsonObject: body)
    }

    func deleteSession(userId: String, sessionId: String, devotion: FSSession) async throws {
        let body: [String: Any] = [
            "devotion_id": sessionId,
            "user_id": userId,
            "devotion": try jsonObject(devotion),
        ]
        _ = try await requestRaw("/devotions/", method: "DELETE", jsonObject: body)
    }

    func joinSession(userId: String, sessionId: String) async throws {
        _ = try await request(
            "/devotions/join?user_id=\(encodeURIComponent(userId))&session_id=\(encodeURIComponent(sessionId))",
            method: "POST"
        )
    }

    func leaveSession(userId: String, sessionId: String) async throws {
        _ = try await request(
            "/devotions/leave?user_id=\(encodeURIComponent(userId))&session_id=\(encodeURIComponent(sessionId))",
            method: "POST"
        )
    }

    // ── Notifications ─────────────────────────────────────────────────────────
    // GET    /notification/{userId}
    // POST   /notification/{userId}           body: {name, prompt, timestamps}
    // PUT    /notification/{userId}/{notifId} body: {name, prompt, timestamps}
    // DELETE /notification/{userId}/{notifId}

    func fetchNotifications(userId: String) async throws -> [FSNotification] {
        let data = try await get("/notification/\(userId)")
        return decode([FSNotification].self, from: data) ?? []
    }

    func createNotification(userId: String, name: String, prompt: String, timestamps: [String?]) async throws -> FSNotification {
        let tsArray = timestamps.map { $0 != nil ? $0! as Any : NSNull() as Any }
        let body: [String: Any] = ["name": name, "prompt": prompt, "timestamps": tsArray]
        // checked so a free-tier 403 surfaces as AppError.limitReached
        let data = try await checkedRequestRaw("/notification/\(userId)", method: "POST", jsonObject: body)
        guard let result = decode([String: String].self, from: data), let notifId = result["id"] else {
            throw AppError.networkError("Failed to create notification")
        }
        return FSNotification(id: notifId, user_id: userId, name: name, prompt: prompt, timestamps: timestamps)
    }

    func updateNotification(userId: String, notifId: String, name: String, prompt: String, timestamps: [String?]) async throws {
        let tsArray = timestamps.map { $0 != nil ? $0! as Any : NSNull() as Any }
        let body: [String: Any] = ["name": name, "prompt": prompt, "timestamps": tsArray]
        _ = try await requestRaw("/notification/\(userId)/\(notifId)", method: "PUT", jsonObject: body)
    }

    func deleteNotification(userId: String, notifId: String) async throws {
        _ = try await request("/notification/\(userId)/\(notifId)", method: "DELETE")
    }

    func registerDeviceToken(userId: String, token: String) async throws {
        _ = try await requestRaw("/notification/\(userId)/device-token", method: "POST",
                                 jsonObject: ["token": token])
    }

    func triggerNotification(userId: String, notifId: String) async throws -> [String: String] {
        let data = try await request("/notification/\(userId)/\(notifId)/trigger", method: "POST")
        return decode([String: String].self, from: data) ?? [:]
    }

    // ── Chime calls ───────────────────────────────────────────────────────────
    // POST /devotions/join-call?user_id=&session_id=  → {Meeting, Attendee}

    func joinCall(userId: String, sessionId: String) async throws -> ChimeJoinResponse {
        let data = try await request(
            "/devotions/join-call?user_id=\(encodeURIComponent(userId))&session_id=\(encodeURIComponent(sessionId))",
            method: "POST"
        )
        guard let response = decode(ChimeJoinResponse.self, from: data) else {
            let detail = decode([String: String].self, from: data)?["detail"] ?? "Failed to join call"
            throw AppError.networkError(detail)
        }
        return response
    }

    // ── Subscriptions ─────────────────────────────────────────────────────────
    // Mirrors api/routes/subscription.py.

    func fetchUserSubscription(userId: String) async throws -> FSSubscription? {
        // The backend returns 404 {"detail": "No active subscription"} when the
        // user is on no plan. FSSubscription's lenient decoder would otherwise
        // happily decode that error body into a default (bogus "individual")
        // plan, so explicitly treat any error status — and any subscription that
        // came back without a real id — as "no subscription".
        let (data, response) = try await URLSession.shared.data(
            from: url("/subscriptions/user/\(encodeURIComponent(userId))")
        )
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
        guard let sub = decode(FSSubscription.self, from: data), !sub.id.isEmpty else { return nil }
        return sub
    }

    // GET /subscriptions/user/{userId}/usage → free-tier usage snapshot.
    func fetchUsage(userId: String) async throws -> FSUsage? {
        let data = try await get("/subscriptions/user/\(encodeURIComponent(userId))/usage")
        return decode(FSUsage.self, from: data)
    }

    func startSubscription(userId: String, memberCount: Int, billing: FSBillingInfo?) async throws -> String {
        var body: [String: Any] = ["user_id": userId, "member_count": memberCount, "provider": "stripe"]
        if let b = billing {
            // Only non-sensitive billing metadata is transmitted.
            body["card_brand"]     = b.brand
            body["card_last4"]     = b.last4
            body["card_exp_month"] = b.expMonth
            body["card_exp_year"]  = b.expYear
        }
        let data = try await requestRaw("/subscriptions/", method: "POST", jsonObject: body)
        guard let result = decode([String: String].self, from: data), let id = result["id"] else {
            throw AppError.networkError("Could not start plan.")
        }
        return id
    }

    func cancelSubscription(subscriptionId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))", method: "DELETE")
    }

    // Host changes how many people the plan covers; server re-prices from member_count.
    func updateSubscriptionSeats(subscriptionId: String, memberCount: Int) async throws {
        _ = try await requestRaw("/subscriptions/\(encodeURIComponent(subscriptionId))", method: "PUT",
                                 jsonObject: ["member_count": memberCount])
    }

    func fetchSubMembers(subscriptionId: String) async throws -> [FSSubMember] {
        let data = try await get("/subscriptions/\(encodeURIComponent(subscriptionId))/members")
        return decode([FSSubMember].self, from: data) ?? []
    }

    func removeSubMember(subscriptionId: String, userId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))/members/\(encodeURIComponent(userId))",
                              method: "DELETE")
    }

    func fetchSubRequests(subscriptionId: String) async throws -> [FSSubMember] {
        let data = try await get("/subscriptions/\(encodeURIComponent(subscriptionId))/requests")
        return decode([FSSubMember].self, from: data) ?? []
    }

    func fetchMySubRequests(userId: String) async throws -> [FSSubRequest] {
        let data = try await get("/subscriptions/user/\(encodeURIComponent(userId))/requests")
        return decode([FSSubRequest].self, from: data) ?? []
    }

    func requestJoinSubscription(subscriptionId: String, fromUserId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))/requests?from_user_id=\(encodeURIComponent(fromUserId))",
                              method: "POST")
    }

    func acceptSubRequest(subscriptionId: String, fromUserId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))/requests/\(encodeURIComponent(fromUserId))/accept",
                              method: "POST")
    }

    func declineSubRequest(subscriptionId: String, fromUserId: String) async throws {
        _ = try await request("/subscriptions/\(encodeURIComponent(subscriptionId))/requests/\(encodeURIComponent(fromUserId))",
                              method: "DELETE")
    }

    func syncAppleSubscription(userId: String, jws: String) async throws -> FSSubscription? {
        // Forwards a StoreKit 2 signed transaction; backend verifies + records.
        let data = try await requestRaw("/subscriptions/apple/sync", method: "POST",
                                        jsonObject: ["user_id": userId, "jws": jws])
        return decode(FSSubscription.self, from: data)
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private func encodeURIComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

// ── Private response models ───────────────────────────────────────────────────

private struct RawAgentMsg: Decodable {
    let content:   String
    let title:     String?   // "user" or "assistant"
    let timestamp: String?
}

private struct RawMsg: Decodable {
    let id:        String?
    let text:      String?
    let from_user: String?
    let timestamp: String
}

private struct RawChatResponse: Decodable {
    let host_msgs:  [RawMsg]?
    let other_msgs: [RawMsg]?
}

private struct RawFriendRequest: Decodable {
    let user_id:  String
    let username: String
}

private struct RawGroup: Decodable {
    var title: String? = nil
    var users: [String]? = nil
}

private struct RawGroupResponse: Decodable {
    let group:      RawGroup?
    let host_msgs:  [RawMsg]?
    let other_msgs: [RawMsg]?
    let members:    [String]?
}

private struct RawMsgBody: Decodable {
    let host_msgs:  [RawMsg]?
    let other_msgs: [RawMsg]?

    var allMsgs: [RawMsg] { (host_msgs ?? []) + (other_msgs ?? []) }
}

private struct RawMsgPayload: Decodable {
    let payload: RawMsgBody?
}

private struct RawDevotionsResponse: Decodable {
    let sessions: [FSSession]?
}
