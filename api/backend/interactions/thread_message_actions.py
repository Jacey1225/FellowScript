"""Reactions, pins and replies on thread messages (flags ``message_reactions``,
``message_pins``, ``chat_replies``, plus ``threads``).

Thread messages live in ``thread_messages``, never in ``messages``, so the
main-chat reaction / pin managers cannot reach them. This module mirrors their
rules on thread-scoped tables (``thread_message_reactions``,
``thread_message_pins``, ``thread_messages.reply_to_id``; DDL in
``schema_ddl/threads.py``).

Authorization (deny by default, re-read on every call, nothing client-supplied):
the caller must be a current member of the path group, the thread must belong
to that group, the message must belong to that thread and not be soft-deleted,
and its author must be the caller or a visible author (``groups.author_set``:
current members minus block relationships in either direction). Every failure
returns ``None`` and the route answers the same uniform 404.

Scoping: reactions key on the thread message id; a pin belongs to ONE thread and
shows only inside it (a thread pin never appears in the group's pin list).
A reply stays inside its thread: the target must be a live message of the same
thread. Emoji allowlist and caps are the main chat's. Logs carry ids only.
No push and no system line are emitted for thread reactions or pins.
"""
from __future__ import annotations

import logging

import psycopg2.errors

from backend import content_store
from backend.interactions import flags, paging
from backend.interactions import message_replies
from backend.interactions.groups import author_set, live_member_ids
from backend.interactions.message_reactions import (
    CAP_MESSAGE, CAP_USER, MAX_DISTINCT_PER_MESSAGE, MAX_PER_USER_PER_MESSAGE, _canon, is_allowed_emoji,
)
from backend.interactions.message_reactions import FLAG as REACTIONS_FLAG
from backend.interactions.message_pins import FLAG as PINS_FLAG, PREVIEW_MAX, max_page_size
from backend.interactions.send_guard import is_current_member
from db import DBManager

logger = logging.getLogger(__name__)


def reaction_frame(thread_id: str, group_id: str, message_id: str, emoji: str, count: int, actor_id: str) -> dict:
    """Live frame. Has ``type`` and neither ``from_user`` nor ``text``, so older
    clients ignore it. Receivers keep their own ``viewer_reacted`` by comparing
    ``actor_id`` with their id."""
    return {
        "type": "thread_reaction_updated", "thread_id": thread_id, "group_id": group_id,
        "message_id": message_id, "emoji": emoji, "count": count, "actor_id": actor_id,
    }


def pin_frame(thread_id: str, group_id: str, message_id: str, pinned: bool, actor_id: str) -> dict:
    return {
        "type": "thread_pin_updated", "thread_id": thread_id, "group_id": group_id,
        "message_id": message_id, "pinned": pinned, "actor_id": actor_id,
    }


def _blocked_with(cur, user_id: str) -> set[str]:
    return message_replies.blocked_with(cur, user_id)


# ---- reply on send ------------------------------------------------------------

def resolve_thread_reply(cur, sender_id: str, thread_id: str, recipients: list[str], target) -> dict:
    """Validate a reply target for a new message in ``thread_id`` and return its
    display values (same shape as ``message_replies.resolve_reply``; only
    ``reply_to_id`` is stored). ``cur`` is the send guard's cursor adapter
    (``execute/fetchone/fetchall``); ``recipients`` are the AUTHORIZED live
    members. Raises ``ReplyInvalid`` for every refusal (no detail)."""
    tid = _canon(target)
    sender = _canon(sender_id)
    if tid is None or sender is None:
        raise message_replies.ReplyInvalid()
    cur.execute(
        "SELECT from_user::text, text, attachment_kind FROM thread_messages "
        "WHERE _id = %s::uuid AND thread_id = %s::uuid AND deleted_at IS NULL",
        (tid, thread_id),
    )
    row = cur.fetchone()
    if not row or not row[0]:
        raise message_replies.ReplyInvalid()
    author, stored_text, kind = row[0].lower(), row[1], row[2]
    members = {m.lower() for m in recipients}
    if sender not in members:
        raise message_replies.ReplyInvalid()
    if author != sender and (author not in members or sender in _blocked_with(cur, author)):
        raise message_replies.ReplyInvalid()
    cur.execute("SELECT username FROM users WHERE _id = %s::uuid", (author,))
    name_row = cur.fetchone()
    if not name_row or not name_row[0]:
        raise message_replies.ReplyInvalid()
    try:
        text = content_store.open_(tid, content_store.F_THREAD_MESSAGE_TEXT, stored_text)
    except content_store.ContentDecryptError:
        logger.warning("thread reply target undecryptable: message=%s", tid)
        raise message_replies.ReplyInvalid()
    return {
        "reply_to_id": tid,
        "reply_to_text": message_replies.make_snippet(text, kind),
        "reply_to_author": str(name_row[0])[: message_replies.MAX_AUTHOR_LENGTH],
        "reply_to_author_id": author,
    }


