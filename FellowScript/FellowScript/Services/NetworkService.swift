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
        let (data, _) = try await URLSession.shared.data(for: req)
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

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    // ── Auth ──────────────────────────────────────────────────────────────────

    func signIn(username: String, password: String) async throws -> FSUser {
        let data = try await requestRaw("/login", method: "POST",
                                        jsonObject: ["username": username, "plain_pass": password])
        guard let user = decode(FSUser.self, from: data) else {
            let detail = decode([String: String].self, from: data)?["detail"] ?? "Sign in failed."
            throw AppError.authFailed(detail)
        }
        return user
    }

    func signUp(username: String, email: String, password: String) async throws -> FSUser {
        let data = try await requestRaw("/signup", method: "POST",
                                        jsonObject: ["username": username, "email": email, "plain_pass": password])
        guard let user = decode(FSUser.self, from: data) else {
            let detail = decode([String: String].self, from: data)?["detail"] ?? "Sign up failed."
            throw AppError.authFailed(detail)
        }
        return user
    }

    // ── User ──────────────────────────────────────────────────────────────────
    // GET  /user/{userId}
    // PUT  /user/{userId}   body: {username?, email?, plain_pass?}
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
    // POST   /agent/{userId}/{agentId}/commit_heartbeat body: {prompt}
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
        _ = try await request("/agent/\(userId)/\(agentId)/heartbeat", method: "POST", body: heartbeat)
    }

    func deleteHeartbeat(userId: String, agentId: String, heartbeatId: String) async throws {
        _ = try await request("/agent/\(userId)/\(agentId)/heartbeat/\(heartbeatId)", method: "DELETE")
    }

    func commitHeartbeat(userId: String, agentId: String, prompt: String) async throws -> [String: String] {
        let data = try await requestRaw(
            "/agent/\(userId)/\(agentId)/commit_heartbeat", method: "POST",
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
                    // Fetch last DM for preview
                    var preview = ""
                    if let md = try? await self.get("/message/messages/\(userId)/?guest_user=\(fid)"),
                       let resp = self.decode(RawMsgPayload.self, from: md) {
                        let all = resp.payload?.allMsgs ?? []
                        preview = all.sorted { $0.timestamp < $1.timestamp }.last?.text ?? ""
                    }
                    return FSContact(id: fid, name: u.username, type: .friend,
                                     preview: preview, toUsers: [fid])
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
            let allMsgs = (resp.host_msgs ?? []) + (resp.other_msgs ?? [])
            let preview = allMsgs.sorted { $0.timestamp < $1.timestamp }.last?.text ?? ""
            groupContacts.append(FSContact(id: gid, name: title, type: .group,
                                           preview: preview, toUsers: users))
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

    // ── Groups ────────────────────────────────────────────────────────────────
    // POST   /groups/{userId}         body: {group_id, title, users}
    // DELETE /groups/{userId}/{groupId}

    func createGroup(userId: String, groupId: String, title: String, users: [String]) async throws {
        _ = try await requestRaw("/groups/\(userId)", method: "POST",
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
        let data = try await requestRaw("/notification/\(userId)", method: "POST", jsonObject: body)
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
