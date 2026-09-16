// NetworkService+Messaging.swift — friend/group message history fetch,
// Groups (create/update/leave), Sessions/Devotions (create/update/delete/
// join/leave), and Chime call join. Grouped together because Sessions and
// Chime calls are messaging-thread-scoped features (scheduled inside a
// friend/group chat thread), not independent domains of their own. Split
// out of NetworkService.swift (readability #H16, 20260904-frontend-arch-
// sweep) -- same type, same behavior, just this domain's own file. See
// NetworkService.swift's header comment for the full split rationale and
// the list of sibling domain files.

import Foundation

extension NetworkService {

    // GET /friends/{userId}/{friendId}       → {host_msgs, other_msgs}
    func fetchFriendMessages(userId: String, friendId: String) async throws -> [FSMessage] {
        let data = try await get("/friends/\(userId)/\(friendId)")
        guard let resp = decode(RawChatResponse.self, from: data) else { return [] }
        let mine  = (resp.host_msgs  ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: true,  sender: "",       timestamp: m.timestamp ?? "", attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta) }
        let theirs = (resp.other_msgs ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: false, sender: m.from_user ?? "", timestamp: m.timestamp ?? "", attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta) }
        return (mine + theirs).sorted { $0.timestamp < $1.timestamp }
    }

    // GET /groups/{userId}/{groupId}         → {host_msgs, other_msgs}
    func fetchGroupMessages(userId: String, groupId: String) async throws -> [FSMessage] {
        let data = try await get("/groups/\(userId)/\(groupId)")
        guard let resp = decode(RawGroupResponse.self, from: data) else { return [] }
        let mine  = (resp.host_msgs  ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: true,  sender: "",          timestamp: m.timestamp ?? "", attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta) }
        let theirs = (resp.other_msgs ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: false, sender: m.from_user ?? "", timestamp: m.timestamp ?? "", attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta) }
        return (mine + theirs).sorted { $0.timestamp < $1.timestamp }
    }

    // ── Groups ────────────────────────────────────────────────────────────────
    // POST   /groups/{userId}         body: {group_id, title, users}
    // POST   /groups/{userId}/{groupId}/leave   -- leave (single-member removal)
    // DELETE /groups/{userId}/{groupId}         -- delete (owner-gated, whole group)

    // Uses checkedRequestRaw (not requestRaw) so a rejected create/update — most
    // notably group_router's content-filter check_clean(title=...) 422 — throws
    // instead of silently no-opping. See createGroup/updateGroup call sites for
    // the corresponding UI-side error handling and optimistic-update rollback.
    func createGroup(userId: String, groupId: String, title: String, users: [String]) async throws {
        _ = try await checkedRequestRaw("/groups/\(userId)", method: "POST",
                                         jsonObject: ["group_id": groupId, "title": title, "users": users])
    }

    // PUT /groups/{userId}/{groupId}   body: {group_id, title, users}
    func updateGroup(userId: String, groupId: String, title: String, users: [String]) async throws {
        _ = try await checkedRequestRaw("/groups/\(userId)/\(groupId)", method: "PUT",
                                         jsonObject: ["group_id": groupId, "title": title, "users": users])
    }

    // Task 20260916-group-leave-deletes-group: leaving now hits the dedicated
    // single-member-removal endpoint (removes only userId from the group's
    // roster server-side, auto-deleting the row only if that empties it --
    // see GroupsManager.leave_group) instead of the old full-group DELETE,
    // which previously destroyed the group for every member the instant any
    // one of them tapped "Leave." deleteGroup below is the separate,
    // explicitly-authorized action for actually removing the whole group.
    func leaveGroup(userId: String, groupId: String) async throws {
        _ = try await request("/groups/\(userId)/\(groupId)/leave", method: "POST")
    }

    // Owner-gated (or, for a creator_id-NULL group, any current member --
    // see GroupsManager.can_delete): deletes the group outright for every
    // member. The server enforces this regardless of what ChatRootView's
    // client-side affordance-gating shows -- a 403 here surfaces as a thrown
    // AppError like any other rejected write.
    func deleteGroup(userId: String, groupId: String) async throws {
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
}
