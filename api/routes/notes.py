from fastapi import APIRouter, HTTPException, Depends, Query
from schemas.users import Note
from db import DBManager
from backend.errors import SaveFailedError
from backend.interactions.groups import GroupsManager
from backend.subscription.limits import check_limit
from backend.interactions.activity import ActivityManager, NOTE_CREATED, NOTE_EDITED, NOTE_REPLIED, VERSE_HIGHLIGHTED
from backend.interactions.bible_text import is_valid_reference
from backend.auth.dependencies import get_current_user, require_match
from backend.moderation.content_filter import check_clean, ContentRejected, rejection_message
from datetime import datetime
import uuid
import logging

notes_router = APIRouter(prefix="/notes")
logger = logging.getLogger(__name__)

# Page size for keyset-paginated note listings (GET /{user_id} here and
# GET /{user_id}/{group_id}/notes in community.py). Every GET-notes request
# is capped at this size by the SQL query itself -- there is no unpaginated
# full-fetch mode; callers that only need a total (DashboardView,
# AccountView) should use GET /{user_id}/count instead of paging through
# the whole collection.
NOTES_PAGE_SIZE = 15


def _record_activity(user_id: str, activity_type: str) -> None:
    """Best-effort activity-tracking bump — feeds the fixed-notification
    scheduled jobs (backend/interactions/scheduler.py). Never lets an
    activity-tracking failure fail the note/highlight write it's attached
    to; logs and moves on.

    activity_type (NOTE_CREATED / NOTE_EDITED / NOTE_REPLIED /
    VERSE_HIGHLIGHTED) is persisted alongside the bump so
    _friend_went_active_notify can name the action instead of sending a
    generic "came back" push; every call site below passes its own type
    explicitly."""
    activity = ActivityManager()
    try:
        activity.record_activity(user_id, activity_type)
    except Exception as e:
        logger.error("Failed to record activity for %s: %s", user_id, e)
    finally:
        activity.close()


def _can_view_note(note_data: dict, user_id: str) -> bool:
    """True if user_id may view (and therefore reply to) this note: its
    owner, or a note shared in a group the user belongs to. Visibility is
    now derived purely from group_id -- ``public`` no longer gates
    visibility at all; it instead gates whether a non-owner group member
    may *edit* the note (see update_note)."""
    if str(note_data.get("user_id") or "") == user_id:
        return True
    group_id = note_data.get("group_id")
    if group_id:
        gm = GroupsManager(user_id, group_id)
        try:
            return gm.is_member()
        finally:
            gm.close()
    return False


# ── Highlights ────────────────────────────────────────────────────────────────

@notes_router.get("/highlight/{user_id}")
async def get_highlights(user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DBManager()
    try:
        # highlights has a composite PK (user_id, key) with no _id column,
        # so lookup() would collapse all rows; use cursor for the read only.
        db.cur.execute("SELECT key, color FROM highlights WHERE user_id = %s", (user_id,))
        return {row[0]: row[1] for row in db.cur.fetchall()}
    finally:
        db.close()


@notes_router.post("/highlight/{user_id}")
async def highlight_verse(user_id: str, verse: dict, _: str = Depends(require_match("user_id"))) -> dict:
    book    = verse.get("book")
    chapter = verse.get("chapter")
    verse_n = verse.get("verse")
    color   = verse.get("color")
    if not all([book, chapter, verse_n, color]):
        raise HTTPException(status_code=400, detail="book, chapter, verse, color required")
    # Reference must be a real (book, chapter, verse) per bible_text's loaded
    # dataset -- see is_valid_reference's docstring (task
    # 20260904-friend-activity-push-triggers): this field is now exposed
    # verbatim to friends (push body + widget) when verse text can't be
    # resolved, so an unvalidated book/chapter/verse would be a stored
    # content-injection vector into a friend's device notification, not just
    # this user's own private data as before.
    try:
        chapter_i, verse_i = int(chapter), int(verse_n)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="chapter and verse must be integers")
    if not is_valid_reference(book, chapter_i, verse_i):
        raise HTTPException(status_code=400, detail="Not a recognized Bible reference")
    key = f"{book}-{chapter_i}-{verse_i}"
    db = DBManager()
    try:
        # timestamp is explicit (not left to the column's DEFAULT NOW()) so
        # a re-highlight of an already-highlighted verse also refreshes it --
        # ActivityManager.most_recent_highlight and get_friend_activity's
        # highlight_preview both need "most recently written", not "first
        # ever written", and DEFAULT NOW() only applies on the INSERT path,
        # never on an ON CONFLICT UPDATE.
        if not db.insertion(
            "highlights",
            {"user_id": user_id, "key": key, "color": str(color), "timestamp": datetime.now()},
            conflict="(user_id, key) DO UPDATE SET color = EXCLUDED.color, timestamp = EXCLUDED.timestamp",
        ):
            raise SaveFailedError()
        _record_activity(user_id, VERSE_HIGHLIGHTED)
        return {"key": key, "color": color}
    finally:
        db.close()


