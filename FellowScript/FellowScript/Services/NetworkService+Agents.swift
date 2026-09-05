// NetworkService+Agents.swift — AI agent read (list, messages, heartbeats)
// and write (create/update/rename/delete, heartbeat CRUD, commit/summarize).
// Split out of NetworkService.swift (readability #H16, 20260904-frontend-
// arch-sweep) -- same type, same behavior, just this domain's own file. See
// NetworkService.swift's header comment for the full split rationale and
// the list of sibling domain files.

import Foundation

extension NetworkService {

    // ── Agents (read) ─────────────────────────────────────────────────────────
    // GET /agent/{userId}
    // GET /agent/{userId}/{agentId}/messages
    // GET /agent/{userId}/{agentId}/heartbeats

    func fetchAgents(userId: String) async throws -> [FSAgent] {
        let data = try await get("/agent/\(userId)")
        // task 20260903-account-stats-not-loading: tagged like the two above.
        // FSAgent's own Decodable init is lenient per-field (see Models.swift),
        // so a failure here can only come from the top-level payload not being
        // a `{uuid: {...}}` object at all -- rare, but still worth a signal
        // rather than silently reading as "zero agents".
        guard let dict = decode([String: FSAgent].self, from: data, endpoint: "GET /agent/{user_id}") else { return [] }
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
        // task 20260903-account-events-not-loading: tagged like the sibling
        // fetches (fetchNotesCount/fetchHighlights/fetchAgents) fixed earlier
        // today -- this was the one fetch that fix missed. A decode failure
        // here (e.g. the missing-column production-migration gap that caused
        // this exact task) previously vanished indistinguishably from "this
        // agent really has zero events", with no reportDecodeFailure/CloudWatch
        // signal at all.
        return decode([FSHeartbeat].self, from: data, endpoint: "GET /agent/{user_id}/{agent_id}/heartbeats") ?? []
    }

    // ── Agents (write) ────────────────────────────────────────────────────────
    // POST   /agent/{userId}                    body: {user_id, chats, enabled, role?}
    // PUT    /agent/{userId}/{agentId}          body: {enabled} or other fields
    // DELETE /agent/{userId}/{agentId}
    // POST   /agent/{userId}/{agentId}/heartbeat      body: FSHeartbeat
    // POST   /agent/{userId}/{agentId}/{heartbeatId}/commit_heartbeat body: {prompt}
    // POST   /agent/{userId}/{agentId}/summarize      body: {session, group_id}

    func createAgent(userId: String, role: String) async throws -> FSAgent {
        // checkedRequestRaw (not requestRaw) so a rejected create throws instead
        // of falling through to the `return FSAgent(id: UUID()...)` fallback below,
        // which used to fabricate a plausible-looking agent with a client-generated
        // id on ANY failure (network error, 4xx/5xx, or a decode miss) — the worst
        // instance of this file's silent-failure pattern, since it invented a
        // success value rather than merely dropping one.
        var body: [String: Any] = ["user_id": userId, "chats": [], "enabled": true]
        if !role.isEmpty { body["role"] = role }
        let data = try await checkedRequestRaw("/agent/\(userId)", method: "POST", jsonObject: body)
        guard let resp = decode([String: String].self, from: data), let id = resp["id"] else {
            throw AppError.networkError(extractErrorDetail(from: data) ?? "Could not create agent.")
        }
        return FSAgent(id: id, user_id: userId, role: role, enabled: true, chats: [])
    }

    func updateAgent(userId: String, agentId: String, enabled: Bool) async throws {
        // checked so a backend rejection throws instead of leaving the caller's
        // optimistic local mutation (AccountView.toggleAgent) silently drifted
        // from server state.
        _ = try await checkedRequestRaw("/agent/\(userId)/\(agentId)", method: "PUT",
                                  jsonObject: ["enabled": enabled])
    }

    func renameAgent(userId: String, agentId: String, name: String) async throws {
        // checked — see updateAgent above.
        _ = try await checkedRequestRaw("/agent/\(userId)/\(agentId)", method: "PUT",
                                  jsonObject: ["name": name])
    }

    func deleteAgent(userId: String, agentId: String) async throws {
        _ = try await request("/agent/\(userId)/\(agentId)", method: "DELETE")
    }

