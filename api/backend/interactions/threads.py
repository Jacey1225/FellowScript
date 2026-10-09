"""Group message threads: create, list, read, rename (flag ``threads``).

A thread is a named sub-conversation anchored on ONE root message of a group
chat (one thread per root, groups only). Its messages live in their own
``thread_messages`` table, never in ``messages``, so no legacy reader can leak
thread chatter into the main chat. The live send path is
``backend/interactions/thread_send.py``; this module is everything reached over
HTTP (``routes/threads.py``).

Authorization (deny by default, re-read on every call, never taken from the
client):
  * the caller must be a current, non-suspended member of the group
    (``send_guard.is_current_member``, which reads ``groups.live_member_ids``);
  * a thread id is always resolved to its OWN ``group_id`` and compared with the
    group in the path, so a thread id from another group is simply "not found";
  * message and creator visibility comes from ``groups.author_set`` (the caller
    plus current members, minus both-direction blocks), the same predicate the
    main chat history uses.
Every denial returns ``None`` and the route answers one uniform 404. Nothing
here logs message or title text.
"""
from __future__ import annotations

import logging
import uuid

from db import DBManager
from backend import content_store
from backend.interactions import paging
from backend.interactions.attachments import generate_download_url
from backend.interactions.groups import author_set
from backend.interactions.send_guard import is_current_member
from backend.interactions.threads_config import get_threads_config

logger = logging.getLogger(__name__)

# Threads list page size (design: 20). Messages inside a thread use the shared
# ``pagination`` section of chat.json, like the main chat.
LIST_PAGE_SIZE = 20
LIST_MAX_PAGE_SIZE = 50

# Stand-in root preview / title for an attachment-only root message.
ATTACHMENT_LABELS = {"image": "Photo", "video": "Video", "gif": "GIF", "file": "File"}
FALLBACK_TITLE = "Thread"


class ThreadLimitError(Exception):
    """The group already holds ``max_threads_per_group`` threads."""


class InvalidTitleError(ValueError):
    """The title is blank (rename), too long, or has an unsupported character."""


def canon(value) -> str | None:
    """Lowercase canonical UUID string, or None."""
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def clean_title(raw, max_length: int) -> str:
    """Whitespace-normalised title; raises ``InvalidTitleError`` when empty,
    over ``max_length`` or holding a NUL."""
    if not isinstance(raw, str) or "\x00" in raw:
        raise InvalidTitleError("invalid title")
    title = " ".join(raw.split())
    if not title or len(title) > max_length:
        raise InvalidTitleError("invalid title")
    return title


def _label_or_text(text: str | None, kind: str | None, length: int) -> str:
    flat = " ".join((text or "").split())
    if flat:
        return flat[:length]
    return ATTACHMENT_LABELS.get(kind or "", "")


def _blocked_ids(cur, user_id: str) -> list[str]:
    cur.execute(
        "SELECT blocked_id::text FROM blocked_users WHERE blocker_id = %s::uuid "
        "UNION SELECT blocker_id::text FROM blocked_users WHERE blocked_id = %s::uuid",
        (user_id, user_id),
    )
    return [str(r[0]).lower() for r in cur.fetchall()]


# One thread as the list / create response shows it. ``root_deleted`` is true
# when the root is soft-deleted, purged or hard-deleted (FK SET NULL).
_SUMMARY_SQL = (
    "SELECT t._id::text, t.group_id::text, t.title, t.root_preview, t.root_message_id::text, "
    "(m._id IS NULL OR m.deleted_at IS NOT NULL) AS root_deleted, "
    "(SELECT COUNT(*) FROM thread_messages tm WHERE tm.thread_id = t._id "
    " AND tm.deleted_at IS NULL AND tm.from_user = ANY(%s::uuid[])) AS reply_count, "
    "t.last_activity_at, COALESCE(cu.username, ''), "
    "(t.root_author_id IS NOT NULL AND t.root_author_id = ANY(%s::uuid[])) AS root_author_visible "
    "FROM threads t "
    "LEFT JOIN messages m ON m._id = t.root_message_id "
    "LEFT JOIN users cu ON cu._id = t.created_by "
)


