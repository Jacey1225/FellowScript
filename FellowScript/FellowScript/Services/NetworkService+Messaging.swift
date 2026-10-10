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

// Task 20261001-chat-pagination: wire-independent paging types shared by
// NetworkService, DataServiceProtocol and ChatThreadViewModel.

/// Keyset cursor of the oldest row of the page just received (the page's
/// next_cursor_timestamp / next_cursor_seq / next_cursor_id). Opaque to the
/// client: it is only echoed back to the older-messages route.
struct FSMessageCursor: Equatable {
    let timestamp: String
    let seq: Int?
    let id: String
}

/// One page of history, oldest-first. `cursor` is non-nil exactly when
/// `hasMore` is true.
struct FSMessagePage {
    let messages: [FSMessage]
    let hasMore: Bool
    let cursor: FSMessageCursor?
}

/// What a history fetch returned: the legacy full history (flag off, no
/// `page` block) or a page.
enum FSMessageHistory {
    case legacy([FSMessage])
    case paged(FSMessagePage)
}

extension NetworkService {

    // GET /friends/{userId}/{friendId}       → {host_msgs, other_msgs}
    func fetchFriendMessages(userId: String, friendId: String) async throws -> [FSMessage] {
        let data = try await get("/friends/\(userId)/\(friendId)")
        guard let resp = decode(RawChatResponse.self, from: data) else { return [] }
        let mine  = (resp.host_msgs  ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: true,  sender: "",       timestamp: m.timestamp ?? "", attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta, reactions: m.reactions) }
        let theirs = (resp.other_msgs ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: false, sender: m.from_user ?? "", timestamp: m.timestamp ?? "", attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta, reactions: m.reactions) }
        return (mine + theirs).sorted { $0.timestamp < $1.timestamp }
    }

    // GET /groups/{userId}/{groupId}         → {host_msgs, other_msgs}
    func fetchGroupMessages(userId: String, groupId: String) async throws -> [FSMessage] {
        let data = try await get("/groups/\(userId)/\(groupId)")
        guard let resp = decode(RawGroupResponse.self, from: data) else { return [] }
        let mine  = (resp.host_msgs  ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: true,  sender: "",          timestamp: m.timestamp ?? "", attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta, reactions: m.reactions) }
        let theirs = (resp.other_msgs ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: false, sender: m.from_user ?? "", timestamp: m.timestamp ?? "", attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta, reactions: m.reactions) }
        return (mine + theirs).sorted { $0.timestamp < $1.timestamp }
    }

    // ── Paged history (task 20261001-chat-pagination) ─────────────────────────
    // Behavioural reference: frontend/src/lib/chatPaging.js. Opt-in only: the
    // caller (ChatThreadViewModel / fetchContacts) passes a limit solely when
    // the SF capabilities client says chat_pagination (groups) or
    // chat_pagination_dm (DMs) is on; a nil limit is the untouched legacy
    // full-history fetch. A response without a `page` block (old server, flag
    // flipped off, 200 with the legacy shape) is decoded as legacy history, so
    // an unexpected shape can never blank a thread.

    // GET /groups/{userId}/{groupId}?limit=N  or  GET /friends/{userId}/{friendId}?limit=N
    func fetchMessageHistory(userId: String, contactId: String, isGroup: Bool, limit: Int?) async throws -> FSMessageHistory {
        guard let limit else {
            let legacy = isGroup
                ? try await fetchGroupMessages(userId: userId, groupId: contactId)
                : try await fetchFriendMessages(userId: userId, friendId: contactId)
            return .legacy(legacy)
        }
        let base = isGroup ? "/groups/\(userId)/\(contactId)" : "/friends/\(userId)/\(contactId)"
        let data = try await get("\(base)?limit=\(limit)")
        if let page = parsePage(data: data) {
            return .paged(page)
        }
        return .legacy(isGroup ? legacyGroupMessages(from: data) : legacyFriendMessages(from: data))
    }

    // GET /groups/{userId}/{groupId}/messages?limit=&cursor_timestamp=&cursor_seq=&cursor_id=
    // GET /friends/{userId}/{friendId}/messages?...
    // Throws on any non-200 (404 while the flag is off), a transport error, or
    // a body with no `page` block -- the caller shows a retry control, it never
    // fabricates an empty "start of conversation".
    func fetchOlderMessages(userId: String, contactId: String, isGroup: Bool, limit: Int, cursor: FSMessageCursor) async throws -> FSMessagePage {
        let base = isGroup ? "/groups/\(userId)/\(contactId)/messages" : "/friends/\(userId)/\(contactId)/messages"
        var query = "limit=\(limit)&cursor_timestamp=\(encodeURIComponent(cursor.timestamp))"
        if let seq = cursor.seq { query += "&cursor_seq=\(seq)" }
        query += "&cursor_id=\(encodeURIComponent(cursor.id))"
        let data = try await get("\(base)?\(query)")
        guard let page = parsePage(data: data) else {
            throw AppError.networkError("Couldn't load earlier messages.")
        }
        return page
    }

    /// nil when the body has no `page` block or no `messages` array (legacy /
    /// old server). `has_more` without a usable cursor is treated as the end,
    /// since it cannot be continued.
    func parsePage(data: Data) -> FSMessagePage? {
        guard let resp = decode(RawPagedResponse.self, from: data),
              let page = resp.page, let rows = resp.messages else { return nil }
        let messages = rows.map { Self.pagedMessage($0) }
        var cursor: FSMessageCursor? = nil
        if page.has_more == true, let ts = page.next_cursor_timestamp, let id = page.next_cursor_id {
            cursor = FSMessageCursor(timestamp: ts, seq: page.next_cursor_seq, id: id)
        }
        return FSMessagePage(messages: messages, hasMore: cursor != nil, cursor: cursor)
    }

    /// One paged row -> FSMessage. `mine` comes from the row; `from_user` is a
    /// username (not an id) on paged rows.
    static func pagedMessage(_ m: RawMsg) -> FSMessage {
        let mine = m.mine ?? false
        return FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: mine,
                         sender: mine ? "" : (m.from_user ?? ""), timestamp: m.timestamp,
                         attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url,
                         attachmentMeta: m.attachment_meta, reactions: m.reactions)
    }

    private func legacyFriendMessages(from data: Data) -> [FSMessage] {
        guard let resp = decode(RawChatResponse.self, from: data) else { return [] }
        return Self.legacyMerge(host: resp.host_msgs, other: resp.other_msgs)
    }

    private func legacyGroupMessages(from data: Data) -> [FSMessage] {
        guard let resp = decode(RawGroupResponse.self, from: data) else { return [] }
        return Self.legacyMerge(host: resp.host_msgs, other: resp.other_msgs)
    }

    private static func legacyMerge(host: [RawMsg]?, other: [RawMsg]?) -> [FSMessage] {
        let mine   = (host  ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: true,  sender: "",             timestamp: m.timestamp, attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta, reactions: m.reactions) }
        let theirs = (other ?? []).map { m in FSMessage(id: m.id ?? UUID().uuidString, text: m.text ?? "", mine: false, sender: m.from_user ?? "", timestamp: m.timestamp, attachmentKind: m.attachment_kind, attachmentURL: m.attachment_url, attachmentMeta: m.attachment_meta, reactions: m.reactions) }
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
        // checked: a Free-plan sessions block (403) must surface as AppError.limitReached.
        let data = try await checkedRequestRaw("/devotions/", method: "POST", jsonObject: body)
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

    // ── Ring group members (task 20260916-call-ring-members) ────────────────────
    // POST /devotions/ring   body: {devotion_id, user_id, target_ids}
    //   → {"results": {target_id: {"sent": bool, "reason": str|null}}}
    // Uses checkedRequestRaw (not requestRaw) so a 403 (caller not authorized
    // for the session) or a 404 (feature disabled, or the session no longer
    // exists) throws instead of silently producing an empty/misleading result
    // map -- RingMembersSheet's catch path marks every selected row as a
    // send failure in that case, same posture as any other rejected write.
    func ringMembers(userId: String, sessionId: String, targetIds: [String]) async throws -> [String: RingResult] {
        let body: [String: Any] = [
            "devotion_id": sessionId,
            "user_id": userId,
            "target_ids": targetIds,
        ]
        let data = try await checkedRequestRaw("/devotions/ring", method: "POST", jsonObject: body)
        guard let response = decode(RingResponse.self, from: data, endpoint: "/devotions/ring") else {
            throw AppError.networkError("Couldn't reach members — try again.")
        }
        return response.results
    }
}
