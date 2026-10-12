"""Pinned messages in DMs and groups (flag ``message_pins``, ships OFF).

Scope: group messages and DMs (both live in ``messages``). One row per pinned
message in ``message_pins``; a pin is shared by every member of the chat.

Rules:
- Anyone who can SEE a message may pin or unpin it (user-approved, no host-only
  restriction). Visibility is exactly the reactions rule (``_resolve``): not
  soft-deleted, live group member / DM participant, no blocked pair. Every
  failure returns ``None`` and the route answers one uniform 404.
- No cap on pins per chat (REVISION 1). Pin is idempotent (PK on message_id).
- A server-generated system line (``messages.system_kind = 'pin'``, text a
  constant, author = the pinner) and the pin push are emitted only when an
  atomic claim on ``message_pin_push_claims`` succeeds, so pin/unpin churn
  inside ``notify_window_seconds`` is silent. The system line is persisted
  directly (never through the websocket send path), so it triggers no chat
  push; the dedicated pin push lives in ``pin_push``.
- Soft-deleted messages leave every reader (rows survive for restore). System
  lines can not be pinned.
- Logs carry ids only, never text.
"""
from __future__ import annotations

import logging
import uuid
from functools import lru_cache

import psycopg2.errors

from backend import content_store
from backend.config_loader import load_section
from backend.interactions import flags, paging
from backend.interactions.chat_config import CONFIG_PATH
from backend.interactions.message_reactions import MessageReactionsManager, _canon

logger = logging.getLogger(__name__)

FLAG = "message_pins"
CONFIG_SECTION = "message_pins"
SYSTEM_KIND = "pin"
SYSTEM_TEXT = "pinned a message"
PREVIEW_MAX = 280


@lru_cache(maxsize=1)
def _config() -> dict:
    return load_section(
        CONFIG_PATH, CONFIG_SECTION,
        required_keys=("rate", "list_rate", "notify_window_seconds", "max_page_size"),
        types={"rate": str, "list_rate": str, "notify_window_seconds": int, "max_page_size": int},
        rate_keys=("rate", "list_rate"),
    )


def pin_rate() -> str:
    return _config()["rate"]


def list_rate() -> str:
    return _config()["list_rate"]


def notify_window_seconds() -> int:
    return max(1, _config()["notify_window_seconds"])


def max_page_size() -> int:
    return max(1, _config()["max_page_size"])


def pin_frame(message_id: str, chat_key: str, pinned: bool, actor_id: str) -> dict:
    """Live frame. Carries ``type`` and neither ``from_user`` nor ``text``, so
    older clients ignore it."""
    return {"type": "pin_updated", "message_id": message_id, "group_id": chat_key,
            "pinned": pinned, "actor_id": actor_id}


def attach_pins(db, messages: list[dict], viewer_id: str) -> None:
    """Add ``pinned`` (bool) to every message dict with an ``id`` and
    ``system_kind`` to system lines, in place, with one batch query. No-op
    while the flag is off for the viewer, so payloads omit both keys."""
    if not messages or not flags.is_enabled(FLAG, viewer_id):
        return
    ids = [i for i in (_canon(m.get("id")) for m in messages if m.get("id")) if i]
    if not ids:
        return
    try:
        db.cur.execute(
            "SELECT m._id::text, m.system_kind, (p.message_id IS NOT NULL) FROM messages m "
            "LEFT JOIN message_pins p ON p.message_id = m._id WHERE m._id = ANY(%s::uuid[])",
            (ids,),
        )
        found = {r[0]: (r[1], bool(r[2])) for r in db.cur.fetchall()}
    finally:
        db.conn.rollback()  # read-only; release the snapshot
    for m in messages:
        if not m.get("id"):
            continue
        kind, pinned = found.get(str(m["id"]).lower(), (None, False))
        m["pinned"] = pinned
        if kind:
            m["system_kind"] = kind