def _summary_row(row) -> dict:
    root_deleted = bool(row[5])
    # A root authored by someone the caller blocked (either direction), who left
    # the group or whose account is gone must not keep showing its text in the
    # list, exactly as the main chat hides that author's messages (block rule).
    if not row[9]:
        root_deleted = True
    return {
        "id": row[0],
        "group_id": row[1],
        "title": content_store.open_(row[0], content_store.F_THREAD_TITLE, row[2]),
        # A deleted root's text must not keep showing in the list.
        "root_preview": None if root_deleted else content_store.open_(row[0], content_store.F_THREAD_ROOT_PREVIEW, row[3]),
        "root_message_id": row[4],
        "root_deleted": root_deleted,
        "reply_count": int(row[6]),
        "last_activity_at": paging.format_timestamp(row[7]),
        "created_by": row[8],
    }


def _list_item(summary: dict) -> dict:
    return {k: summary[k] for k in (
        "id", "title", "root_preview", "root_deleted", "reply_count", "last_activity_at", "created_by",
    )}


class ThreadsManager(DBManager):
    """Per-request manager; every public method returns ``None`` for a denial."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = canon(user_id) or ""

    # ---- helpers -------------------------------------------------------

    def is_member(self, group_id: str) -> bool:
        gid = canon(group_id)
        if not gid or not self.user_id:
            return False
        try:
            return is_current_member(self.cur, gid, self.user_id)
        finally:
            self.conn.rollback()

    def _fail(self) -> None:
        self.conn.rollback()

    # ---- create --------------------------------------------------------

    def create_thread(self, group_id: str, message_id: str, title) -> "tuple[dict, bool] | None":
        """Start a thread on ``message_id`` or return the existing one.

        Returns ``(summary, created)`` or ``None`` when the caller is not a
        current member, the message is not a live message of this group, or its
        author is not visible to the caller (blocked, not a member). Raises
        ``InvalidTitleError`` for a bad title and ``ThreadLimitError`` at the
        per-group cap. Concurrent creates for one root yield one thread (the
        partial unique index plus a per-group advisory lock).
        """
        cfg = get_threads_config()
        gid, mid = canon(group_id), canon(message_id)
        if not (gid and mid and self.user_id):
            return None
        chosen = None
        if title is not None and str(title).strip() != "":
            chosen = clean_title(title, cfg.title_max_length)
        try:
            self.cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("threads:" + gid,))
            if not is_current_member(self.cur, gid, self.user_id):
                self._fail()
                return None
            self.cur.execute(
                "SELECT from_user::text, text, attachment_kind FROM messages "
                "WHERE _id = %s::uuid AND group_id = %s::uuid AND deleted_at IS NULL",
                (mid, gid),
            )
            msg = self.cur.fetchone()
            if not msg:
                self._fail()
                return None
            authors = author_set(self.cur, gid, self.user_id)
            if not msg[0] or msg[0].lower() not in authors:
                self._fail()
                return None
            self.cur.execute("SELECT _id::text FROM threads WHERE root_message_id = %s::uuid", (mid,))
            existing = self.cur.fetchone()
            if existing:
                summary = self._summary(existing[0], authors)
                self.conn.rollback()
                return summary, False

            self.cur.execute("SELECT COUNT(*) FROM threads WHERE group_id = %s::uuid", (gid,))
            if self.cur.fetchone()[0] >= cfg.max_threads_per_group:
                self._fail()
                raise ThreadLimitError()

            root_text = content_store.open_(mid, content_store.F_MESSAGE_TEXT, msg[1])
            auto_title = _label_or_text(root_text, msg[2], cfg.auto_title_length) or FALLBACK_TITLE
            preview = _label_or_text(root_text, msg[2], cfg.root_preview_length) or None
            # The thread id is chosen here: it is part of the encryption AAD.
            new_tid = str(uuid.uuid4())
            self.cur.execute(
                "INSERT INTO threads (_id, group_id, root_message_id, root_preview, root_author_id, title, created_by) "
                "VALUES (%s::uuid, %s::uuid, %s::uuid, %s, %s::uuid, %s, %s::uuid) "
                "ON CONFLICT (root_message_id) WHERE root_message_id IS NOT NULL DO NOTHING "
                "RETURNING _id::text",
                (new_tid, gid, mid,
                 content_store.seal(new_tid, content_store.F_THREAD_ROOT_PREVIEW, preview), msg[0],
                 content_store.seal(new_tid, content_store.F_THREAD_TITLE, chosen or auto_title), self.user_id),
            )
            row = self.cur.fetchone()
            created = row is not None
            if row is None:
                self.cur.execute("SELECT _id::text FROM threads WHERE root_message_id = %s::uuid", (mid,))
                row = self.cur.fetchone()
                if row is None:
                    self._fail()
                    return None
            thread_id = row[0]
            if created:
                followers = list(dict.fromkeys([self.user_id, msg[0].lower()]))
                self.cur.execute(
                    "INSERT INTO thread_followers (thread_id, user_id) "
                    "SELECT %s::uuid, f FROM unnest(%s::uuid[]) AS f ON CONFLICT DO NOTHING",
                    (thread_id, followers),
                )
            summary = self._summary(thread_id, authors)
            self.conn.commit()
            return summary, created
        except (ThreadLimitError, InvalidTitleError):
            raise
        except Exception:
            self.conn.rollback()
            raise

    def _summary(self, thread_id: str, authors: list[str]) -> dict:
        self.cur.execute(_SUMMARY_SQL + "WHERE t._id = %s::uuid", (authors, authors, thread_id))
        return _summary_row(self.cur.fetchone())

    # ---- list ----------------------------------------------------------

    def list_threads(self, group_id: str, limit: int, cursor: "paging.Cursor | None") -> "dict | None":
        """One keyset page of the group's threads, most recently active first.

        Returns ``{"threads": [...], "has_more", "next_cursor"}`` or ``None`` for
        a non-member. Threads created by someone in a block relationship with
        the caller are excluded in SQL; threads whose creator left or deleted
        their account stay (a thread dies only with its group).
        """
        gid = canon(group_id)
        if not (gid and self.user_id):
            return None
        try:
            if not is_current_member(self.cur, gid, self.user_id):
                return None
            authors = author_set(self.cur, gid, self.user_id)
            blocked = _blocked_ids(self.cur, self.user_id)
            sql = _SUMMARY_SQL + (
                "WHERE t.group_id = %s::uuid AND (t.created_by IS NULL OR t.created_by <> ALL(%s::uuid[])) "
            )
            params: list = [authors, authors, gid, blocked]
            if cursor is not None:
                sql += f"AND (t.last_activity_at, t._id) < ({paging.TS_SQL}, {cursor.id_sql}) "
                params.extend([cursor.timestamp, cursor.id])
            sql += "ORDER BY t.last_activity_at DESC, t._id DESC LIMIT %s"
            params.append(limit + 1)
            self.cur.execute(sql, params)
            rows = self.cur.fetchall()
        finally:
            self.conn.rollback()
        has_more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = None
        if has_more and rows:
            last = rows[-1]
            next_cursor = paging.encode_cursor(last[7], None, last[0])
        return {
            "threads": [_list_item(_summary_row(r)) for r in rows],
            "has_more": has_more,
            "next_cursor": next_cursor,
        }

    # ---- read ----------------------------------------------------------

    def read_messages(
        self, group_id: str, thread_id: str, limit: int, cursor: "paging.Cursor | None"
    ) -> "dict | None":
        """One keyset page of a thread's messages, newest page first and
        oldest-first inside the page (same contract as the main chat page, plus
        ``thread_id`` on each row). ``None`` for a non-member or a thread that
        does not belong to ``group_id``."""
        gid, tid = canon(group_id), canon(thread_id)
        if not (gid and tid and self.user_id):
            return None
        try:
            if not is_current_member(self.cur, gid, self.user_id):
                return None
            self.cur.execute(
                "SELECT 1 FROM threads WHERE _id = %s::uuid AND group_id = %s::uuid", (tid, gid)
            )
            if self.cur.fetchone() is None:
                return None
            authors = author_set(self.cur, gid, self.user_id)
            sql = (
                "SELECT _id, from_user, text, created_at, attachment_kind, attachment_key, "
                "attachment_meta, seq FROM thread_messages "
                "WHERE thread_id = %s::uuid AND deleted_at IS NULL AND from_user = ANY(%s::uuid[]) "
            )
            params: list = [tid, authors]
            if cursor is not None:
                sql += f"AND (created_at, seq, _id) < ({paging.TS_SQL}, {paging.SEQ_SQL}, {cursor.id_sql}) "
                params.extend(cursor.params())
            sql += "ORDER BY created_at DESC, seq DESC, _id DESC LIMIT %s"
            params.append(limit + 1)
            self.cur.execute(sql, params)
            rows = self.cur.fetchall()
            usernames: dict[str, str] = {}
            from_uids = {str(r[1]) for r in rows[:limit] if r[1]}
            if from_uids:
                self.cur.execute(
                    "SELECT _id, username FROM users WHERE _id = ANY(%s::uuid[])", (list(from_uids),)
                )
                usernames = {str(r[0]): r[1] for r in self.cur.fetchall()}
        finally:
            self.conn.rollback()
        has_more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = None
        if has_more and rows:
            oldest = rows[-1]
            next_cursor = paging.encode_cursor(oldest[3], oldest[7], oldest[0])
        me = self.user_id
        messages = []
        for _id, from_user, text, ts, kind, key, meta, _seq in reversed(rows):
            from_uid = str(from_user) if from_user else ""
            messages.append({
                "id": str(_id),
                "thread_id": tid,
                "from_user": usernames.get(from_uid, ""),
                "mine": from_uid.lower() == me,
                "text": content_store.open_(_id, content_store.F_THREAD_MESSAGE_TEXT, text),
                "timestamp": paging.format_timestamp(ts),
                "attachment_kind": kind,
                "attachment_meta": meta,
                "attachment_url": generate_download_url(key) if key else None,
            })
        return {"messages": messages, "has_more": has_more, "next_cursor": next_cursor}

    # ---- rename --------------------------------------------------------

    def rename_thread(self, group_id: str, thread_id: str, title) -> "dict | None":
        """Rename; only the thread's creator, still a current non-suspended
        member of its group. ``None`` for every other case (one atomic UPDATE).
        Raises ``InvalidTitleError`` for a blank, overlong or NUL title."""
        gid, tid = canon(group_id), canon(thread_id)
        if not (gid and tid and self.user_id):
            return None
        new_title = clean_title(title, get_threads_config().title_max_length)
        try:
            if not is_current_member(self.cur, gid, self.user_id):
                self._fail()
                return None
            self.cur.execute(
                "UPDATE threads SET title = %s WHERE _id = %s::uuid AND group_id = %s::uuid "
                "AND created_by = %s::uuid RETURNING _id::text, title",
                (content_store.seal(tid, content_store.F_THREAD_TITLE, new_title), tid, gid, self.user_id),
            )
            row = self.cur.fetchone()
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        return {"id": row[0], "title": content_store.open_(row[0], content_store.F_THREAD_TITLE, row[1])} if row else None


def audit(action: str, user_id: str, group_id: str, thread_id: str) -> None:
    """Ids only, never text."""
    logger.info("THREAD_%s user=%s group=%s thread=%s", action, user_id, group_id, thread_id)
