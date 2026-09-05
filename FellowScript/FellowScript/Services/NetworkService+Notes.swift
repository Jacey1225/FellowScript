// NetworkService+Notes.swift — Notes read (paginated, keyword search,
// single-note fetch), write, and replies. Split out of NetworkService.swift
// (readability #H16, 20260904-frontend-arch-sweep) -- same type, same
// behavior, just this domain's own file. See NetworkService.swift's header
// comment for the full split rationale and the list of sibling domain files.

import Foundation

extension NetworkService {

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
    ///     crash or a placeholder. Task 20260905-profile-photo: the same
    ///     `fetchUser` call also now carries `profile_photo_url`, so each
    ///     reply's author photo is resolved here at no extra network cost
    ///     (`GroupsManager.fetch_replies` itself was never extended to join
    ///     it server-side) -- an unresolved author degrades to `nil`
    ///     exactly like `username` degrades to "", letting NoteDetailView's
    ///     reply monogram fall back to initials.
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
        var photoURLs: [String: String] = [:]
        await withTaskGroup(of: (String, FSUser?).self) { group in
            for uid in userIds {
                group.addTask { [self] in (uid, try? await self.fetchUser(userId: uid)) }
            }
            for await (uid, user) in group {
                guard let user, !user.username.isEmpty else { continue }
                usernames[uid] = user.username
                photoURLs[uid] = user.profile_photo_url
            }
        }

        return raw.map { r in
            var note = FSNote()
            note.id        = r.id ?? UUID().uuidString
            note.user      = r.user_id ?? ""
            note.username  = usernames[r.user_id ?? ""] ?? ""
            note.profile_photo_url = photoURLs[r.user_id ?? ""]
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
}
