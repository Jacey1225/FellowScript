import logging
import uuid
from datetime import datetime

import psycopg2 as sql

from schemas.users import User
from schemas.message import Group
from db import DBManager, _redact_db_error
from backend import content_store
from backend.content_config import get_content_config
from backend.errors import SaveFailedError
from backend.interactions.attachments import generate_download_url
from backend.interactions import lifecycle, paging
from backend.interactions.message_reactions import attach_reactions
from backend.interactions.note_search import scan_matches

logger = logging.getLogger(__name__)

# Group title column is VARCHAR(255) (db.py).
GROUP_TITLE_MAX_LENGTH = 255

# Tunable: attachments returned per gallery page (explicit load-more paging,
# no infinite scroll). A plain module constant, matching this codebase's
# convention for application-behavior tunables (routes/notes.py's
# NOTES_PAGE_SIZE, attachments.py's PER_KIND_LIMITS) -- not an env var.
GALLERY_PAGE_SIZE = 24

# messages columns added for paging / soft delete; never part of a response row.
_INTERNAL_MESSAGE_COLUMNS = ("seq", "deleted_at", "deleted_by")

# Gallery ``kind`` filter values; anything else is rejected, never coerced.
GALLERY_KINDS = frozenset({"image", "video", "gif", "file"})


def normalize_group_title(title: str) -> str:
    """Strip and validate a group title.

    Raises:
        ValueError: If the title is blank or longer than the VARCHAR(255)
            column allows (checked after stripping).
    """
    cleaned = (title or "").strip()
    if not cleaned:
        raise ValueError("Group name can't be empty")
    if len(cleaned) > GROUP_TITLE_MAX_LENGTH:
        raise ValueError(f"Group name must be {GROUP_TITLE_MAX_LENGTH} characters or fewer")
    return cleaned


class GroupFullError(Exception):
    """Adding members would push the group past its owner-set ``max_members``."""


class GroupOwnerOnlyError(Exception):
    """The caller isn't the group's creator (fail closed: also raised when the
    group has no creator_id, so legacy ownerless groups can't set a cap)."""


class ListedGroupOwnerOnlyError(Exception):
    """The group has Explorer presence (a listing in review, published or
    hidden) and this ``PUT /groups`` change is owner-only: a non-creator adding
    members, or anyone removing the creator from the member list. The route
    maps it to 409 ``{"code": "owner_only"}``. Groups without a listing never
    raise it."""


class InvalidMemberError(Exception):
    """A NEW member id supplied to create/update is not a valid, existing,
    non-suspended user. Identical for malformed and non-existent ids so the
    422 never becomes an existence oracle."""


# R4-1: the ONE place the groups.users (TEXT[]) -> users join is written.
# Readers (PAG author_set, WSH recipients, THR recipients, LST live member
# count) import this and never write their own join. It is a correlated
# subquery body: it references the outer groups alias ``g``, e.g.
#   SELECT x.id FROM groups g, LATERAL (SELECT u._id::text AS id, m.ord
#       {LIVE_MEMBER_JOIN}) x WHERE g._id = %s
# The users side is matched through a CASE-guarded uuid cast of the array
# element, never ``u._id::text = x`` (that casts the indexed column and
# full-scans users); the CASE also stops a junk string from raising a uuid
# cast error. A NULL element or a NULL array yields no row. ``ORDINALITY``
# keeps array order for ``live_member_ids``.
LIVE_MEMBER_JOIN = (
    "FROM unnest(g.users) WITH ORDINALITY AS m(member_id, ord) "
    "JOIN users u ON u._id = CASE WHEN m.member_id ~* "
    "'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "
    "THEN m.member_id::uuid END"
)


def live_member_ids(cur, group_id: str) -> list[str]:
    """Canonical lowercase ids of the group's current members that still exist
    as users, array order preserved, de-duplicated. Empty for an unknown or
    malformed group id. Built from ``LIVE_MEMBER_JOIN``."""
    canon = _canonical_uuid(group_id)
    if canon is None:
        return []
    cur.execute(
        "SELECT x.id FROM groups g, LATERAL (SELECT u._id::text AS id, m.ord "
        + LIVE_MEMBER_JOIN
        + ") x WHERE g._id = %s::uuid GROUP BY x.id ORDER BY min(x.ord)",
        (canon,),
    )
    return [r[0] for r in cur.fetchall()]


def author_set(cur, group_id: str, user_id: str) -> list[str]:
    """Ids whose messages ``user_id`` may see in ``group_id``: the caller plus
    the group's CURRENT members, minus anyone in a blocked relationship with
    the caller in either direction.

    Members are resolved only through ``live_member_ids`` (the shared
    ``LIVE_MEMBER_JOIN``), so a dead account id or a junk string in
    ``groups.users`` is ignored and can never make a ``= ANY(...::uuid[])``
    page predicate raise. The caller's own id is always included (their own
    messages stay visible) and is never filtered by a block. Blocking is
    applied here so the page query can filter in SQL and a page never shrinks
    or fakes an "end of history". Canonical lowercase uuid strings, de-duplicated.

    This is the read-side guard that keeps messages injected by a non-member
    (the send path trusts client-supplied ``group_id``) out of history.
    """
    me = _canonical_uuid(user_id)
    members = live_member_ids(cur, group_id)
    if me is None:
        return []
    cur.execute(
        "SELECT blocked_id::text FROM blocked_users WHERE blocker_id = %s::uuid "
        "UNION SELECT blocker_id::text FROM blocked_users WHERE blocked_id = %s::uuid",
        (me, me),
    )
    blocked = {str(r[0]).lower() for r in cur.fetchall()}
    authors = {me}
    authors.update(m for m in members if m not in blocked)
    return sorted(authors)


def _canonical_uuid(value) -> str | None:
    """Lowercase canonical UUID string, or None when ``value`` is not a UUID."""
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