class MessagePinsManager(MessageReactionsManager):
    """Pin / unpin / list; returns None for every denial."""

    def _chat_key(self, uid: str, friend_id: str | None, group_id: str | None) -> tuple[str, list[str]] | None:
        """(chat_key, allowed_author_ids or [] for DM) for a chat the caller may read, else None."""
        from backend.interactions.groups import live_member_ids  # lazy: groups imports this module
        blocked_me = self._blocked_with(uid)
        if group_id is not None:
            gid = _canon(group_id)
            if gid is None:
                return None
            members = live_member_ids(self.cur, gid)
            if uid not in members:
                return None
            allowed = [m for m in members if m == uid or m not in blocked_me]
            return gid, allowed
        fid = _canon(friend_id)
        if fid is None or fid == uid or fid in blocked_me:
            return None
        self.cur.execute("SELECT 1 FROM users WHERE _id = %s::uuid", (fid,))
        if not self.cur.fetchone():
            return None
        return "|".join(sorted([uid, fid])), []

    def pin(self, message_id: str) -> dict | None:
        """Idempotently pin. ``{"changed", "message_id", "group_id", "recipients",
        "system_line", "notify"}`` or None. ``system_line`` is ``{"id",
        "timestamp", "text"}`` only when a line was written; ``notify`` is True
        only when the throttle claim succeeded."""
        uid, mid = _canon(self.user_id), _canon(message_id)
        if not (uid and mid):
            return None
        try:
            ctx = self._resolve(uid, mid)
            if ctx is None:
                self.conn.rollback()
                return None
            self.cur.execute("SELECT 1 FROM messages WHERE _id = %s::uuid AND system_kind IS NULL", (mid,))
            if not self.cur.fetchone():
                self.conn.rollback()
                return None
            chat_key = ctx["group_id"]
            self.cur.execute(
                "INSERT INTO message_pins (message_id, chat_key, pinned_by) VALUES (%s::uuid, %s, %s::uuid) "
                "ON CONFLICT DO NOTHING",
                (mid, chat_key, uid),
            )
            changed = self.cur.rowcount == 1
            line = None
            if changed:
                self.cur.execute(
                    "INSERT INTO message_pin_push_claims (chat_key, pinner_id, last_at) "
                    "VALUES (%s, %s::uuid, NOW()) ON CONFLICT (chat_key, pinner_id) DO UPDATE SET last_at = NOW() "
                    "WHERE message_pin_push_claims.last_at < NOW() - make_interval(secs => %s) RETURNING 1",
                    (chat_key, uid, notify_window_seconds()),
                )
                if self.cur.fetchone():
                    line = self._write_system_line(uid, chat_key, ctx["recipients"])
            self.conn.commit()
        except psycopg2.errors.ForeignKeyViolation:
            self.conn.rollback()  # message or user removed concurrently
            return None
        except Exception:
            self.conn.rollback()
            raise
        return {"changed": changed, "message_id": mid, "group_id": chat_key,
                "recipients": ctx["recipients"], "system_line": line, "notify": line is not None}

    def _write_system_line(self, uid: str, chat_key: str, recipients: list[str]) -> dict:
        """Persist the constant system line in the caller's transaction."""
        new_id = str(uuid.uuid4())
        is_group = "|" not in chat_key
        self.cur.execute(
            "INSERT INTO messages (_id, from_user, group_id, text, system_kind) "
            "VALUES (%s::uuid, %s::uuid, %s, %s, %s) RETURNING timestamp",
            (new_id, uid, chat_key if is_group else None,
             content_store.seal(new_id, content_store.F_MESSAGE_TEXT, SYSTEM_TEXT), SYSTEM_KIND),
        )
        ts = self.cur.fetchone()[0]
        for rid in recipients:
            self.cur.execute(
                "INSERT INTO message_recipients (message_id, user_id) VALUES (%s::uuid, %s::uuid) "
                "ON CONFLICT DO NOTHING",
                (new_id, rid),
            )
        return {"id": new_id, "timestamp": ts, "text": SYSTEM_TEXT}

    def unpin(self, message_id: str) -> dict | None:
        """Idempotently unpin (no-op when not pinned). Same shape as ``pin``
        minus the system line fields; no line and no push on removal."""
        uid, mid = _canon(self.user_id), _canon(message_id)
        if not (uid and mid):
            return None
        try:
            ctx = self._resolve(uid, mid)
            if ctx is None:
                self.conn.rollback()
                return None
            self.cur.execute(
                "DELETE FROM message_pins WHERE message_id = %s::uuid AND chat_key = %s",
                (mid, ctx["group_id"]),
            )
            changed = self.cur.rowcount == 1
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        return {"changed": changed, "message_id": mid, "group_id": ctx["group_id"],
                "recipients": ctx["recipients"]}

    def list_pins(self, *, group_id: str | None = None, friend_id: str | None = None,
                  limit: int = 50, offset: int = 0) -> dict | None:
        """Pinned messages of one chat, newest pin first, paginated.
        ``{"pins": [...], "has_more": bool, "count": n_total}`` or None."""
        uid = _canon(self.user_id)
        if not uid:
            return None
        limit = max(1, min(int(limit), max_page_size()))
        offset = max(0, int(offset))
        try:
            scope = self._chat_key(uid, friend_id, group_id)
            if scope is None:
                self.conn.rollback()
                return None
            chat_key, authors = scope
            clauses = "p.chat_key = %s AND m.deleted_at IS NULL AND m.system_kind IS NULL"
            params: list = [chat_key]
            if group_id is not None:
                clauses += " AND m.group_id = %s::uuid AND m.from_user = ANY(%s::uuid[])"
                params += [chat_key, authors]
            self.cur.execute(
                "SELECT COUNT(*) FROM message_pins p JOIN messages m ON m._id = p.message_id WHERE " + clauses,
                params,
            )
            total = int(self.cur.fetchone()[0])
            self.cur.execute(
                "SELECT p.message_id::text, p.pinned_by::text, p.pinned_at, pu.username, "
                "m.from_user::text, au.username, m.text, m.timestamp, m.attachment_kind "
                "FROM message_pins p JOIN messages m ON m._id = p.message_id "
                "LEFT JOIN users pu ON pu._id = p.pinned_by LEFT JOIN users au ON au._id = m.from_user "
                "WHERE " + clauses + " ORDER BY p.pinned_at DESC, p.message_id LIMIT %s OFFSET %s",
                params + [limit + 1, offset],
            )
            rows = self.cur.fetchall()
        finally:
            self.conn.rollback()  # read-only
        has_more = len(rows) > limit
        pins = []
        for mid, by_id, pinned_at, by_name, author_id, author_name, text, ts, kind in rows[:limit]:
            clear = content_store.open_or_none(mid, content_store.F_MESSAGE_TEXT, text, label="pin") or ""
            pins.append({
                "message_id": mid,
                "pinned_by_id": (by_id or "").lower(),
                "pinned_by": by_name or "",
                "pinned_at": pinned_at.isoformat() if pinned_at else None,
                "message": {
                    "id": mid,
                    "from_user_id": (author_id or "").lower(),
                    "from_user": author_name or "",
                    "text": clear if len(clear) <= PREVIEW_MAX else clear[: PREVIEW_MAX - 1] + "…",
                    "timestamp": paging.format_timestamp(ts) if ts else None,
                    "attachment_kind": kind,
                },
            })
        return {"pins": pins, "has_more": has_more, "count": total}