# ---- read-side decoration -----------------------------------------------------

def attach_thread_actions(db: DBManager, thread_id: str, messages: list[dict], viewer_id: str,
                          authors: list[str]) -> None:
    """Add ``reactions`` / ``pinned`` / reply keys to the thread message dicts
    (each has an ``id``), in place, in a fixed number of queries. Each part is a
    no-op while its flag is off for the viewer, so payloads omit those keys."""
    ids = [i for i in (_canon(m.get("id")) for m in messages if m.get("id")) if i]
    viewer = _canon(viewer_id)
    if not ids or viewer is None:
        return
    try:
        if flags.is_enabled(REACTIONS_FLAG, viewer):
            db.cur.execute(
                "SELECT r.message_id::text, r.emoji, COUNT(*), BOOL_OR(r.user_id = %s::uuid), MIN(r.created_at) "
                "FROM thread_message_reactions r JOIN thread_messages m ON m._id = r.message_id "
                "WHERE r.message_id = ANY(%s::uuid[]) AND m.deleted_at IS NULL "
                "GROUP BY r.message_id, r.emoji ORDER BY MIN(r.created_at), r.emoji",
                (viewer, ids),
            )
            found: dict[str, list[dict]] = {}
            for mid, emoji, count, mine, _first in db.cur.fetchall():
                found.setdefault(mid, []).append({"emoji": emoji, "count": int(count), "viewer_reacted": bool(mine)})
            for m in messages:
                if m.get("id"):
                    m["reactions"] = found.get(str(m["id"]).lower(), [])
        if flags.is_enabled(PINS_FLAG, viewer):
            db.cur.execute(
                "SELECT message_id::text FROM thread_message_pins WHERE message_id = ANY(%s::uuid[])", (ids,),
            )
            pinned = {r[0] for r in db.cur.fetchall()}
            for m in messages:
                if m.get("id"):
                    m["pinned"] = str(m["id"]).lower() in pinned
        if flags.is_enabled(message_replies.FLAG, viewer):
            db.cur.execute(
                "SELECT _id::text, reply_to_id::text FROM thread_messages "
                "WHERE _id = ANY(%s::uuid[]) AND reply_to_id IS NOT NULL",
                (ids,),
            )
            replies = {r[0]: r[1] for r in db.cur.fetchall()}
            visible: dict[str, dict] = {}
            if replies:
                db.cur.execute(
                    "SELECT t._id::text, t.from_user::text, t.text, t.attachment_kind, u.username "
                    "FROM thread_messages t LEFT JOIN users u ON u._id = t.from_user "
                    "WHERE t._id = ANY(%s::uuid[]) AND t.thread_id = %s::uuid AND t.deleted_at IS NULL",
                    (sorted(set(replies.values())), thread_id),
                )
                allowed = set(authors)
                for tid, author, text, kind, username in db.cur.fetchall():
                    author = (author or "").lower()
                    if not author or author not in allowed:
                        continue
                    try:
                        plain = content_store.open_(tid, content_store.F_THREAD_MESSAGE_TEXT, text)
                    except content_store.ContentDecryptError:
                        continue
                    visible[tid] = {
                        "reply_to_id": tid, "reply_to_text": message_replies.make_snippet(plain, kind),
                        "reply_to_author": (username or "")[: message_replies.MAX_AUTHOR_LENGTH],
                        "reply_to_author_id": author,
                    }
            for m in messages:
                target = replies.get(str(m.get("id", "")).lower())
                if target is None:
                    continue
                info = visible.get(target)
                m.update(message_replies.public_fields(info) if info else message_replies.deleted_fields(target))
    finally:
        db.conn.rollback()  # read-only; release the snapshot


# ---- manager --------------------------------------------------------------------

