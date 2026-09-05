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

    // Defensive bound on every request built by the four helpers below. Chosen
    // as half of URLSession's own 60s default (timeoutIntervalForRequest) --
    // generous enough not to false-positive on a slow-but-alive connection,
    // while making sure a stalled/black-holed connect phase (the one plausible
    // mechanism identified for the never-reproduced NetworkServiceGetErrorHandlingTests
    // hang -- see 20260828-networkservice-get-hang-investigation) can no longer
    // hang indefinitely. This is defensive hardening, not a confirmed-bug fix:
    // four real xcodebuild attempts (three prior + one full-suite re-attempt
    // during this task) never reproduced the hang.
    private static let requestTimeout: TimeInterval = 30

    private func url(_ path: String) -> URL {
        URL(string: apiBase + path)!
    }

    private func get(_ path: String) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.timeoutInterval = Self.requestTimeout
        let (data, response) = try await URLSession.shared.data(for: req)
        // Validate status like request()/checkedRequestRaw() do — previously this
        // never called throwIfError, so every fetch* built on it silently turned
        // an HTTP error (e.g. a 401 from an expired session) into a blank default
        // value or empty collection instead of surfacing a thrown error. Fixed at
        // this single shared helper since it underlies nearly every domain's reads.
        try throwIfError(response, data)
        return data
    }

    private func request(_ path: String, method: String, body: Encodable? = nil) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
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
        req.timeoutInterval = Self.requestTimeout
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
        req.timeoutInterval = Self.requestTimeout
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

    /// Decodes `data` as `T`. Callers keep their existing "nil on failure →
    /// fall back to an empty/default value" behavior (that part is
    /// unchanged and still intentional for these best-effort reads) — what
    /// changes is that a failure is no longer silently discarded. It's
    /// always logged, and when `endpoint` is given (the call sites that
    /// matter most for diagnosing a broken contract) it's also beaconed to
    /// the server via `reportDecodeFailure`.
    ///
    /// This replaces a blanket `try? JSONDecoder().decode(...)` that swallowed
    /// every decode failure with zero logging or user-facing signal anywhere
    /// in this file — which is exactly why the notes-load-failure incident
    /// this fix is part of (an out-of-date client build silently failing to
    /// decode the new `GET /notes/{user_id}` envelope) produced no error
    /// trail on the client side either. See notes-load-failure-cloudwatch-gap
    /// intake spec.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String = "") -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let context = endpoint.isEmpty ? "\(T.self)" : endpoint
            print("[NetworkService] decode(\(T.self)) failed for \(context): \(error)")
            if !endpoint.isEmpty {
                reportDecodeFailure(endpoint: endpoint, summary: String(describing: error))
            }
            return nil
        }
    }

    /// Logs + beacons a thrown fetch failure (a non-2xx HTTP response or
    /// transport error surfaced by throwIfError()/URLSession) for a given
    /// endpoint, then rethrows so the caller's own fallback behavior (e.g. a
    /// `try? ... ?? .empty` degrade-to-cache pattern) is unchanged — this
    /// only makes the failure visible, it never changes control flow.
    ///
    /// Complements decode(endpoint:) above: that one covers a 200 response
    /// this client can't parse; this one covers the response never getting
    /// that far at all (e.g. a 404/500). Both were silent before — a fetch
    /// failure caught by a bare `try?` at the call site (as
    /// DashboardViewModel.load() does for fetchFriendActivity) previously
    /// vanished with zero signal, exactly the gap that let a stale-deploy
    /// 404 on GET /friends/{user_id}/activity hide the check-in row with no
    /// error trail anywhere. See 20260827-checkin-row-investigation.
    private func reportFetchFailure<T>(endpoint: String, operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            print("[NetworkService] fetch failed for \(endpoint): \(error)")
            reportDecodeFailure(endpoint: endpoint, summary: String(describing: error))
            throw error
        }
    }

    /// "\(short) (\(build))", e.g. "1.4.2 (37)" — matches
    /// `ClientErrorReport.client_app_version`'s documented format, the key
    /// signal for distinguishing an out-of-date client build from a genuine
    /// current-code bug when triaging a reported detection.
    private func currentAppVersion() -> String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Fire-and-forget beacon to `POST /monitoring/client-error` (backend
    /// step 1 of the notes-load-failure-cloudwatch-gap workflow) — the
    /// server-log-based CloudWatch watchdog can never see a well-formed 200
    /// response an out-of-date client fails to decode on its own, so this is
    /// the only way that class of failure becomes visible at all. Diagnostics
    /// only: deliberately best-effort (`try?`) so a beacon failure (e.g. no
    /// network) never surfaces to or blocks the caller that hit the original
    /// decode failure. Never sends the raw response body — only the
    /// endpoint, app version, and a short error summary, per
    /// `ClientErrorReport`'s data-minimization contract.
    private func reportDecodeFailure(endpoint: String, summary: String) {
        let version = currentAppVersion()
        Task {
            _ = try? await requestRaw("/monitoring/client-error", method: "POST", jsonObject: [
                "endpoint": endpoint,
                "client_app_version": version,
                "error_summary": String(summary.prefix(500)),
            ])
        }
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

    /// Invalidates the server-side session (deletes the row + clears the cookie).
    /// Auth is cookie-based (URLSession's shared HTTPCookieStorage sends it
    /// automatically), so no user id / body is needed — the session token in
    /// the request cookie identifies which session to end.
    func logout() async throws {
        _ = try await request("/logout", method: "POST")
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
        // checkedRequestRaw (not requestRaw) so a 4xx/5xx response (e.g. a
        // rejected timezone identifier or an auth failure) is raised as an
        // AppError instead of silently falling through to the decode below.
        let data = try await checkedRequestRaw("/user/\(userId)", method: "PUT", jsonObject: body)
        guard let user = decode(FSUser.self, from: data) else {
            let detail = extractErrorDetail(from: data) ?? "Update failed."
            throw AppError.networkError(detail)
        }
        return user
    }

    func deleteUser(userId: String) async throws {
        _ = try await request("/user/\(userId)", method: "DELETE")
    }

    // ── Notes (read) ──────────────────────────────────────────────────────────
    // GET /notes/{userId}?cursor_created_at=&cursor_id=
    // Every call returns one SQL-capped (15), keyset-paginated page; there is
    // no unpaginated full-fetch mode. Omit both cursor params for the first
    // page; pass a previous page's next cursor back to fetch the following one.

    private func cursorQuery(_ cursorCreatedAt: String?, _ cursorId: String?) -> String {
        guard let c = cursorCreatedAt, let i = cursorId else { return "" }
        return "?cursor_created_at=\(encodeURIComponent(c))&cursor_id=\(encodeURIComponent(i))"
    }

    func fetchNotes(userId: String, cursorCreatedAt: String? = nil, cursorId: String? = nil) async throws -> NotesPage {
        let data = try await get("/notes/\(userId)" + cursorQuery(cursorCreatedAt, cursorId))
        guard let raw = decode(RawNotesPage.self, from: data, endpoint: "GET /notes/{user_id}") else {
            return NotesPage(notes: [:], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
        }
        var dict = raw.notes
        for (key, var note) in dict { note.id = key; dict[key] = note }
        return NotesPage(notes: dict, nextCursorCreatedAt: raw.next_cursor_created_at,
                         nextCursorId: raw.next_cursor_id, hasMore: raw.has_more)
    }

    func fetchGroupNotes(userId: String, groupId: String, cursorCreatedAt: String? = nil, cursorId: String? = nil) async throws -> NotesPage {
        let raw = try await get("/groups/\(userId)/\(groupId)/notes" + cursorQuery(cursorCreatedAt, cursorId))
        // Response shape: { notes: { username: { note_id: { user_id, title, text, public, group_id, is_reply, timestamp } } },
        //                    next_cursor_created_at, next_cursor_id, has_more }
        guard let top = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let outer = top["notes"] as? [String: Any] else {
            // Same silent-failure class as fetchNotes' RawNotesPage decode
            // above, just reached via manual JSONSerialization instead of
            // JSONDecoder (this response is keyed by username, so it can't
            // use a static Decodable type the same way) — log + beacon it
            // too rather than letting group segments fail invisibly.
            let context = groupId.isEmpty ? "?" : groupId
            print("[NetworkService] fetchGroupNotes decode failed for group \(context): unexpected response shape")
            reportDecodeFailure(endpoint: "GET /groups/{user_id}/{group_id}/notes",
                                 summary: "Unexpected response shape (missing/invalid top-level 'notes' object)")
            return NotesPage(notes: [:], nextCursorCreatedAt: nil, nextCursorId: nil, hasMore: false)
        }

        let groupNotesEndpoint = "GET /groups/{user_id}/{group_id}/notes"
        var result: [String: FSNote] = [:]
        for (username, byNote) in outer {
            guard let noteMap = byNote as? [String: Any] else {
                let context = username.isEmpty ? "?" : username
                print("[NetworkService] fetchGroupNotes: notes[\(context)] is not an object, skipping that member's notes")
                reportDecodeFailure(endpoint: groupNotesEndpoint,
                                     summary: "notes[username] value is not a JSON object")
                continue
            }
            for (noteId, rawFields) in noteMap {
                // Previously this whole per-note pipeline (dict-cast, re-serialize,
                // FSNote decode) collapsed into a single `guard ... else { continue }`
                // with zero diagnostics — any one note's field-shape mismatch silently
                // vanished with no trace of which step failed or why. Split into
                // distinct, beaconed failure points (matching this file's existing
                // reportDecodeFailure convention) so a future occurrence is visible
                // instead of just manifesting as "other members' notes are missing".
                guard var fields = rawFields as? [String: Any] else {
                    print("[NetworkService] fetchGroupNotes: notes[\(username)][\(noteId)] value is not an object, dropping note")
                    reportDecodeFailure(endpoint: groupNotesEndpoint,
                                         summary: "notes[username][note_id] value is not a JSON object")
                    continue
                }
                // The DB column is "user_id"; FSNote.CodingKey is "user"
                fields["user"]     = fields["user_id"] ?? ""
                fields["id"]       = noteId
                fields["group_id"] = groupId
                // Ensure these keys exist so FSNote decodes cleanly
                if fields["verses"]  == nil { fields["verses"]  = [[Any]]() }
                if fields["replies"] == nil { fields["replies"] = [Any]() }
                fields.removeValue(forKey: "user_id")

                guard let noteData = try? JSONSerialization.data(withJSONObject: fields) else {
                    print("[NetworkService] fetchGroupNotes: failed to re-serialize note \(noteId) (keys: \(fields.keys.sorted())), dropping note")
                    reportDecodeFailure(endpoint: groupNotesEndpoint,
                                         summary: "Failed to re-serialize note fields for JSON encoding (keys: \(fields.keys.sorted()))")
                    continue
                }
                guard var note = decode(FSNote.self, from: noteData, endpoint: groupNotesEndpoint) else {
                    // decode() already logs + beacons this case (endpoint is non-empty
                    // here, unlike the previous unlabeled call), but add the note id
                    // for correlation since decode()'s own summary doesn't have it.
                    print("[NetworkService] fetchGroupNotes: FSNote decode failed for note \(noteId), dropping note")
                    continue
                }
                note.id       = noteId
                note.group_id = groupId
                // Stamp the outer "notes[username]" key onto the decoded note so
                // the UI can attribute authorship — the note payload itself only
                // carries user_id (-> note.user), never a display-ready username.
                note.username = username
                result[noteId] = note
            }
        }
        return NotesPage(
            notes: result,
            nextCursorCreatedAt: top["next_cursor_created_at"] as? String,
            nextCursorId: top["next_cursor_id"] as? String,
            hasMore: top["has_more"] as? Bool ?? false
        )
    }

    // GET /notes/{userId}/count — a dedicated COUNT(*) so summary displays
    // (DashboardView, AccountView) that only need a total don't have to page
    // through the whole capped collection to compute one.
    func fetchNotesCount(userId: String) async throws -> Int {
        let data = try await get("/notes/\(userId)/count")
        // task 20260903-account-stats-not-loading: this was previously the
        // untagged decode(...) form, so a decode failure here (distinct from
        // a thrown HTTP/network error, which the caller already handles)
        // produced zero server-side signal -- it silently collapsed to the
        // same "0 notes" the account genuinely having no notes would show.
        // Tagged now so a recurrence is visible via reportDecodeFailure/CloudWatch.
        return decode([String: Int].self, from: data, endpoint: "GET /notes/{user_id}/count")?["count"] ?? 0
    }

    // ── Notes (keyword search) ───────────────────────────────────────────────
    // GET /notes/{userId}/search?q=...                   -- Personal notes
    // GET /groups/{userId}/{groupId}/notes/search?q=...  -- group notes
    // Both are segment-scoped exactly like fetchNotes/fetchGroupNotes above,
    // and both return every matching (non-reply) note in one flat response
    // rather than a keyset-paginated page -- bounded by the query itself,
    // not a full-collection dump, so the "no unpaginated full-fetch mode"
    // contract on the list endpoints above doesn't apply here (task
    // 20260903-notes-keyword-search).

    func searchNotes(userId: String, query: String) async throws -> [String: FSNote] {
        let data = try await get("/notes/\(userId)/search?q=\(encodeURIComponent(query))")
        guard let raw = decode(RawSearchNotes.self, from: data, endpoint: "GET /notes/{user_id}/search") else {
            return [:]
        }
        var dict = raw.notes
        for (key, var note) in dict { note.id = key; dict[key] = note }
        return dict
    }

    func searchGroupNotes(userId: String, groupId: String, query: String) async throws -> [String: FSNote] {
        let raw = try await get("/groups/\(userId)/\(groupId)/notes/search?q=\(encodeURIComponent(query))")
        // Response shape mirrors fetchGroupNotes's { notes: { username: { note_id: {...} } } }
        // (see GroupsManager.search_notes) -- same per-note fields, just no
        // cursor/has_more since this isn't paginated.
        guard let top = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let outer = top["notes"] as? [String: Any] else {
            let context = groupId.isEmpty ? "?" : groupId
            print("[NetworkService] searchGroupNotes decode failed for group \(context): unexpected response shape")
            reportDecodeFailure(endpoint: "GET /groups/{user_id}/{group_id}/notes/search",
                                 summary: "Unexpected response shape (missing/invalid top-level 'notes' object)")
            return [:]
        }

        let searchEndpoint = "GET /groups/{user_id}/{group_id}/notes/search"
        var result: [String: FSNote] = [:]
        for (username, byNote) in outer {
            guard let noteMap = byNote as? [String: Any] else {
                let context = username.isEmpty ? "?" : username
                print("[NetworkService] searchGroupNotes: notes[\(context)] is not an object, skipping that member's notes")
                reportDecodeFailure(endpoint: searchEndpoint,
                                     summary: "notes[username] value is not a JSON object")
                continue
            }
            for (noteId, rawFields) in noteMap {
                guard var fields = rawFields as? [String: Any] else {
                    print("[NetworkService] searchGroupNotes: notes[\(username)][\(noteId)] value is not an object, dropping note")
                    reportDecodeFailure(endpoint: searchEndpoint,
                                         summary: "notes[username][note_id] value is not a JSON object")
                    continue
                }
                // The DB column is "user_id"; FSNote.CodingKey is "user"
                fields["user"]     = fields["user_id"] ?? ""
                fields["id"]       = noteId
                fields["group_id"] = groupId
                if fields["verses"]  == nil { fields["verses"]  = [[Any]]() }
                if fields["replies"] == nil { fields["replies"] = [Any]() }
                fields.removeValue(forKey: "user_id")

                guard let noteData = try? JSONSerialization.data(withJSONObject: fields) else {
                    print("[NetworkService] searchGroupNotes: failed to re-serialize note \(noteId) (keys: \(fields.keys.sorted())), dropping note")
                    reportDecodeFailure(endpoint: searchEndpoint,
                                         summary: "Failed to re-serialize note fields for JSON encoding (keys: \(fields.keys.sorted()))")
                    continue
                }
                guard var note = decode(FSNote.self, from: noteData, endpoint: searchEndpoint) else {
                    print("[NetworkService] searchGroupNotes: FSNote decode failed for note \(noteId), dropping note")
                    continue
                }
                note.id       = noteId
                note.group_id = groupId
                note.username = username
                result[noteId] = note
            }
        }
        return result
    }

    // ── Notes (single fetch by id) ───────────────────────────────────────────
    // GET /notes/{userId}/note/{noteId} -- task
    // 20260903-friend-activity-note-navigation. Backs the Friend Activity
    // hero card's note-preview tap target. Response is the note fields
    // directly at the top level (no `notes: {...}` wrapper -- this is
    // always exactly one note), plus a `username` field for the owner: this
    // is the one notes-read endpoint that can return a note the caller
    // doesn't own, so NoteDetailView.canEdit needs the owner's username to
    // compare against the viewer's own (see backend step 2's summary).
    //
    // On a missing-or-not-visible note the server returns the identical
    // `{"error": "cannot find note"}` body (implicit 200, not an
    // HTTPException) that post_reply already established, so note-id
    // enumeration can't distinguish the two cases -- checked for explicitly
    // here since FSNote's own lenient Decodable (every field defaulted)
    // would otherwise happily decode that error body into a garbage
    // "empty" note instead of surfacing the failure.
    func fetchNote(userId: String, noteId: String) async throws -> FSNote {
        let endpoint = "GET /notes/{user_id}/note/{note_id}"
        let data = try await get("/notes/\(userId)/note/\(encodeURIComponent(noteId))")
        // Same user-visible message for both branches (missing vs. no-longer-
        // visible), matching the server's own identical-response IDOR-safe
        // contract for this endpoint -- this client never has grounds to
        // say anything more specific than "not available" either.
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], obj["error"] != nil {
            throw AppError.networkError("That note is no longer available.")
        }
        guard var note = decode(FSNote.self, from: data, endpoint: endpoint) else {
            throw AppError.networkError("That note is no longer available.")
        }
        note.id = noteId
        return note
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

    // ── Notes (replies) ──────────────────────────────────────────────────────
    // GET  /groups/{userId}/{noteId}/{groupId}/replies   -- group notes (existing route, wired here for the first time)
    // GET  /notes/{userId}/{noteId}/replies               -- personal notes (new backend route, this pass)
    // POST /notes/reply/{noteId}                          body: {user, text, title, public, group_id, verses, replies, is_reply}
    //
    // Both GET routes share the same response contract: a raw `list[dict]`
    // of reply rows on success, or `{"error": "cannot find note"}` (still
    // HTTP 200 -- not a thrown 4xx) when the parent note doesn't exist or
    // isn't visible to the caller. decode() below treats either a genuine
    // parse failure or that error shape as "no replies", which
    // NoteDetailView's Option A section renders identically to a true empty
    // state -- per the spec, a loading/absent-data state must never show a
    // stale/flashing zero-count, so collapsing both into [] is deliberate.

    /// Fetches every reply to `noteId`, routing to the group or personal
    /// replies endpoint depending on whether `groupId` is non-empty (pass
    /// `note.group_id` straight through). The group route's backing
    /// `GroupsManager.fetch_replies()` now carries each reply's real row id
    /// under `"id"` (task 20260904-reply-edit-button, backend step 1 --
    /// previously discarded once `lookup()`'s result was unwrapped into a
    /// flat list), so this:
    /// (1) decodes that real `id` per reply and uses it as `FSNote.id`,
    ///     falling back to a synthesized UUID only if the field is ever
    ///     absent (e.g. the personal-notes replies route, which has no
    ///     server-side implementation yet and is unreachable from
    ///     `NoteDetailView` today) -- a real id is required for a reply
    ///     Edit save to `PUT /notes/{userId}?note_id=` the correct row
    ///     rather than a throwaway one with no relationship to it;
    /// (2) resolves each distinct author's display username via the
    ///     existing `fetchUser` endpoint, concurrently -- mirroring
    ///     `fetchContacts`'s per-friend username resolution above. A
    ///     user_id that fails to resolve (deleted account, transient error)
    ///     degrades to `FSNote.username == ""`, which NoteDetailView's
    ///     reply cards already render as the deliberate author-less state
    ///     documented on `FSNote.username` (Models.swift:183-189) -- not a
    ///     crash or a placeholder.
    func fetchReplies(userId: String, noteId: String, groupId: String) async throws -> [FSNote] {
        let path: String
        let endpoint: String
        if groupId.isEmpty {
            path     = "/notes/\(userId)/\(encodeURIComponent(noteId))/replies"
            endpoint = "GET /notes/{user_id}/{note_id}/replies"
        } else {
            path     = "/groups/\(userId)/\(encodeURIComponent(noteId))/\(encodeURIComponent(groupId))/replies"
            endpoint = "GET /groups/{user_id}/{note_id}/{group_id}/replies"
        }
        let data = try await reportFetchFailure(endpoint: endpoint) { try await self.get(path) }
        guard let raw = decode([RawReplyNote].self, from: data, endpoint: endpoint) else { return [] }

        let userIds = Set(raw.compactMap { $0.user_id }.filter { !$0.isEmpty })
        var usernames: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for uid in userIds {
                group.addTask { [self] in (uid, try? await self.fetchUser(userId: uid).username) }
            }
            for await (uid, name) in group {
                if let name, !name.isEmpty { usernames[uid] = name }
            }
        }

        return raw.map { r in
            var note = FSNote()
            note.id        = r.id ?? UUID().uuidString
            note.user      = r.user_id ?? ""
            note.username  = usernames[r.user_id ?? ""] ?? ""
            note.title     = r.title ?? ""
            note.text      = r.text ?? ""
            note.public    = r.public ?? false
            note.group_id  = r.group_id ?? ""
            note.is_reply  = r.is_reply ?? true
            note.timestamp = r.timestamp ?? r.created_at ?? ""
            return note
        }
    }

    /// Posts a reply via the existing `POST /notes/reply/{noteId}` route
    /// (unchanged by this pass; only this client call is new). `reply.user`
    /// must equal the authenticated caller -- `post_reply()` 403s otherwise
    /// -- so callers must stamp it from `AppState.currentUser.user_id`, not
    /// the parent note's author. checkedRequestRaw so a content-filter
    /// rejection (422) or a free-tier notes-limit 403 (replies count
    /// against the same weekly cap as any other note, per `post_reply()`)
    /// throws instead of silently no-opping.
    ///
    /// Returns the new reply's id. Callers should append a local copy of
    /// `reply` (with this id) to their in-memory replies list rather than
    /// refetching -- the same optimistic, id-swap pattern
    /// `NotesViewModel.saveNote(_:editingId:userId:)` already uses for the
    /// main note save round-trip.
    func postReply(_ reply: FSNote, noteId: String) async throws -> String {
        let body: [String: Any] = [
            "user":     reply.user,
            "text":     reply.text,
            "title":    reply.title,
            "public":   reply.public,
            "group_id": reply.group_id,
            "verses":   [],
            "replies":  [],
            "is_reply": true,
        ]
        let data = try await checkedRequestRaw("/notes/reply/\(encodeURIComponent(noteId))", method: "POST", jsonObject: body)
        guard let resp = decode([String: String].self, from: data), let id = resp["id"] else {
            throw AppError.networkError(extractErrorDetail(from: data) ?? "Could not post reply.")
        }
        return id
    }

    // ── Highlights ────────────────────────────────────────────────────────────
    // GET    /notes/highlight/{userId}
    // POST   /notes/highlight/{userId}             body: {book, chapter, verse, color}
    // DELETE /notes/highlight/{userId}/{encodedKey}

    func fetchHighlights(userId: String) async throws -> [String: String] {
        let data = try await get("/notes/highlight/\(userId)")
        // task 20260903-account-stats-not-loading: tagged like fetchNotesCount
        // above -- a decode failure here (e.g. a value shape the plain
        // [String: String] decode doesn't tolerate) previously vanished
        // indistinguishably from "this account really has zero highlights".
        return decode([String: String].self, from: data, endpoint: "GET /notes/highlight/{user_id}") ?? [:]
    }

    func saveHighlight(userId: String, book: String, chapter: Int, verse: Int, color: String) async throws {
        // checkedRequestRaw (not requestRaw) so a 4xx/5xx response (e.g. an
        // expired session or a free-tier highlight limit) throws instead of
        // being silently discarded — callers optimistically mutate local
        // state and must be able to revert on failure.
        _ = try await checkedRequestRaw("/notes/highlight/\(userId)", method: "POST",
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
        // checkedRequestRaw (not requestRaw) — same rationale as saveHighlight above.
        _ = try await checkedRequestRaw("/notes/bookmark/\(userId)", method: "POST",
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

    func addHeartbeat(userId: String, agentId: String, heartbeat: FSHeartbeat) async throws {
        let tsArray = heartbeat.timestamps.map { $0 != nil ? $0! as Any : NSNull() as Any }
        // group_id: "" (rather than omitting the key) matches the server's
        // own `body.get("group_id") or None` falsy check in api/routes/agent.py.
        let body: [String: Any] = [
            "timestamps":   tsArray,
            "prompt":       heartbeat.prompt,
            "group_id":     heartbeat.group_id ?? "",
            "notes_public": heartbeat.notes_public,
        ]
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

    // ── Attachments (task 20260904-messaging-attachments) ────────────────────
    // Wire contract per design-notes.md's "Wire contract" section / backend
    // step 2: request a presigned S3 POST policy over plain HTTP, then upload
    // the raw bytes directly to S3 with it — this server never receives the
    // file itself. GIF search is a thin authenticated proxy (backend step 2)
    // so the provider API key never reaches this client.

    private struct AttachmentUploadURLBody: Encodable {
        let attachment_kind: String
        let content_type:    String
        let size_bytes:      Int?
    }

    // POST /message/upload-url/{userId} → {url, fields, object_key, expires_in}
    func requestAttachmentUploadURL(userId: String, attachmentKind: String, contentType: String, sizeBytes: Int?) async throws -> FSUploadURLInfo {
        let body = AttachmentUploadURLBody(attachment_kind: attachmentKind, content_type: contentType, size_bytes: sizeBytes)
        let data = try await request("/message/upload-url/\(userId)", method: "POST", body: body)
        guard let info = decode(FSUploadURLInfo.self, from: data, endpoint: "/message/upload-url") else {
            throw AppError.networkError("Could not prepare that upload. Please try again.")
        }
        return info
    }

    /// Uploads raw bytes directly to S3 using the presigned POST policy from
    /// `requestAttachmentUploadURL` — a multipart/form-data POST straight to
    /// `uploadInfo.url`, not this app's own API (`apiBase` is deliberately
    /// unused here). `uploadInfo.fields` must ride ahead of the file part
    /// (S3's presigned-POST contract), and every field key must be present
    /// exactly as issued — the policy's signature covers them.
    func uploadAttachment(fileData: Data, contentType: String, uploadInfo: FSUploadURLInfo) async throws {
        guard let uploadURL = URL(string: uploadInfo.url) else {
            throw AppError.networkError("Could not reach upload storage.")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        for (key, value) in uploadInfo.fields {
            appendField(key, value)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[NetworkService] Attachment upload to S3 failed with status \(status)")
            throw AppError.networkError("Upload failed. Please try again.")
        }
    }

    private struct RawGifSearchResponse: Decodable {
        let results: [FSGifResult]
    }

    // GET /message/gif-search?q= → {results: [...]}
    func searchGifs(query: String) async throws -> [FSGifResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let data = try await get("/message/gif-search?q=\(encoded)")
        guard let resp = decode(RawGifSearchResponse.self, from: data, endpoint: "/message/gif-search") else { return [] }
        return resp.results
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

    // ── Groups ────────────────────────────────────────────────────────────────
    // POST   /groups/{userId}         body: {group_id, title, users}
    // DELETE /groups/{userId}/{groupId}

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
    // POST   /notification/{userId}/device-token
    //
    // The user-authored notification CRUD/trigger endpoints this file used to
    // call (GET/POST/PUT/DELETE /notification/{userId}[...]) were removed from
    // the backend in 20260826-activity-based-notifications; device-token
    // registration and push delivery are unaffected and kept below.

    func registerDeviceToken(userId: String, token: String) async throws {
        // checked so a write failure is at least logged by the caller instead of
        // vanishing — this endpoint's DB write can fail like any other and there
        // is no other signal (no UI polls "is my token registered?").
        _ = try await checkedRequestRaw("/notification/\(userId)/device-token", method: "POST",
                                 jsonObject: ["token": token])
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
        // checkedRequestRaw (not requestRaw) so a real 400/403 rejection throws
        // with the server's actual detail instead of silently falling through
        // to the generic "Could not start plan." guard below.
        let data = try await checkedRequestRaw("/subscriptions/", method: "POST", jsonObject: body)
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
        // checkedRequestRaw so a 403 ("only the host may do this") or 404 (plan
        // gone) actually throws instead of being silently discarded — mirrors
        // updateUser()/createGroup() elsewhere in this file.
        _ = try await checkedRequestRaw("/subscriptions/\(encodeURIComponent(subscriptionId))", method: "PUT",
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
        // This is the highest-stakes call in the app — real Apple money has
        // already changed hands by the time StoreKitManager.purchase() calls
        // this. checkedRequestRaw (not requestRaw) so a 400 (invalid
        // transaction / untrusted environment / unknown product) or 409
        // (subscription already linked to a different account) actually
        // throws instead of silently decoding an error body into a lenient,
        // bogus-default FSSubscription — StoreKitManager depends on this
        // throwing to know whether it's safe to finish() the transaction and
        // report the purchase as successful.
        let data = try await checkedRequestRaw("/subscriptions/apple/sync", method: "POST",
                                               jsonObject: ["user_id": userId, "jws": jws])
        // A successful "expired" response (`{"status": "expired"}`) has no id,
        // same as fetchUserSubscription's no-subscription case just above —
        // treat a missing id as "no active subscription" rather than a bogus
        // empty-id plan.
        guard let sub = decode(FSSubscription.self, from: data), !sub.id.isEmpty else { return nil }
        return sub
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private func encodeURIComponent(_ s: String) -> String {
        // .urlQueryAllowed treats '+' as a legal sub-delim character per raw URI
        // syntax and leaves it unescaped. But query strings are decoded using
        // application/x-www-form-urlencoded conventions (by FastAPI/Starlette and
        // virtually every other web framework), where an unescaped '+' means
        // "space", not a literal plus sign. Any value that can contain a literal
        // '+' — e.g. an ISO-8601 timestamp with a UTC offset like "+00:00", as
        // used by the notes-pagination cursor — must have it escaped as "%2B" or
        // it gets silently corrupted into a space server-side. Remove '+' from
        // the allowed set so addingPercentEncoding always escapes it.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
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
    // Task 20260904-messaging-attachments: null/absent for an ordinary
    // text-only message. `attachment_url` (image/video/file only) is a
    // freshly presigned GET the server resolves at read time — never a
    // durable/storable URL.
    let attachment_kind: String?
    let attachment_meta: FSAttachmentMeta?
    let attachment_url:  String?
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

private struct RawNotesPage: Decodable {
    let notes: [String: FSNote]
    let next_cursor_created_at: String?
    let next_cursor_id: String?
    let has_more: Bool
}

/// Raw shape of `GET /notes/{user_id}/search`'s success response --
/// `{"notes": {note_id: note_data}}`, same per-note fields as RawNotesPage
/// but with no cursor/has_more (search returns every match in one response).
private struct RawSearchNotes: Decodable {
    let notes: [String: FSNote]
}

/// Raw shape of one item in `GET /notes/{user_id}/{note_id}/replies` and
/// `GET /groups/{user_id}/{note_id}/{group_id}/replies`'s success response.
/// Both routes return `GroupsManager.fetch_replies()`'s raw DB rows
/// (`SELECT *` minus the primary key -- `DBManager.lookup()` keys its
/// returned dict by `_id`, and `fetch_replies()` then drops that key via
/// `.values()`) rather than the same field-remapping `GET /notes/{user_id}`
/// applies to top-level notes. So there is no `id` in the payload, and the
/// author key is `user_id`, not `user` -- `NetworkService.fetchReplies`
/// remaps both when building each reply's `FSNote`.
private struct RawReplyNote: Decodable {
    // Real DB row id (task 20260904-reply-edit-button, backend step 1):
    // `GroupsManager.fetch_replies` now re-attaches the id `lookup()` already
    // had (previously discarded once unwrapped into a flat list) under this
    // key. Optional -- the personal-notes replies route has no server-side
    // implementation yet (out of scope; `NoteDetailView` never calls that
    // branch), so this stays nil there and `fetchReplies` below falls back
    // to a synthesized id rather than crashing a decode that's otherwise
    // still valid.
    let id:             String?
    let user_id:       String?
    let title:          String?
    let text:           String?
    let `public`:       Bool?
    let group_id:       String?
    let is_reply:       Bool?
    let parent_note_id: String?
    let timestamp:      String?
    let created_at:     String?
}
