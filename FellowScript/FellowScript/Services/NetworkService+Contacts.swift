// NetworkService+Contacts.swift — Contacts (friends+groups list with DM/group
// previews), Friends (requests/add/remove), Friend Activity, and Reports/
// Blocks (Guideline 1.2). Split out of NetworkService.swift (readability
// #H16, 20260904-frontend-arch-sweep) -- same type, same behavior, just this
// domain's own file. See NetworkService.swift's header comment for the full
// split rationale and the list of sibling domain files.

import Foundation

extension NetworkService {

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
                    // Task 20260905-profile-photo: `u` is the friend's own
                    // full profile (already fetched above for `username`),
                    // which now carries a freshly-issued `profile_photo_url`
                    // -- no extra round-trip needed to thread it onto the
                    // contact for ChatRootView's contact rows / ChatThreadView's
                    // DM header+avatar.
                    return FSContact(id: fid, name: u.username, type: .friend,
                                     preview: preview, toUsers: [fid], lastMessageAt: lastAt,
                                     photoUrl: u.profile_photo_url)
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

    // GET /friends/{userId}/activity → {friends_active: [...], check_in_candidates: [...]}
    // (check_in_candidates: task 20260902-dashboard-friend-randomization —
    // a bounded top-N "longest since contact" pool, was a single check_in
    // winner object|null.)
    // Dashboard's Friend Activity hero card. Declared server-side ahead of
    // /friends/{userId}/{friendId} so the literal "activity" path segment
    // matches first.
    //
    // Wrapped in reportFetchFailure so a thrown fetch-level error (any
    // 4xx/5xx from throwIfError(), e.g. the 404 a stale-deploy build
    // returned in 20260827-checkin-row-investigation) is logged + beaconed
    // before it reaches DashboardViewModel.load()'s `try? ... ?? .empty` —
    // that swallow still degrades to cache/.empty exactly as before, but the
    // failure is no longer invisible. decode(endpoint:) below already covers
    // the "200 but can't parse" half of this same silent-failure class.
    func fetchFriendActivity(userId: String) async throws -> FSFriendActivityFeed {
        let endpoint = "/friends/{userId}/activity"
        let data = try await reportFetchFailure(endpoint: endpoint) {
            try await self.get("/friends/\(userId)/activity")
        }
        return decode(FSFriendActivityFeed.self, from: data, endpoint: endpoint) ?? .empty
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
}