class ThreadMessageActions(DBManager):
    """Add / remove a reaction, pin / unpin, list pins; ``None`` for every denial."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = _canon(user_id) or ""

    def is_member_quiet(self, group_id: str) -> bool:
        """Current-member check that leaves no open transaction (route pre-check
        before ``require_current_terms``, as ``ThreadsManager.is_member``)."""
        gid = _canon(group_id)
        if not gid or not self.user_id:
            return False
        try:
            return is_current_member(self.cur, gid, self.user_id)
        finally:
            self.conn.rollback()

    def _resolve(self, group_id: str, thread_id: str, message_id: str | None) -> dict | None:
        """Context for a thread (and message) the caller may act on, else None.
        Read-only; the caller owns the transaction."""
        gid, tid = _canon(group_id), _canon(thread_id)
        mid = _canon(message_id) if message_id is not None else None
        if not (gid and tid and self.user_id) or (message_id is not None and mid is None):
            return None
        if not is_current_member(self.cur, gid, self.user_id):
            return None
        self.cur.execute("SELECT 1 FROM threads WHERE _id = %s::uuid AND group_id = %s::uuid", (tid, gid))
        if self.cur.fetchone() is None:
            return None
        authors = author_set(self.cur, gid, self.user_id)
        recipients: list[str] = []
        if mid is not None:
            self.cur.execute(
                "SELECT from_user::text FROM thread_messages "
                "WHERE _id = %s::uuid AND thread_id = %s::uuid AND deleted_at IS NULL",
                (mid, tid),
            )
            row = self.cur.fetchone()
            if not row or not row[0]:
                return None
            author = row[0].lower()
            if author not in authors:
                return None
            blocked_me = _blocked_with(self.cur, self.user_id)
            recipients = [m for m in live_member_ids(self.cur, gid) if m != self.user_id and m not in blocked_me]
            if author != self.user_id:
                blocked_author = _blocked_with(self.cur, author)
                recipients = [m for m in recipients if m not in blocked_author]
        return {"group_id": gid, "thread_id": tid, "message_id": mid, "authors": authors, "recipients": recipients}

    def _count(self, mid: str, emoji: str) -> dict:
        self.cur.execute(
            "SELECT COUNT(*), BOOL_OR(user_id = %s::uuid) FROM thread_message_reactions "
            "WHERE message_id = %s::uuid AND emoji = %s",
            (self.user_id, mid, emoji),
        )
        count, mine = self.cur.fetchone()
        return {"emoji": emoji, "count": int(count), "viewer_reacted": bool(mine)}

    def _result(self, ctx: dict, **extra) -> dict:
        return {"message_id": ctx["message_id"], "thread_id": ctx["thread_id"], "group_id": ctx["group_id"],
                "recipients": ctx["recipients"], **extra}

    # -- reactions --

    def add_reaction(self, group_id: str, thread_id: str, message_id: str, emoji: str) -> dict | None:
        """``{"changed", "reaction", ids, "recipients"}``, ``{"cap": CAP_*}`` or None."""
        if not is_allowed_emoji(emoji):
            return None
        try:
            ctx = self._resolve(group_id, thread_id, message_id)
            if ctx is None:
                self.conn.rollback()
                return None
            mid, uid = ctx["message_id"], self.user_id
            self.cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (mid,))
            self.cur.execute(
                "SELECT 1 FROM thread_message_reactions WHERE message_id = %s::uuid AND user_id = %s::uuid "
                "AND emoji = %s", (mid, uid, emoji),
            )
            changed = False
            if not self.cur.fetchone():
                self.cur.execute(
                    "SELECT COUNT(DISTINCT emoji), COUNT(DISTINCT emoji) FILTER (WHERE user_id = %s::uuid), "
                    "BOOL_OR(emoji = %s) FROM thread_message_reactions WHERE message_id = %s::uuid",
                    (uid, emoji, mid),
                )
                distinct, mine, present = self.cur.fetchone()
                if int(mine or 0) >= MAX_PER_USER_PER_MESSAGE:
                    self.conn.rollback()
                    return {"cap": CAP_USER}
                if not present and int(distinct or 0) >= MAX_DISTINCT_PER_MESSAGE:
                    self.conn.rollback()
                    return {"cap": CAP_MESSAGE}
                self.cur.execute(
                    "INSERT INTO thread_message_reactions (message_id, user_id, emoji) "
                    "VALUES (%s::uuid, %s::uuid, %s) ON CONFLICT DO NOTHING", (mid, uid, emoji),
                )
                changed = self.cur.rowcount == 1
            reaction = self._count(mid, emoji)
            self.conn.commit()
        except psycopg2.errors.ForeignKeyViolation:
            self.conn.rollback()  # message or user removed concurrently
            return None
        except Exception:
            self.conn.rollback()
            raise
        return self._result(ctx, changed=changed, reaction=reaction)

    def remove_reaction(self, group_id: str, thread_id: str, message_id: str, emoji: str) -> dict | None:
        if not is_allowed_emoji(emoji):
            return None
        try:
            ctx = self._resolve(group_id, thread_id, message_id)
            if ctx is None:
                self.conn.rollback()
                return None
            self.cur.execute(
                "DELETE FROM thread_message_reactions WHERE message_id = %s::uuid AND user_id = %s::uuid "
                "AND emoji = %s", (ctx["message_id"], self.user_id, emoji),
            )
            changed = self.cur.rowcount == 1
            reaction = self._count(ctx["message_id"], emoji)
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        return self._result(ctx, changed=changed, reaction=reaction)

    # -- pins --

    def pin(self, group_id: str, thread_id: str, message_id: str) -> dict | None:
        """Idempotently pin inside the thread. ``{"changed", ids, "recipients"}`` or None."""
        try:
            ctx = self._resolve(group_id, thread_id, message_id)
            if ctx is None:
                self.conn.rollback()
                return None
            self.cur.execute(
                "INSERT INTO thread_message_pins (message_id, thread_id, pinned_by) "
                "VALUES (%s::uuid, %s::uuid, %s::uuid) ON CONFLICT DO NOTHING",
                (ctx["message_id"], ctx["thread_id"], self.user_id),
            )
            changed = self.cur.rowcount == 1
            self.conn.commit()
        except psycopg2.errors.ForeignKeyViolation:
            self.conn.rollback()
            return None
        except Exception:
            self.conn.rollback()
            raise
        return self._result(ctx, changed=changed)

    def unpin(self, group_id: str, thread_id: str, message_id: str) -> dict | None:
        try:
            ctx = self._resolve(group_id, thread_id, message_id)
            if ctx is None:
                self.conn.rollback()
                return None
            self.cur.execute(
                "DELETE FROM thread_message_pins WHERE message_id = %s::uuid AND thread_id = %s::uuid",
                (ctx["message_id"], ctx["thread_id"]),
            )
            changed = self.cur.rowcount == 1
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        return self._result(ctx, changed=changed)

    def list_pins(self, group_id: str, thread_id: str, limit: int = 50, offset: int = 0) -> dict | None:
        """Pinned messages of one thread, newest pin first.
        ``{"pins": [...], "has_more", "count"}`` or None. Same item shape as
        the group pin list."""
        limit = max(1, min(int(limit), max_page_size()))
        offset = max(0, int(offset))
        try:
            ctx = self._resolve(group_id, thread_id, None)
            if ctx is None:
                return None
            clauses = ("p.thread_id = %s::uuid AND m.deleted_at IS NULL AND m.from_user = ANY(%s::uuid[])")
            params: list = [ctx["thread_id"], ctx["authors"]]
            self.cur.execute(
                "SELECT COUNT(*) FROM thread_message_pins p JOIN thread_messages m ON m._id = p.message_id WHERE "
                + clauses, params,
            )
            total = int(self.cur.fetchone()[0])
            self.cur.execute(
                "SELECT p.message_id::text, p.pinned_by::text, p.pinned_at, pu.username, "
                "m.from_user::text, au.username, m.text, m.created_at, m.attachment_kind "
                "FROM thread_message_pins p JOIN thread_messages m ON m._id = p.message_id "
                "LEFT JOIN users pu ON pu._id = p.pinned_by LEFT JOIN users au ON au._id = m.from_user "
                "WHERE " + clauses + " ORDER BY p.pinned_at DESC, p.message_id LIMIT %s OFFSET %s",
                params + [limit + 1, offset],
            )
            rows = self.cur.fetchall()
        finally:
            self.conn.rollback()
        has_more = len(rows) > limit
        pins = []
        for mid, by_id, pinned_at, by_name, author_id, author_name, text, ts, kind in rows[:limit]:
            clear = content_store.open_or_none(
                mid, content_store.F_THREAD_MESSAGE_TEXT, text, label="thread_pin") or ""
            shown = clear if len(clear) <= PREVIEW_MAX else clear[: PREVIEW_MAX - 1] + "…"
            pins.append({
                "message_id": mid,
                "pinned_by_id": (by_id or "").lower(),
                "pinned_by": by_name or "",
                "pinned_at": pinned_at.isoformat() if pinned_at else None,
                "message": {
                    "id": mid, "thread_id": ctx["thread_id"],
                    "from_user_id": (author_id or "").lower(), "from_user": author_name or "",
                    "text": shown, "timestamp": paging.format_timestamp(ts) if ts else None,
                    "attachment_kind": kind,
                },
            })
        return {"pins": pins, "has_more": has_more, "count": total}