class GroupsManager(DBManager):
    """Handles all group-level data operations for a single user/group context."""

    def __init__(self, user_id: str, group_id: str = "") -> None:
        super().__init__()
        self.user_id  = user_id
        self.group_id = group_id
        result = self.lookup("users", {"_id": user_id})
        if result:
            uid, data = list(result.items())[0]
            self.user = User(user_id=uid, **data)
        else:
            self.user = User()

    def _blocked_set(self) -> set[str]:
        """IDs in a blocked relationship with self.user_id, either direction —
        Guideline 1.2: a block must hide that user's content from the blocker's
        feed. One query, reused by every fetch method below."""
        self.cur.execute(
            "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
            "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s",
            (self.user_id, self.user_id),
        )
        return {str(r[0]) for r in self.cur.fetchall()}

    def _fetch_verses_map(self, note_ids: list[str]) -> dict[str, list[list]]:
        """Batch-resolve attached verses for a set of note ids in one query,
        keyed by note_id -> ``[[book, chapter, verse], ...]`` ordered by
        ``position`` -- the same per-note shape routes/notes.py's personal-
        notes equivalents (GET /{user_id}, /{user_id}/search) already
        produce, just batched via a single ``WHERE note_id = ANY(...)``
        rather than one query per note. A single query fits this file's
        existing pattern of batching the per-page author lookup (username/
        profile_photo_key above) rather than looping per row, and this list
        is already page-capped the same way. Without this, fetch_notes/
        search_notes never touched note_verses at all, so a group note's
        "verses" key was always absent from the response -- the iOS client
        then defaulted the missing key to [] and NoteRow correctly hid the
        (empty) verse-chip row, even though the note genuinely had attached
        verses (see .claude/pipeline/20260908-group-notes-verses).

        Args:
            note_ids: note _id strings to resolve verses for.

        Returns:
            dict[str, list[list]]: note_id -> ordered verse triples. A note
                with no attached verses (or not present in note_ids) simply
                has no key -- callers should ``.get(nid, [])``.
        """
        if not note_ids:
            return {}
        self.cur.execute(
            "SELECT note_id, position, book, chapter::text, verse::text "
            "FROM note_verses WHERE note_id = ANY(%s::uuid[]) "
            "ORDER BY note_id, position",
            (note_ids,),
        )
        verses_map: dict[str, list[list]] = {}
        for row in self.cur.fetchall():
            verses_map.setdefault(str(row[0]), []).append([row[2], row[3], row[4]])
        return verses_map

    def is_member(self) -> bool:
        """True if ``self.user_id`` belongs to ``self.group_id``'s member list."""
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return False
        _, group_data = list(group.items())[0]
        return self.user_id in (group_data.get("users") or [])

    def format_messages(self, messages: dict) -> list[dict]:
        from_uids = {str(uid) for uid in (data.get("from_user", "") for data in messages.values()) if uid}
        usernames: dict[str, str] = {}
        if from_uids:
            self.cur.execute(
                "SELECT _id, username FROM users WHERE _id = ANY(%s::uuid[])",
                (list(from_uids),),
            )
            usernames = {str(r[0]): r[1] for r in self.cur.fetchall()}
        result = []
        for message_id, data in messages.items():
            from_uid = str(data.get("from_user", "") or "")
            if from_uid in usernames:
                data = {**data, "from_user": usernames[from_uid]}
            # Task 20260904-messaging-attachments / security step 5 fix:
            # render via a fresh, short-lived presigned GET issued at read
            # time -- the stored attachment_key itself is never handed to
            # the client (see backend/interactions/attachments.py), mirroring
            # FriendsManager._format_dm_row's DM equivalent. `data` here
            # originates from a raw `SELECT *`/`lookup()` row (fetch_group),
            # so attachment_key must be popped unconditionally rather than
            # merely read -- leaving it in `data` would otherwise ride
            # straight through to the client on every group history response,
            # defeating the whole point of resolving it to a short-lived URL
            # instead of a permanent, cacheable object key. None for a
            # text-only message or a gif (whose url already lives in
            # attachment_meta).
            data = dict(data)
            attachment_key = data.pop("attachment_key", None)
            if attachment_key:
                data["attachment_url"] = generate_download_url(attachment_key)
            # Ordering/soft-delete columns are internal: the legacy shape is
            # unchanged except for the additive ``id`` (string UUID), added
            # last so key order is otherwise identical.
            for internal in _INTERNAL_MESSAGE_COLUMNS:
                data.pop(internal, None)
            data["id"] = str(message_id)
            result.append(data)
        attach_reactions(self, result, self.user_id)
        return result

    def _validate_new_member_ids(self, ids) -> dict[str, str]:
        """Map each raw id -> canonical id for ids that are valid, existing,
        non-suspended users. Raises ``InvalidMemberError`` (same error for a
        malformed, non-existent or suspended id) on the first bad one. The
        caller's own id always passes without a lookup."""
        canon_by_raw: dict[str, str] = {}
        for raw in ids:
            canon = _canonical_uuid(raw)
            if canon is None:
                raise InvalidMemberError()
            canon_by_raw[raw] = canon
        needed = [c for c in dict.fromkeys(canon_by_raw.values()) if c != str(self.user_id).lower()]
        if needed:
            self.cur.execute(
                "SELECT _id::text FROM users WHERE _id = ANY(%s::uuid[]) AND suspended_at IS NULL",
                (needed,),
            )
            live = {r[0] for r in self.cur.fetchall()}
            self.conn.rollback()  # read-only; release the snapshot
            if any(c not in live for c in needed):
                raise InvalidMemberError()
        return canon_by_raw

    def create_group(self, users: list[str], group: Group) -> None:
        """Create a new group and add it to each member's groups list.

        Args:
            users: List of user IDs to add as initial members.
            group: ``Group`` schema instance with group_id, title, and users.

        Raises:
            InvalidMemberError: a supplied member id is malformed, does not
                exist or is suspended (the creator's own id always passes).
        """
        # Membership lives in the groups.users column; GET /user derives each
        # user's group list from it, so no separate per-user sync is needed.
        # creator_id is stamped from self.user_id (the authenticated caller
        # the route resolved via require_match, i.e. GroupsManager's own
        # constructor arg) -- never from the client-supplied `group` payload,
        # so a caller can't spoof ownership of a group they didn't actually
        # create.
        canon = self._validate_new_member_ids(list(group.users or []))
        members = list(dict.fromkeys(canon[raw] for raw in (group.users or [])))
        if not self.insertion("groups", {
            "_id":         group.group_id,
            "title":       group.title,
            "users":       members,
            "creator_id":  self.user_id,
        }):
            raise SaveFailedError()

    def fetch_message_page(self, limit: int, cursor: "paging.Cursor | None" = None) -> dict:
        """One keyset page of group history, newest page first.

        A SINGLE query: ``group_id`` and ``deleted_at IS NULL`` and
        ``from_user = ANY(author_set)`` (the caller plus CURRENT live members
        minus both-direction blocks, so a page never shrinks and never fakes
        an "end of history"), optionally bounded by the keyset predicate on
        ``(timestamp, COALESCE(seq, 0), _id)``. It fetches ``limit + 1`` rows
        so ``has_more`` is exact. Rows come back OLDEST-first so a client
        prepends a page verbatim; ``next_cursor`` is the oldest row of the
        page and is set only when ``has_more``.

        ``limit`` must already be clamped by the caller; the cursor must come
        from ``paging.decode_cursor`` (validated, bound as typed parameters,
        never string-built). Returns ``{"messages", "has_more", "next_cursor"}``
        with the row shape ``{id, from_user (username), mine, text, timestamp
        (ISO Z), attachment_kind, attachment_meta, attachment_url}``; the
        stored ``attachment_key`` never leaves the server.
        """
        authors = author_set(self.cur, self.group_id, self.user_id)
        sql_text = (
            "SELECT _id, from_user, text, timestamp, attachment_kind, attachment_key, "
            "attachment_meta, COALESCE(seq, 0) AS seq "
            "FROM messages WHERE group_id = %s::uuid AND deleted_at IS NULL "
            "AND from_user = ANY(%s::uuid[]) "
        )
        params: list = [self.group_id, authors]
        if cursor is not None:
            sql_text += f"AND (timestamp, COALESCE(seq, 0), _id) < ({paging.TS_SQL}, {paging.SEQ_SQL}, {cursor.id_sql}) "
            params.extend(cursor.params())
        sql_text += "ORDER BY timestamp DESC, COALESCE(seq, 0) DESC, _id DESC LIMIT %s"
        params.append(limit + 1)
        self.cur.execute(sql_text, params)
        rows = self.cur.fetchall()
        self.conn.rollback()  # read-only; release the snapshot

        has_more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = None
        if has_more and rows:
            oldest = rows[-1]
            next_cursor = paging.encode_cursor(oldest[3], oldest[7], oldest[0])

        usernames: dict[str, str] = {}
        from_uids = {str(r[1]) for r in rows if r[1]}
        if from_uids:
            self.cur.execute(
                "SELECT _id, username FROM users WHERE _id = ANY(%s::uuid[])",
                (list(from_uids),),
            )
            usernames = {str(r[0]): r[1] for r in self.cur.fetchall()}
            self.conn.rollback()
        me = str(self.user_id).lower()
        messages = []
        for _id, from_user, text, ts, kind, key, meta, _seq in reversed(rows):
            from_uid = str(from_user) if from_user else ""
            messages.append({
                "id": str(_id),
                "from_user": usernames.get(from_uid, ""),
                "mine": from_uid.lower() == me,
                "text": content_store.open_(_id, content_store.F_MESSAGE_TEXT, text),
                "timestamp": paging.format_timestamp(ts),
                "attachment_kind": kind,
                "attachment_meta": meta,
                "attachment_url": generate_download_url(key) if key else None,
            })
        attach_reactions(self, messages, self.user_id)
        return {"messages": messages, "has_more": has_more, "next_cursor": next_cursor}

    def fetch_group(self, paged: bool = False) -> dict:
        """Retrieve full group data including members and message history.

        Args:
            paged: when True the two unbounded message queries are skipped
                (the caller supplies the newest page via ``fetch_message_page``)
                and ``host_msgs``/``other_msgs`` are omitted from the result.

        Returns:
            dict: Contains ``group`` metadata, ``members`` list, ``host_msgs``,
                and ``other_msgs``. Returns ``{"error": str}`` if the group
                does not exist.
        """
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return {"error": "Group not found"}
        _, group_data = list(group.items())[0]
        member_ids = [u for u in group_data.get("users", []) if u != self.user_id]
        blocked    = self._blocked_set()
        usernames: list = []
        other_msgs: dict = {}
        if member_ids:
            self.cur.execute(
                "SELECT _id, username FROM users WHERE _id = ANY(%s::uuid[])",
                (member_ids,),
            )
            user_map = {str(r[0]): r[1] for r in self.cur.fetchall()}
            # Roster stays unfiltered for transparency about who's in the
            # group — only their message content is hidden below.
            usernames = [user_map[uid] for uid in member_ids if uid in user_map]

            unblocked_ids = [uid for uid in member_ids if uid not in blocked]
            if unblocked_ids and not paged:
                self.cur.execute(
                    "SELECT * FROM messages WHERE from_user = ANY(%s::uuid[]) AND group_id = %s "
                    "AND deleted_at IS NULL",
                    (unblocked_ids, self.group_id),
                )
                cols = [desc[0] for desc in self.cur.description]
                other_msgs = {
                    row[0]: content_store.open_row("messages", row[0], dict(zip(cols[1:], row[1:])))
                    for row in self.cur.fetchall()
                }
        host_msgs: dict = {}
        if not paged:
            # Raw SELECT (not lookup) so soft-deleted rows can be excluded;
            # same columns and keying as lookup() returned.
            self.cur.execute(
                "SELECT * FROM messages WHERE from_user = %s AND group_id = %s AND deleted_at IS NULL",
                (self.user_id, self.group_id),
            )
            cols = [desc[0] for desc in self.cur.description]
            host_msgs = {
                row[0]: content_store.open_row("messages", row[0], dict(zip(cols[1:], row[1:])))
                for row in self.cur.fetchall()
            }
        # Task 20260929-group-info-panel: never hand the stored photo_key to
        # the client -- resolve it to a fresh presigned GET at read time
        # (same rule as attachment_key in format_messages). New fields are
        # additive; old clients ignore them.
        group_data = dict(group_data)
        photo_key = group_data.pop("photo_key", None)
        group_data["photo_url"] = generate_download_url(photo_key)
        group_data["muted"] = self.is_muted()
        if paged:
            return {"group": group_data, "members": usernames}
        return {
            "group":      group_data,
            "members":    usernames,
            "host_msgs":  self.format_messages(host_msgs),
            "other_msgs": self.format_messages(other_msgs),
        }

    def fetch_notes(
        self,
        limit: int = 15,
        cursor_created_at: str | None = None,
        cursor_id: str | None = None,
    ) -> dict:
        """Retrieve one page of non-reply notes belonging to the group,
        newest first, using keyset pagination anchored on
        (created_at, _id) rather than OFFSET -- so a note created or deleted
        between page loads can't shift another row's position and cause
        drift, duplicates, or skipped notes. Blocked-user exclusion
        (Guideline 1.2) happens in the SQL WHERE clause itself, not as a
        post-fetch Python filter, so a full page always contains ``limit``
        visible notes.

        Uses the raw cursor (rather than ``lookup``) because ordering,
        LIMIT, and the blocked-user anti-join aren't expressible through the
        generic helpers.

        Args:
            limit: Max notes to return for this page.
            cursor_created_at: created_at of the last note from the previous
                page. Omit together with cursor_id to fetch the first page.
            cursor_id: _id of the last note from the previous page. Must be
                supplied together with cursor_created_at.

        Returns:
            dict: ``{"notes": {username: {note_id: note data}},
                "next_cursor_created_at": str | None, "next_cursor_id":
                str | None, "has_more": bool}``. has_more is True iff
                exactly ``limit`` rows were returned. Each note's data now
                also carries ``profile_photo_url`` (the author's photo,
                resolved via ``generate_download_url`` -- ``None`` when the
                author has no photo set; task 20260905-profile-photo-avatar-gaps)
                and ``verses`` (``[[book, chapter, verse], ...]`` ordered by
                ``position``, ``[]`` when the note has none -- same shape as
                routes/notes.py's personal-notes equivalents; task
                20260908-group-notes-verses).
        """
        where = (
            "group_id = %s AND is_reply = false "
            "AND user_id NOT IN ("
            "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
            "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s"
            ")"
        )
        params: list = [self.group_id, self.user_id, self.user_id]
        if cursor_created_at is not None and cursor_id is not None:
            where += " AND (created_at, _id) < (%s::timestamptz, %s::uuid)"
            params += [cursor_created_at, cursor_id]
        self.cur.execute(
            "SELECT _id, user_id, title, text, public, group_id, is_reply, "
            "parent_note_id, timestamp, created_at FROM notes "
            f"WHERE {where} "
            "ORDER BY created_at DESC, _id DESC "
            "LIMIT %s",
            params + [limit],
        )
        cols = [desc[0] for desc in self.cur.description]
        rows = self.cur.fetchall()
        row_data = [(str(row[0]), content_store.open_row("notes", row[0], dict(zip(cols[1:], row[1:])))) for row in rows]
        distinct_uids = {str(data.get("user_id")) for _, data in row_data if data.get("user_id")}
        username_map: dict[str, str] = {}
        # Task 20260905-profile-photo-avatar-gaps: mirrors friends.py's
        # get_requests/get_friends precedent -- resolve each author's
        # profile_photo_key to a fresh, short-lived presigned GET via
        # generate_download_url (never the raw key itself), keyed alongside
        # username so both can be stamped onto each note below.
        photo_map: dict[str, str | None] = {}
        if distinct_uids:
            self.cur.execute(
                "SELECT _id, username, profile_photo_key FROM users WHERE _id = ANY(%s::uuid[])",
                (list(distinct_uids),),
            )
            for r in self.cur.fetchall():
                uid_str = str(r[0])
                username_map[uid_str] = r[1]
                photo_map[uid_str] = generate_download_url(r[2])
        verses_map = self._fetch_verses_map([nid for nid, _ in row_data])
        group_notes: dict = {}
        for nid, data in row_data:
            uid = data.get("user_id")
            if not uid:
                continue
            uid_str = str(uid)
            username = username_map.get(uid_str, "")
            if username not in group_notes:
                group_notes[username] = {}
            group_notes[username][nid] = {
                **data,
                "profile_photo_url": photo_map.get(uid_str),
                "verses": verses_map.get(nid, []),
            }
        has_more = len(rows) == limit
        last = rows[-1] if rows else None
        return {
            "notes": group_notes,
            "next_cursor_created_at": str(last[9]) if last else None,
            "next_cursor_id": str(last[0]) if last else None,
            "has_more": has_more,
        }

    def search_notes(self, q: str) -> dict:
        """Search the group's non-reply notes by keyword against title/text.

        Unlike ``fetch_notes``, this returns every matching note in one
        response rather than a keyset-paginated page -- the pagination
        contract there exists to bound a full-collection dump, but a
        keyword search is already bounded by the query itself. Same
        blocked-user exclusion as ``fetch_notes`` (SQL-level, not a
        post-fetch Python filter).

        Args:
            q: Keyword to match (literal case-insensitive substring) against
                title or text, after decryption in the app (bounded by
                ``group_search_scan_cap``; see note_search.py).

        Returns:
            dict: ``{"notes": {username: {note_id: note data}}}``, newest
                first. Each note's data now also carries
                ``profile_photo_url`` (the author's photo, resolved via
                ``generate_download_url`` -- ``None`` when the author has no
                photo set; task 20260905-profile-photo-avatar-gaps) and
                ``verses`` (``[[book, chapter, verse], ...]`` ordered by
                ``position``, ``[]`` when the note has none; task
                20260908-group-notes-verses).
        """
        # Title/text are ciphertext at rest: SQL scopes the candidates (group,
        # non-reply, block filter), the app decrypts and filters
        # (backend/interactions/note_search.py).
        cols = ["_id", "user_id", "title", "text", "public", "group_id", "is_reply",
                "parent_note_id", "timestamp", "created_at"]
        rows, _truncated = scan_matches(
            self.cur,
            "SELECT _id, user_id, title, text, public, group_id, is_reply, "
            "parent_note_id, timestamp, created_at FROM notes",
            "group_id = %s AND is_reply = false "
            "AND user_id NOT IN ("
            "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
            "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s"
            ")",
            [self.group_id, self.user_id, self.user_id],
            q,
            idx_id=0, idx_created=9, idx_title=2, idx_text=3,
            created_expr="created_at", id_expr="_id",
            scan_cap=get_content_config().group_search_scan_cap,
        )
        row_data = [(str(row[0]), dict(zip(cols[1:], row[1:]))) for row in rows]
        distinct_uids = {str(data.get("user_id")) for _, data in row_data if data.get("user_id")}
        username_map: dict[str, str] = {}
        # Task 20260905-profile-photo-avatar-gaps: same presigned-GET
        # resolution as fetch_notes above, mirroring friends.py's
        # get_requests/get_friends precedent.
        photo_map: dict[str, str | None] = {}
        if distinct_uids:
            self.cur.execute(
                "SELECT _id, username, profile_photo_key FROM users WHERE _id = ANY(%s::uuid[])",
                (list(distinct_uids),),
            )
            for r in self.cur.fetchall():
                uid_str = str(r[0])
                username_map[uid_str] = r[1]
                photo_map[uid_str] = generate_download_url(r[2])
        verses_map = self._fetch_verses_map([nid for nid, _ in row_data])
        group_notes: dict = {}
        for nid, data in row_data:
            uid = data.get("user_id")
            if not uid:
                continue
            uid_str = str(uid)
            username = username_map.get(uid_str, "")
            if username not in group_notes:
                group_notes[username] = {}
            group_notes[username][nid] = {
                **data,
                "profile_photo_url": photo_map.get(uid_str),
                "verses": verses_map.get(nid, []),
            }
        return {"notes": group_notes}

    def fetch_replies(self, note_id: str) -> list[dict]:
        """Retrieve all replies for a given note.

        Args:
            note_id: ID of the parent note whose replies to fetch.

        Returns:
            list[dict]: List of reply note dicts. Each dict now carries its
                own real row id under ``"id"`` -- ``lookup()`` keys its
                returned mapping by ``_id`` but that key was previously
                discarded once unwrapped into this flat list, leaving
                editors with no way to target the right row. Callers
                editing a reply need this real id to update the correct
                row via the existing ``PUT /notes/{user_id}?note_id=``
                path (no new endpoint or schema change -- just re-attaching
                the id ``lookup()`` already had).
        """
        blocked = self._blocked_set()
        replies = self.lookup("notes", {"is_reply": True, "parent_note_id": note_id})
        return [
            {**data, "id": str(rid)}
            for rid, data in replies.items()
            if str(data.get("user_id")) not in blocked
        ]

    def fetch_highlights(self) -> dict:
        """Retrieve highlight data for all members of the group.

        Returns:
            dict: Mapping of user_id -> {key -> color} for every group member.
        """
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return {}
        _, group_data = list(group.items())[0]
        member_ids = group_data.get("users", [])
        result: dict = {uid: {} for uid in member_ids}
        if member_ids:
            self.cur.execute(
                "SELECT user_id, key, color FROM highlights WHERE user_id = ANY(%s::uuid[])",
                (member_ids,),
            )
            for user_id, key, color in self.cur.fetchall():
                result.setdefault(str(user_id), {})[key] = color
        return result

    def can_delete(self) -> bool:
        """True iff self.user_id is authorized to delete self.group_id
        outright (the explicit, owner-gated "delete group" action -- NOT
        the ordinary leave path, which never calls this).

        Deny-by-default (Security Posture Q2/Q14): a group with a recorded
        creator_id may be deleted only by that creator -- everyone else,
        member or not, is denied. A group whose creator_id is NULL (it
        either predates this column, or its creator's account was later
        deleted -- see the ON DELETE SET NULL on groups.creator_id) falls
        back to the approved permissive rule: any *current* member may
        delete it. That fallback is intentionally re-checked against
        current membership every call rather than cached, and never
        widens to non-members. A group that can't be found at all is
        denied rather than defaulting open (fail closed).
        """
        if not self.group_id:
            return False
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return False
        _, data = list(group.items())[0]
        creator_id = data.get("creator_id")
        if creator_id is not None:
            return str(creator_id) == self.user_id
        return self.user_id in (data.get("users") or [])

    def delete_group(self) -> None:
        """Delete the group outright. Membership is derived from the
        groups.users column, so deleting the row removes it from every
        member's view automatically.

        This is the explicit, owner-gated destructive action -- callers
        must have already confirmed ``can_delete()`` before invoking this;
        it performs no authorization check of its own. Cascades in
        Postgres to linked notes/messages (ON DELETE SET NULL) and
        devotions (ON DELETE SET NULL on notes/messages' group_id FK;
        devotions.group_id is a plain unlinked TEXT column, out of scope
        for this task -- see intake spec).

        One transaction: the group row lock, the ``group_delete`` collectors
        (photo and announcement-banner S3 keys), the outbox enqueue, the row
        delete and the invite purge commit together or not at all. Nothing
        here talks to S3; the outbox job deletes the objects later.
        """
        if not self.group_id:
            return
        from backend.interactions.invites import purge_target_invites
        try:
            self.cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (self.group_id,))
            # delete_group is only ever called after the caller already loaded
            # this group (routes/community.py), so a missing row here is a
            # real write failure, not an expected no-op.
            if self.cur.fetchone() is None:
                raise SaveFailedError()
            keys = lifecycle.run("group_delete", self.cur, self.group_id)
            lifecycle.enqueue_s3_deletes(self.cur, keys)
            self.cur.execute("DELETE FROM groups WHERE _id = %s", (self.group_id,))
            if self.cur.rowcount != 1:
                raise SaveFailedError()
            # invites.target_id has no FK by design, so this cleanup lives in
            # code (task 20260929-group-invite-links). Same transaction now: a
            # failure rolls the whole delete back instead of leaving a group
            # gone with live invite links.
            purge_target_invites(self.cur, "group", self.group_id)
            self.conn.commit()
        except SaveFailedError:
            self.conn.rollback()
            raise
        except sql.Error as e:
            logger.error("DB_WRITE_FAILURE op=delete_group table=groups error=%s", _redact_db_error(e))
            self.conn.rollback()
            raise SaveFailedError()
        except BaseException:
            self.conn.rollback()
            raise

    @staticmethod
    def remove_member_in_tx(cur, group_id: str, user_id: str) -> str:
        """Remove ``user_id`` from one group inside the caller's transaction.

        This is exactly the ``leave_group`` transaction body (shared with the
        ``user_delete`` hook so account deletion and leaving cannot drift).
        It does NOT commit or roll back; the caller owns the transaction.

        Under the groups row lock (the lock invite redeem and the member cap
        take first): remove the id; if members remain, revoke the leaver's
        group invite links and run the ``member_leave`` hooks; if the list is
        now empty, run the ``group_delete`` collectors, delete the group and
        purge its invites. Any S3 keys reported are enqueued to the outbox in
        the same transaction.

        Returns:
            ``"missing"`` (no such group), ``"left"`` or ``"deleted"``.
        """
        from backend.interactions.invites import purge_target_invites, revoke_member_group_invites
        cur.execute(
            "SELECT COALESCE(users, '{}') FROM groups WHERE _id = %s FOR UPDATE",
            (group_id,),
        )
        row = cur.fetchone()
        if row is None:
            return "missing"
        remaining = [u for u in row[0] if u != user_id]
        if remaining:
            cur.execute("UPDATE groups SET users = %s WHERE _id = %s", (remaining, group_id))
            if cur.rowcount != 1:
                raise SaveFailedError()
            revoke_member_group_invites(cur, group_id, [user_id])
            lifecycle.enqueue_s3_deletes(cur, lifecycle.run("member_leave", cur, group_id, user_id))
            return "left"
        keys = lifecycle.run("group_delete", cur, group_id)
        lifecycle.enqueue_s3_deletes(cur, keys)
        cur.execute("DELETE FROM groups WHERE _id = %s", (group_id,))
        if cur.rowcount != 1:
            raise SaveFailedError()
        purge_target_invites(cur, "group", group_id)
        return "deleted"

    def leave_group(self) -> None:
        """Remove only self.user_id from the group's member list -- the
        ordinary "Leave Group" action, distinct from delete_group() above.
        This never calls can_delete() and is not gated by creator_id at
        all: any member may always remove themselves.

        If removing self.user_id leaves the group with no members left,
        the now-empty group row is deleted as a system-triggered cleanup
        (the approved auto-delete-on-empty behavior) -- this reuses the
        same underlying DELETE as delete_group() but is a distinct call
        path that does not go through, and cannot be used to bypass,
        can_delete()'s creator_id gate: it only ever fires once the
        member list is already empty, never for a non-empty group.
        """
        if not self.group_id:
            return
        # One transaction under the groups row lock: the membership change,
        # the revoke of the leaver's group invite links (creator included),
        # the lifecycle hooks and the outbox enqueue commit together or not at
        # all, so a failed revoke fails the leave (fail closed) and a
        # concurrent redeem can't race a link past the departure.
        try:
            outcome = self.remove_member_in_tx(self.cur, self.group_id, self.user_id)
            if outcome == "missing":
                self.conn.rollback()
                return
            self.conn.commit()
        except SaveFailedError:
            self.conn.rollback()
            raise
        except sql.Error as e:
            logger.error("DB_WRITE_FAILURE op=leave_group table=groups error=%s", _redact_db_error(e))
            self.conn.rollback()
            raise SaveFailedError()
        except BaseException:
            self.conn.rollback()
            raise

    def _clean_member_list(self, requested, current: set[str]) -> list[str]:
        """Validate a replacement member list (called under the groups row lock).

        - An id already in the stored list that no longer resolves to a user
          (deleted account or junk string) is dropped silently, so build-78
          clients that echo the raw array back keep working.
        - An id already in the list that still exists is kept as stored (a
          suspended existing member is not "new", it stays).
        - Any NEW id must be a UUID of an existing, non-suspended user, else
          ``InvalidMemberError`` (same error for malformed and unknown ids).
        Order is the client's order, de-duplicated.
        """
        raws = list(dict.fromkeys(requested))
        canon = {raw: _canonical_uuid(raw) for raw in raws}
        lookup = list(dict.fromkeys(c for c in canon.values() if c))
        status: dict[str, bool] = {}  # canonical id -> suspended?
        if lookup:
            self.cur.execute(
                "SELECT _id::text, suspended_at IS NOT NULL FROM users WHERE _id = ANY(%s::uuid[])",
                (lookup,),
            )
            status = {r[0]: r[1] for r in self.cur.fetchall()}
        cleaned: list[str] = []
        for raw in raws:
            c = canon[raw]
            if raw in current:
                if c is not None and c in status:
                    cleaned.append(raw)
                continue
            if c is None or c not in status or status[c]:
                self.conn.rollback()
                raise InvalidMemberError()
            cleaned.append(c)
        return list(dict.fromkeys(cleaned))

    def _guard_listed_group(self, current: list[str], cleaned: list[str]) -> None:
        """Owner-only member changes for a group with Explorer presence (J4c).

        Called under the groups row lock. For a group without a listing this is
        one indexed lookup and changes nothing, so build-78 clients that add
        members through this route keep working for every ordinary group. For a
        listed group, a non-creator may not ADD members and nobody may remove
        the creator (the listing's owner) from the member list.
        """
        from backend.interactions.listings import group_has_explorer_presence

        if not group_has_explorer_presence(self.cur, self.group_id):
            return
        self.cur.execute("SELECT creator_id::text FROM groups WHERE _id = %s", (self.group_id,))
        row = self.cur.fetchone()
        creator = row[0] if row else None
        added = set(cleaned) - set(current)
        caller_is_creator = creator is not None and creator == str(self.user_id).lower()
        creator_removed = (
            creator is not None
            and any(isinstance(m, str) and m.lower() == creator for m in current)
            and not any(isinstance(m, str) and m.lower() == creator for m in cleaned)
        )
        if (added and not caller_is_creator) or creator_removed:
            self.conn.rollback()
            raise ListedGroupOwnerOnlyError()

    def update_group(self, group: Group) -> None:
        """Replace a group's title and member list.

        Args:
            group: Replacement ``Group`` instance with updated title and users.
        """
        if not self.group_id:
            return
        existing = self.lookup("groups", {"_id": self.group_id})
        if not existing:
            return
        # groups.users is the single source of membership; GET /user derives each
        # member's group list from it, so updating this column is sufficient.
        # `existing` above already confirmed the row exists, so a False
        # return is a real write failure, not an expected no-op.
        # Member cap (groups.max_members): this endpoint replaces the whole
        # member list from client input, so it is a join path too. Lock the
        # row (the same lock invite redemption takes) and refuse any list that
        # adds a member beyond the cap. Pure removals/renames still pass.
        try:
            self.cur.execute(
                "SELECT COALESCE(users, '{}'), max_members FROM groups WHERE _id = %s FOR UPDATE",
                (self.group_id,),
            )
            locked = self.cur.fetchone()
            if locked is None:
                self.conn.rollback()
                return
            current, cap = locked
            cleaned = self._clean_member_list(group.users or [], set(current))
            self._guard_listed_group(current, cleaned)
            if cap is not None and (set(cleaned) - set(current)) and len(cleaned) > cap:
                self.conn.rollback()
                raise GroupFullError()
            # Same transaction/lock: write the new list and revoke the group
            # invite links of every dropped member (fail closed on error).
            from backend.interactions.invites import revoke_member_group_invites
            self.cur.execute(
                "UPDATE groups SET title = %s, users = %s WHERE _id = %s",
                (group.title, cleaned, self.group_id),
            )
            if self.cur.rowcount != 1:
                raise SaveFailedError()
            revoke_member_group_invites(
                self.cur, self.group_id, set(current) - set(cleaned))
            self.conn.commit()
        except (GroupFullError, InvalidMemberError, ListedGroupOwnerOnlyError):
            raise
        except SaveFailedError:
            self.conn.rollback()
            raise
        except sql.Error as e:
            logger.error("DB_WRITE_FAILURE op=update_group table=groups error=%s", _redact_db_error(e))
            self.conn.rollback()
            raise SaveFailedError()
        except BaseException:
            self.conn.rollback()
            raise

    # ── Group info panel (task 20260929-group-info-panel) ─────────────────────
    # None of these methods check membership themselves -- routes must call
    # ``is_member()`` first (deny-by-default), same as every other method here.

    def get_member_cap_info(self) -> tuple[int | None, bool, int]:
        """(max_members or None, caller is creator, member count). Reads the
        group row; call after ``is_member()``."""
        self.cur.execute(
            "SELECT max_members, creator_id, COALESCE(cardinality(users), 0) FROM groups WHERE _id = %s",
            (self.group_id,),
        )
        row = self.cur.fetchone()
        self.conn.rollback()  # read-only; release the snapshot
        if not row:
            return None, False, 0
        cap, creator, count = row
        return cap, creator is not None and str(creator) == self.user_id, count

    def set_max_members(self, cap: int | None, ceiling: int, floor: int) -> None:
        """Set (or clear, with None) the group's member cap. Owner only.

        Raises:
            GroupOwnerOnlyError: caller isn't groups.creator_id (or none set).
            ValueError: not an int (bool rejected), outside [floor, ceiling],
                or below the current member count.
            SaveFailedError: the group vanished or the write failed.
        """
        if cap is not None:
            if isinstance(cap, bool) or not isinstance(cap, int):
                raise ValueError("Max members must be a whole number")
            if cap < floor or cap > ceiling:
                raise ValueError(f"Max members must be between {floor} and {ceiling}")
        try:
            self.cur.execute(
                "SELECT creator_id, COALESCE(cardinality(users), 0) FROM groups WHERE _id = %s FOR UPDATE",
                (self.group_id,),
            )
            row = self.cur.fetchone()
            if row is None:
                raise SaveFailedError()
            creator, count = row
            if creator is None or str(creator) != self.user_id:
                raise GroupOwnerOnlyError()
            if cap is not None and cap < count:
                raise ValueError(f"This group already has {count} members; the limit can't be lower")
            self.cur.execute("UPDATE groups SET max_members = %s WHERE _id = %s", (cap, self.group_id))
            self.conn.commit()
        except BaseException:
            self.conn.rollback()
            raise

    def rename_group(self, title: str) -> str:
        """Set only the group's title (members untouched). Returns the
        normalized title actually stored.

        Raises:
            ValueError: blank or overlong title.
            SaveFailedError: the write failed or the group no longer exists.
        """
        cleaned = normalize_group_title(title)
        if not self.update("groups", {"title": cleaned}, {"_id": self.group_id}):
            raise SaveFailedError()
        return cleaned

    def get_photo_key(self) -> tuple[bool, str | None]:
        """(group exists, current photo_key or None)."""
        group = self.lookup("groups", {"_id": self.group_id})
        if not group:
            return False, None
        _, data = list(group.items())[0]
        return True, data.get("photo_key")

    def set_photo_key(self, key: str | None) -> None:
        """Persist (or clear, with None) the group's photo key.

        Raises:
            SaveFailedError: the write failed or the group no longer exists.
        """
        if not self.update("groups", {"photo_key": key}, {"_id": self.group_id}):
            raise SaveFailedError()

    def is_muted(self) -> bool:
        """True iff ``self.user_id`` has muted ``self.group_id``."""
        self.cur.execute(
            "SELECT 1 FROM group_mutes WHERE user_id = %s AND group_id = %s",
            (self.user_id, self.group_id),
        )
        return self.cur.fetchone() is not None

    def set_muted(self, muted: bool) -> None:
        """Mute or unmute the group for ``self.user_id``. Idempotent: muting
        an already-muted group, or unmuting an unmuted one, is a no-op.

        Raises:
            SaveFailedError: the write itself failed (a caught SQL error).
        """
        if muted:
            if not self.insertion("group_mutes", {"user_id": self.user_id, "group_id": self.group_id}):
                raise SaveFailedError()
            return
        # DBManager.delete reports "matched nothing" as False; for an
        # idempotent unmute that is a legitimate no-op, so verify by state.
        self.delete("group_mutes", {"user_id": self.user_id, "group_id": self.group_id})
        if self.is_muted():
            raise SaveFailedError()

    def fetch_gallery(
        self,
        kind: str | None = None,
        limit: int = GALLERY_PAGE_SIZE,
        cursor_timestamp: str | None = None,
        cursor_id: str | None = None,
    ) -> dict:
        """One page of the group's attachments, newest first, keyset-paginated
        on (timestamp, _id). Blocked users' attachments are excluded in SQL
        (Guideline 1.2, same relationship set as ``_blocked_set``). URLs are
        presigned fresh at read time; stored keys are never returned.

        Args:
            kind: Optional filter, one of ``GALLERY_KINDS``.
            limit: Page size.
            cursor_timestamp / cursor_id: Both from the previous page's
                ``next_cursor_*``; supply together or not at all.

        Returns:
            dict: ``{"items": [...], "next_cursor_timestamp", "next_cursor_id",
            "has_more"}``. Each item: ``id``, ``kind``, ``url`` (None if
            presigning failed), ``meta``, ``from_user`` (username),
            ``timestamp``, ``text``.

        Raises:
            ValueError: unknown ``kind``, or a half-supplied cursor.
        """
        if kind is not None and kind not in GALLERY_KINDS:
            raise ValueError(f"Unsupported kind: {kind!r}")
        if (cursor_timestamp is None) != (cursor_id is None):
            raise ValueError("cursor_timestamp and cursor_id must be supplied together")
        if cursor_timestamp is not None:
            try:
                datetime.fromisoformat(cursor_timestamp)
                uuid.UUID(cursor_id)
            except (ValueError, TypeError):
                raise ValueError("Invalid gallery cursor")

        where = "group_id = %s AND attachment_kind IS NOT NULL AND deleted_at IS NULL"
        params: list = [self.group_id]
        if kind is not None:
            where += " AND attachment_kind = %s"
            params.append(kind)
        blocked = list(self._blocked_set())
        if blocked:
            where += " AND (from_user IS NULL OR NOT (from_user = ANY(%s::uuid[])))"
            params.append(blocked)
        if cursor_timestamp is not None:
            where += " AND (timestamp, _id) < (%s::timestamptz, %s::uuid)"
            params += [cursor_timestamp, cursor_id]
        self.cur.execute(
            "SELECT _id, from_user, text, timestamp, attachment_kind, "
            "attachment_key, attachment_meta FROM messages "
            f"WHERE {where} ORDER BY timestamp DESC, _id DESC LIMIT %s",
            params + [limit + 1],
        )
        rows = self.cur.fetchall()
        has_more = len(rows) > limit
        rows = rows[:limit]

        from_ids = list({str(r[1]) for r in rows if r[1]})
        usernames: dict[str, str] = {}
        if from_ids:
            self.cur.execute(
                "SELECT _id, username FROM users WHERE _id = ANY(%s::uuid[])",
                (from_ids,),
            )
            usernames = {str(r[0]): r[1] for r in self.cur.fetchall()}

        items = []
        for r in rows:
            meta = r[6] or {}
            url = meta.get("url") if r[4] == "gif" else generate_download_url(r[5])
            items.append({
                "id": str(r[0]),
                "kind": r[4],
                "url": url,
                "meta": meta,
                "from_user": usernames.get(str(r[1]), "") if r[1] else "",
                "timestamp": r[3].isoformat() if r[3] else None,
                "text": content_store.open_(r[0], content_store.F_MESSAGE_TEXT, r[2]) or "",
            })
        last = rows[-1] if rows else None
        return {
            "items": items,
            "next_cursor_timestamp": last[3].isoformat() if last and has_more else None,
            "next_cursor_id": str(last[0]) if last and has_more else None,
            "has_more": has_more,
        }