    func addHeartbeat(userId: String, agentId: String, heartbeat: FSHeartbeat, idempotencyKey: String?) async throws {
        let tsArray = heartbeat.timestamps.map { $0 != nil ? $0! as Any : NSNull() as Any }
        // group_id: "" (rather than omitting the key) matches the server's
        // own `body.get("group_id") or None` falsy check in api/routes/agent.py.
        var body: [String: Any] = [
            "timestamps":   tsArray,
            "prompt":       heartbeat.prompt,
            "group_id":     heartbeat.group_id ?? "",
            "notes_public": heartbeat.notes_public,
        ]
        // idempotency_key (task 20260905-heartbeat-timezone-duplicate-bugs,
        // Bug 2): a per-save-attempt token, generated once when the user
        // taps Save (EventSetupSheet.swift) so a double-tap or retry that
        // dispatches two requests for the same attempt collides on the
        // server's UNIQUE (user_id, agent_id, idempotency_key) index and
        // yields exactly one persisted row instead of two. Omitted entirely
        // (not sent as null) when absent so the server's own
        // `body.get("idempotency_key")` fallback-generation path applies.
        if let idempotencyKey { body["idempotency_key"] = idempotencyKey }
        // checked so a free-tier 403 surfaces as AppError.limitReached
        _ = try await checkedRequestRaw("/agent/\(userId)/\(agentId)/heartbeat", method: "POST", jsonObject: body)
    }

    func deleteHeartbeat(userId: String, agentId: String, heartbeatId: String) async throws {
        _ = try await request("/agent/\(userId)/\(agentId)/heartbeat/\(heartbeatId)", method: "DELETE")
    }

    func updateHeartbeat(userId: String, heartbeatId: String, heartbeat: FSHeartbeat) async throws {
        // checked — see updateAgent above; AccountView.updateEvent applies its
        // local mutation unconditionally today, so a swallowed rejection here
        // would leave the UI showing an edit the server never saved.
        let tsArray = heartbeat.timestamps.map { $0 != nil ? $0! as Any : NSNull() as Any }
        let body: [String: Any] = [
            "agent_id":     heartbeat.agent_id,
            "timestamps":   tsArray,
            "prompt":       heartbeat.prompt,
            "group_id":     heartbeat.group_id ?? "",
            "notes_public": heartbeat.notes_public,
        ]
        _ = try await checkedRequestRaw("/agent/\(userId)/\(heartbeatId)/update_heartbeats", method: "PUT", jsonObject: body)
    }

    func commitHeartbeat(userId: String, agentId: String, heartbeatId: String, prompt: String) async throws -> [String: String] {
        // checked — the route gates this on the same free-tier "notes" cap as
        // addHeartbeat/createEvent, and a manual "execute now" trigger (task
        // 20260901-heartbeat-manual-trigger-button) must surface that 403 as
        // AppError.limitReached rather than silently decoding an empty/error
        // JSON body as if the fire succeeded (this previously used the
        // unchecked requestRaw, which never validated the HTTP status).
        //
        // "force": true — this method's one and only caller is
        // AccountViewModel.fireHeartbeatNow, the manual "execute now" trigger,
        // which per task 20260901-heartbeat-manual-force-fire must always
        // succeed regardless of whether this heartbeat already fired today
        // (by schedule or an earlier manual force-fire), without disturbing
        // the scheduler's own once-per-day claim (api/backend/interactions/
        // agent.py::commit_hb_response's forced branch never touches
        // last_fired). Since every call through this client method IS a
        // manual/forced fire, force is sent unconditionally here rather than
        // threading an unused parameter through the protocol for a case
        // (an unforced client-triggered fire) nothing in this app calls.
        let data = try await checkedRequestRaw(
            "/agent/\(userId)/\(agentId)/\(heartbeatId)/commit_heartbeat", method: "POST",
            jsonObject: ["prompt": prompt, "force": true]
        )
        return decode([String: String].self, from: data) ?? [:]
    }

    func summarizeSession(userId: String, agentId: String, session: FSSession, groupId: String) async throws {
        // checked — see updateAgent above.
        _ = try await checkedRequestRaw("/agent/\(userId)/\(agentId)/summarize", method: "POST",
                                  jsonObject: ["session": try jsonObject(session), "group_id": groupId])
    }
}