@notes_router.delete("/highlight/{user_id}/{key}")
async def remove_highlight(user_id: str, key: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DBManager()
    try:
        # Idempotent: removing a highlight that's already gone is a
        # legitimate no-op, not a failure -- a real DB error is still
        # visible via db.py's DB_WRITE_FAILURE log line.
        db.delete("highlights", {"user_id": user_id, "key": key})
        return {"success": "highlight removed"}
    finally:
        db.close()


# ── Bookmarks ─────────────────────────────────────────────────────────────────

@notes_router.get("/bookmark/{user_id}")
async def get_bookmarks(user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DBManager()
    try:
        # bookmarks has a composite PK (user_id, key) with no _id column.
        db.cur.execute("SELECT key, label FROM bookmarks WHERE user_id = %s", (user_id,))
        return {row[0]: row[1] for row in db.cur.fetchall()}
    finally:
        db.close()


@notes_router.post("/bookmark/{user_id}")
async def add_bookmark(user_id: str, bookmark: dict, _: str = Depends(require_match("user_id"))) -> dict:
    book    = bookmark.get("book")
    chapter = bookmark.get("chapter")
    label   = bookmark.get("label", "")
    if not all([book, chapter]):
        raise HTTPException(status_code=400, detail="book and chapter required")
    key = f"{book}-{chapter}"
    db = DBManager()
    try:
        if not db.insertion(
            "bookmarks",
            {"user_id": user_id, "key": key, "label": str(label)},
            conflict="(user_id, key) DO UPDATE SET label = EXCLUDED.label",
        ):
            raise SaveFailedError()
        return {"key": key, "label": label}
    finally:
        db.close()


@notes_router.delete("/bookmark/{user_id}/{key}")
async def remove_bookmark(user_id: str, key: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DBManager()
    try:
        # Idempotent, same reasoning as remove_highlight above.
        db.delete("bookmarks", {"user_id": user_id, "key": key})
        return {"success": "bookmark removed"}
    finally:
        db.close()


# ── Notes ─────────────────────────────────────────────────────────────────────

@notes_router.post("/reply/{note_id}", status_code=201)
async def post_reply(note_id: str, reply: dict, current_user: str = Depends(get_current_user)) -> dict:
    # The reply's author must be the authenticated caller, not whatever the
    # request body claims.
    author = reply.get("user", "")
    if author != current_user:
        raise HTTPException(status_code=403, detail="Forbidden")
    # Replies are notes too, so they count against the same weekly cap.
    gate = check_limit(author, "notes")
    if not gate["allowed"]:
        raise HTTPException(status_code=403, detail=gate)
    db = DBManager()
    try:
        parent = db.lookup("notes", {"_id": note_id})
        if not parent:
            return {"error": "cannot find note"}
        _, parent_data = list(parent.items())[0]
        # Same "cannot find note" message for missing vs. not-visible so a
        # caller can't use this endpoint to probe which private note ids exist.
        if not _can_view_note(parent_data, current_user):
            return {"error": "cannot find note"}
        reply_note = Note(**reply)
        try:
            check_clean(title=reply_note.title, text=reply_note.text)
        except ContentRejected as e:
            raise HTTPException(status_code=422, detail=rejection_message(e))
        reply_id   = str(uuid.uuid4())
        if not db.insertion("notes", {
            "_id":            reply_id,
            "user_id":        reply_note.user,
            "title":          reply_note.title,
            "text":           reply_note.text,
            "public":         reply_note.public,
            "group_id":       reply_note.group_id or None,
            "is_reply":       True,
            "parent_note_id": note_id,
            "timestamp":      reply_note.timestamp,
        }):
            raise SaveFailedError()
        # NOTE_REPLIED (task 20260904-friend-activity-push-triggers): a reply
        # used to fold into NOTE_CREATED -- now its own type so
        # _friend_went_active_notify can name "replied to {owner}'s note"
        # specifically instead of a generic "created a new note".
        _record_activity(author, NOTE_REPLIED)
        return {"id": reply_id}
    finally:
        db.close()


@notes_router.post("/{user_id}", status_code=201)
async def create_note(user_id: str, note_dict: dict, _: str = Depends(require_match("user_id"))) -> dict:
    gate = check_limit(user_id, "notes")
    if not gate["allowed"]:
        raise HTTPException(status_code=403, detail=gate)
    db = DBManager()
    try:
        note_id = str(uuid.uuid4())
        note_dict.setdefault("user", user_id)
        note = Note(**note_dict)
        # IDOR guard: a client-supplied group_id must be one the poster
        # actually belongs to, mirroring community.py::fetch_group_notes's
        # read-side check -- without this, any authenticated user could post
        # into a group they were never invited to.
        if note.group_id:
            gm = GroupsManager(user_id, note.group_id)
            try:
                if not gm.is_member():
                    raise HTTPException(status_code=403, detail="Not a member of this group")
            finally:
                gm.close()
        try:
            check_clean(title=note.title, text=note.text)
        except ContentRejected as e:
            raise HTTPException(status_code=422, detail=rejection_message(e))
        if not db.insertion("notes", {
            "_id":        note_id,
            # Deliberately the require_match-verified path param, NOT
            # note.user: note_dict.setdefault("user", user_id) above only
            # *defaults* the body's "user" field, it doesn't enforce it, so
            # an unvalidated body could otherwise attribute the note to an
            # arbitrary victim user_id -- authorship spoofing/impersonation,
            # and (combined with the group_id membership check above being
            # keyed on the real caller, not this field) a residual bypass of
            # this same fix's intent. Mirrors post_reply's explicit
            # `author != current_user` 403 a few endpoints up in this file.
            "user_id":    user_id,
            "title":      note.title,
            "text":       note.text,
            "public":     note.public,
            "group_id":   note.group_id or None,
            "is_reply":   note.is_reply,
            "timestamp":  note.timestamp,
            "created_at": datetime.now(),
        }):
            raise SaveFailedError()
        for i, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                if not db.insertion("note_verses", {
                    "note_id":  note_id,
                    "position": i,
                    "book":     verse[0],
                    "chapter":  verse[1],
                    "verse":    verse[2],
                }):
                    raise SaveFailedError()
        # NOTE: iOS's NetworkService.saveNote() decodes this response as
        # [String: String] (id -> value); a nested "data" object here used to
        # make that decode throw, so saveNote() silently fell back to the
        # client's locally-generated FSNote.id instead of this server-issued
        # note_id (decode() swallows the error via `try?`). The client then
        # keyed the new note under the wrong id, so a subsequent edit/delete
        # sent a note_id the server had never seen -> 404 "Note not found",
        # itself silently swallowed by the caller's `try?`. Keep this shape
        # minimal so it decodes cleanly; the frontend (useNotes.js) only ever
        # read `saved.id` too, so the "data" field was unused dead weight.
        #
        # Deliberately keyed off `user_id` (the require_match-verified path
        # param), NOT `note.user`: the request body's "user" field is
        # client-supplied and only defaulted (not overridden) to user_id, so
        # a caller could otherwise set an arbitrary "user" in the body and
        # trigger record_activity for a victim they don't own — feeding a
        # false inactive->active transition into the friend-went-active
        # notification path (spamming the victim's real friends) and
        # resetting the victim's midday/guilt dedup markers. See
        # .claude/pipeline/20260826-activity-based-notifications security
        # review (step 3).
        _record_activity(user_id, NOTE_CREATED)
        return {"id": note_id}
    finally:
        db.close()


@notes_router.get("/{user_id}")
async def get_notes(
    user_id: str,
    cursor_created_at: str | None = Query(default=None, description="created_at of the last note seen on the previous page; omit (with cursor_id) to fetch the first page"),
    cursor_id: str | None = Query(default=None, description="_id of the last note seen on the previous page; omit (with cursor_created_at) to fetch the first page"),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Retrieve one page of a user's personal (non-reply, non-group) notes,
    newest first, using keyset pagination anchored on (created_at, _id)
    rather than OFFSET -- so a note created or deleted between page loads
    can't shift another row's position and cause drift, duplicates, or
    skipped notes. Every call is capped at NOTES_PAGE_SIZE by the SQL query
    itself; there is no unpaginated full-fetch mode.

    Args:
        user_id: UUID of the notes' owner.
        cursor_created_at: created_at of the last note from the previous
            page. Omit together with cursor_id to fetch the first page.
        cursor_id: _id of the last note from the previous page. Must be
            supplied together with cursor_created_at.

    Returns:
        dict: ``{"notes": {note_id: note data}, "next_cursor_created_at":
            str | None, "next_cursor_id": str | None, "has_more": bool}``.
            Pass next_cursor_created_at/next_cursor_id back as
            cursor_created_at/cursor_id to fetch the following page.
            has_more is True iff exactly NOTES_PAGE_SIZE rows were returned
            -- False means the true end of the list has been reached, so the
            client should not request another page even though a cursor is
            still present.
    """
    db = DBManager()
    try:
        where = "n.user_id = %s AND n.is_reply = false AND n.group_id IS NULL"
        params: list = [user_id]
        if cursor_created_at is not None and cursor_id is not None:
            where += " AND (n.created_at, n._id) < (%s::timestamptz, %s::uuid)"
            params += [cursor_created_at, cursor_id]
        db.cur.execute(
            "SELECT n._id, n.user_id, n.title, n.text, n.public, n.group_id, n.is_reply, n.timestamp, n.created_at "
            "FROM notes n "
            f"WHERE {where} "
            "ORDER BY n.created_at DESC, n._id DESC "
            "LIMIT %s",
            params + [NOTES_PAGE_SIZE],
        )
        rows = db.cur.fetchall()
        result = {}
        for row in rows:
            nid = str(row[0])
            db.cur.execute(
                "SELECT position, book, chapter::text, verse::text "
                "FROM note_verses WHERE note_id = %s ORDER BY position",
                (nid,)
            )
            verses = [[r[1], r[2], r[3]] for r in db.cur.fetchall()]
            result[nid] = {
                "user":       str(row[1] or ""),
                "title":      row[2],
                "text":       row[3],
                "public":     row[4],
                "group_id":   row[5] or "",
                "is_reply":   row[6],
                "timestamp":  str(row[7] or ""),
                "created_at": str(row[8] or ""),
                "verses":     verses,
                "replies":    [],
            }
        has_more = len(rows) == NOTES_PAGE_SIZE
        last = rows[-1] if rows else None
        return {
            "notes": result,
            "next_cursor_created_at": str(last[8]) if last else None,
            "next_cursor_id": str(last[0]) if last else None,
            "has_more": has_more,
        }
    finally:
        db.close()


@notes_router.get("/{user_id}/search")
async def search_notes(
    user_id: str,
    q: str = Query(..., min_length=1, description="Keyword to match (case-insensitive substring) against note title or text"),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Search a user's personal (non-reply, non-group) notes by keyword
    against title and/or text.

    Unlike GET /{user_id}, this returns every matching note in one response
    rather than a NOTES_PAGE_SIZE page -- the "no unpaginated full-fetch
    mode" rule on that endpoint exists to bound a full-collection dump; a
    keyword search is instead bounded by the query itself, so there's no
    equivalent drift/duplication risk from returning the whole match set at
    once.

    Args:
        user_id: UUID of the notes' owner.
        q: Keyword to match (ILIKE substring, case-insensitive) against
            title or text.

    Returns:
        dict: ``{"notes": {note_id: note data}}``, newest first. Same
            per-note shape as GET /{user_id} (including "verses" and an
            always-empty "replies" list).
    """
    db = DBManager()
    try:
        pattern = f"%{q}%"
        db.cur.execute(
            "SELECT n._id, n.user_id, n.title, n.text, n.public, n.group_id, n.is_reply, n.timestamp, n.created_at "
            "FROM notes n "
            "WHERE n.user_id = %s AND n.is_reply = false AND n.group_id IS NULL "
            "AND (n.title ILIKE %s OR n.text ILIKE %s) "
            "ORDER BY n.created_at DESC, n._id DESC",
            (user_id, pattern, pattern),
        )
        rows = db.cur.fetchall()
        result = {}
        for row in rows:
            nid = str(row[0])
            db.cur.execute(
                "SELECT position, book, chapter::text, verse::text "
                "FROM note_verses WHERE note_id = %s ORDER BY position",
                (nid,)
            )
            verses = [[r[1], r[2], r[3]] for r in db.cur.fetchall()]
            result[nid] = {
                "user":       str(row[1] or ""),
                "title":      row[2],
                "text":       row[3],
                "public":     row[4],
                "group_id":   row[5] or "",
                "is_reply":   row[6],
                "timestamp":  str(row[7] or ""),
                "created_at": str(row[8] or ""),
                "verses":     verses,
                "replies":    [],
            }
        return {"notes": result}
    finally:
        db.close()


@notes_router.get("/{user_id}/note/{note_id}")
async def get_note(user_id: str, note_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Fetch a single note by id -- backs the friend-activity-feed "open this
    note" entry point (tapping a friend's note_preview) and any other
    single-note-by-id lookup.

    Always does a fresh ``notes`` lookup and re-derives visibility via
    ``_can_view_note`` on every call -- never trusts the friend-activity
    feed's own prior filtering, or any client-supplied preview data, as
    proof of access (deny-by-default). A missing note and a
    found-but-not-visible note return the byte-identical
    ``{"error": "cannot find note"}`` response (same shape as ``post_reply``
    above), so note-id enumeration can't distinguish "doesn't exist" from
    "exists but you can't see it".

    Args:
        user_id: UUID of the authenticated viewer (not necessarily the
            note's owner) -- verified against the session via require_match.
        note_id: UUID of the note to fetch.

    Returns:
        dict: the note on success, in the same per-note shape as
            ``GET /{user_id}``/``GET /{user_id}/search`` (including
            "verses" and an always-empty "replies" list), plus a
            "username" field (the owner's display name) those two routes
            omit -- they only ever return the caller's own notes, so the
            client already knows the owner; here the note may belong to a
            friend, and NoteDetailView's canEdit gate needs the owner's
            username (not just user_id) to compare against the viewer's own
            username. ``{"error": "cannot find note"}`` if the note doesn't
            exist or the viewer isn't permitted to see it.
    """
    db = DBManager()
    try:
        existing = db.lookup("notes", {"_id": note_id})
        if not existing:
            return {"error": "cannot find note"}
        _, note_data = list(existing.items())[0]
        # Same "cannot find note" message for missing vs. not-visible as
        # post_reply above -- closes the enumeration oracle.
        if not _can_view_note(note_data, user_id):
            return {"error": "cannot find note"}
        db.cur.execute(
            "SELECT position, book, chapter::text, verse::text "
            "FROM note_verses WHERE note_id = %s ORDER BY position",
            (note_id,)
        )
        verses = [[r[1], r[2], r[3]] for r in db.cur.fetchall()]
        owner_id = str(note_data.get("user_id") or "")
        username = ""
        if owner_id:
            owner = db.lookup("users", {"_id": owner_id})
            if owner:
                _, owner_data = list(owner.items())[0]
                username = owner_data.get("username") or ""
        return {
            "user":       owner_id,
            "username":   username,
            "title":      note_data.get("title"),
            "text":       note_data.get("text"),
            "public":     note_data.get("public"),
            "group_id":   str(note_data.get("group_id") or ""),
            "is_reply":   note_data.get("is_reply"),
            "timestamp":  str(note_data.get("timestamp") or ""),
            "created_at": str(note_data.get("created_at") or ""),
            "verses":     verses,
            "replies":    [],
        }
    finally:
        db.close()


@notes_router.get("/{user_id}/count")
async def get_notes_count(user_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Total count of a user's personal (non-reply, non-group) notes.

    A dedicated COUNT(*) so summary displays (DashboardView, AccountView)
    that only need a number don't have to page through the full capped
    collection to compute one.

    Args:
        user_id: UUID of the notes' owner.

    Returns:
        dict: ``{"count": int}``.
    """
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT COUNT(*) FROM notes WHERE user_id = %s AND is_reply = false AND group_id IS NULL",
            (user_id,),
        )
        return {"count": db.cur.fetchone()[0]}
    finally:
        db.close()


@notes_router.put("/{user_id}")
async def update_note(user_id: str, note_id: str, note_dict: dict, _: str = Depends(require_match("user_id"))) -> None:
    """Update an existing note.

    The owner may always edit their own note. A non-owner may edit an
    existing note iff it currently has a group_id, the caller is a member
    of that group, and the note's stored `public` value is True -- `public`
    no longer means "visible to others" (see _can_view_note); it means
    "group members other than the owner may edit this note". Deny-by-default:
    any lookup/membership failure or ambiguity denies the edit rather than
    allowing it.
    """
    db = DBManager()
    try:
        existing = db.lookup("notes", {"_id": note_id})
        if not existing:
            raise HTTPException(status_code=404, detail="Note not found")
        _, note_data = list(existing.items())[0]
        is_owner = str(note_data.get("user_id") or "") == user_id
        if not is_owner:
            # Non-owner group-edit branch (new authorization surface): only
            # reachable when the note already has a group_id, the caller is
            # a current member of THAT group (never a client-supplied one --
            # see the retargeting guard just below), and the note's owner
            # opted it into group-editing via public == True. Any failure
            # here (no group_id, not a member, public not True, or a
            # GroupsManager lookup miss) falls through to the 403 below --
            # fail closed, not open.
            existing_group_id = note_data.get("group_id")
            allowed = False
            if existing_group_id and note_data.get("public"):
                gm = GroupsManager(user_id, existing_group_id)
                try:
                    allowed = gm.is_member()
                finally:
                    gm.close()
            if not allowed:
                raise HTTPException(status_code=403, detail="Not authorized")
        note = Note(**note_dict)
        if not is_owner and (note.group_id or None) != note_data.get("group_id"):
            # IDOR guard: a non-owner's edit was only authorized by their
            # membership in the note's CURRENT group. Without this check the
            # same request could smuggle a different (or empty) group_id
            # through the payload, either stripping the note out of the
            # group whose membership authorized the edit, or retargeting it
            # at a different group the caller may not belong to.
            raise HTTPException(status_code=403, detail="Not authorized")
        # Same IDOR guard as create_note -- re-targeting an existing owned
        # note at an arbitrary group_id must also require membership.
        if note.group_id:
            gm = GroupsManager(user_id, note.group_id)
            try:
                if not gm.is_member():
                    raise HTTPException(status_code=403, detail="Not a member of this group")
            finally:
                gm.close()
        try:
            check_clean(title=note.title, text=note.text)
        except ContentRejected as e:
            raise HTTPException(status_code=422, detail=rejection_message(e))
        # `existing` above already confirmed the note exists, so a False
        # return here is a real write failure, not an expected no-op.
        if not db.update(
            "notes",
            {
                "title":     note.title,
                "text":      note.text,
                "public":    note.public,
                "group_id":  note.group_id or None,
                "timestamp": datetime.now(),   # bump so lists can sort by last-edited
            },
            {"_id": note_id},
        ):
            raise SaveFailedError()
        # Sync note_verses: replace all existing verse rows with the ones
        # from the PUT body. A note with no prior verses is a legitimate
        # zero-rows no-op here, so this delete isn't checked; each fresh
        # insertion below is checked, since a silently-dropped verse row
        # would leave the note's scripture references incomplete.
        db.delete("note_verses", {"note_id": note_id})
        for i, verse in enumerate(note.verses):
            if isinstance(verse, list) and len(verse) >= 3:
                if not db.insertion("note_verses", {
                    "note_id":  note_id,
                    "position": i,
                    "book":     verse[0],
                    "chapter":  verse[1],
                    "verse":    verse[2],
                }):
                    raise SaveFailedError()
        # Same activity-tracking bump as create_note/post_reply/
        # highlight_verse -- previously missing here, which meant an edit
        # never counted as activity or could queue a friend notification.
        # Keyed off the require_match-verified user_id path param, matching
        # the same IDOR-avoidance reasoning as create_note's own comment
        # above (note.user_id was already re-validated against user_id
        # earlier in this handler, so this call can't be pointed at a
        # victim's activity row either).
        _record_activity(user_id, NOTE_EDITED)
    finally:
        db.close()


@notes_router.delete("/{user_id}")
async def delete_note(user_id: str, note_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    db = DBManager()
    try:
        existing = db.lookup("notes", {"_id": note_id})
        if not existing:
            raise HTTPException(status_code=404, detail="Note not found")
        _, note_data = list(existing.items())[0]
        if str(note_data.get("user_id")) != user_id:
            raise HTTPException(status_code=403, detail="Not authorized")
        # `existing` above already confirmed the note exists, so a False
        # return here is a real write failure, not an expected no-op.
        if not db.delete("notes", {"_id": note_id}):
            raise SaveFailedError()
        return {"success": "note deleted"}
    finally:
        db.close()
