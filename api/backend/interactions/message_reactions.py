"""Emoji reactions on chat messages (flag ``message_reactions``).

Scope: group messages and DMs (both live in ``messages``); group thread
messages are deferred. One row per (message, user, emoji) in
``message_reactions``.

Rules:
- Deny by default. A reaction needs the caller to be able to SEE the message:
  not soft-deleted; group message: caller is a live member and the author is
  the caller or a live member not in a block relationship with the caller;
  DM: caller is the author or a recipient and no participant pair involving
  the caller is blocked. Every failure returns ``None`` (the route answers one
  uniform 404, no oracle for ids, membership or state).
- Emoji come from a fixed allowlist, stored exactly as listed (no skin-tone or
  variation variants). The same list is exposed through capabilities.
- Caps (bound abuse and payload size): ``MAX_DISTINCT_PER_MESSAGE`` distinct
  emoji per message, ``MAX_PER_USER_PER_MESSAGE`` per user per message.
- Add and remove are idempotent. Adds for one message serialize on a
  transaction-scoped advisory lock so the caps hold under concurrency.
- Rows survive a soft delete; every reader filters ``messages.deleted_at``.
- Logs carry ids only, never text.
"""
from __future__ import annotations

import logging
import uuid
from functools import lru_cache

import psycopg2.errors

from backend.config_loader import load_section
from backend.interactions import flags
from backend.interactions.chat_config import CONFIG_PATH
from db import DBManager

logger = logging.getLogger(__name__)

FLAG = "message_reactions"
CONFIG_SECTION = "message_reactions"

QUICK_EMOJI = ("\U0001F44D", "❤️", "\U0001F602", "\U0001F62E", "\U0001F622", "\U0001F64F")
MORE_EMOJI = (
    "\U0001F525", "\U0001F389", "\U0001F44F", "\U0001F4AF", "\U0001F60D", "\U0001F914",
    "\U0001F62D", "\U0001F64C", "\U0001F600", "\U0001F60A", "\U0001F609", "\U0001F970",
    "\U0001F60E", "\U0001F917", "\U0001F644", "\U0001F621", "\U0001F44E", "\U0001F4AA",
    "✅", "❌", "✨", "\U0001F440", "\U0001F607", "\U0001F54A️",
)
ALLOWED_EMOJI = QUICK_EMOJI + MORE_EMOJI
_ALLOWED_SET = frozenset(ALLOWED_EMOJI)
MAX_EMOJI_LENGTH = 16  # generous bound on the raw field before the allowlist check

MAX_DISTINCT_PER_MESSAGE = 20
MAX_PER_USER_PER_MESSAGE = 10

CAP_MESSAGE = "message_cap"
CAP_USER = "user_cap"


def is_allowed_emoji(value) -> bool:
    return isinstance(value, str) and value in _ALLOWED_SET


@lru_cache(maxsize=1)
def reaction_rate() -> str:
    raw = load_section(
        CONFIG_PATH, CONFIG_SECTION,
        required_keys=("rate",), types={"rate": str}, rate_keys=("rate",),
    )
    return raw["rate"]


def capability_emoji(user_id: str | None) -> dict:
    """Allowlist for clients; empty lists while the flag is off for the user."""
    if not flags.is_enabled(FLAG, user_id):
        return {"quick": [], "more": []}
    return {"quick": list(QUICK_EMOJI), "more": list(MORE_EMOJI)}


def _canon(value) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def reactions_for_messages(cur, message_ids: list[str], viewer_id: str) -> dict[str, list[dict]]:
    """Aggregate reactions for many messages in ONE query.

    Returns ``{message_id: [{"emoji", "count", "viewer_reacted"}, ...]}``;
    messages without reactions (or soft-deleted ones) have no key. Order is
    by first reaction time. Read-only; the caller owns the transaction.
    """
    viewer = _canon(viewer_id)
    ids = [m for m in (_canon(i) for i in message_ids) if m]
    if not ids or viewer is None:
        return {}
    cur.execute(
        "SELECT r.message_id::text, r.emoji, COUNT(*), BOOL_OR(r.user_id = %s::uuid), MIN(r.created_at) "
        "FROM message_reactions r JOIN messages m ON m._id = r.message_id "
        "WHERE r.message_id = ANY(%s::uuid[]) AND m.deleted_at IS NULL "
        "GROUP BY r.message_id, r.emoji ORDER BY MIN(r.created_at), r.emoji",
        (viewer, ids),
    )
    out: dict[str, list[dict]] = {}
    for mid, emoji, count, mine, _first in cur.fetchall():
        out.setdefault(mid, []).append({"emoji": emoji, "count": int(count), "viewer_reacted": bool(mine)})
    return out


def attach_reactions(db: DBManager, messages: list[dict], viewer_id: str) -> None:
    """Add ``reactions`` (possibly empty list) to every message dict that has
    an ``id``, in place, with a single batch query. No-op while the flag is
    off for the viewer, so payloads omit the key entirely."""
    if not messages or not flags.is_enabled(FLAG, viewer_id):
        return
    try:
        found = reactions_for_messages(db.cur, [m["id"] for m in messages if m.get("id")], viewer_id)
    finally:
        db.conn.rollback()  # read-only; release the snapshot
    for m in messages:
        if m.get("id"):
            m["reactions"] = found.get(str(m["id"]).lower(), [])


def reaction_frame(message_id: str, group_id: str, emoji: str, count: int, actor_id: str) -> dict:
    """Live frame. Carries ``type`` and neither ``from_user`` nor ``text``, so
    older clients (which render any frame with those) ignore it. Receivers
    compare ``actor_id`` with their own id to keep their own ``viewer_reacted``."""
    return {
        "type": "reaction_updated", "message_id": message_id, "group_id": group_id,
        "emoji": emoji, "count": count, "actor_id": actor_id,
    }


class MessageReactionsManager(DBManager):
    """Add / remove one reaction; returns None for every denial."""

    def __init__(self, user_id: str) -> None:
        super().__init__()
        self.user_id = user_id

    # -- visibility ---------------------------------------------------------

    def _blocked_with(self, user_id: str) -> set[str]:
        self.cur.execute(
            "SELECT blocked_id::text FROM blocked_users WHERE blocker_id = %s::uuid "
            "UNION SELECT blocker_id::text FROM blocked_users WHERE blocked_id = %s::uuid",
            (user_id, user_id),
        )
        return {str(r[0]).lower() for r in self.cur.fetchall()}

    def _resolve(self, uid: str, mid: str) -> dict | None:
        """Context for a message the caller may see, else None. Read-only."""
        from backend.interactions.groups import live_member_ids  # lazy: groups imports this module
        self.cur.execute(
            "SELECT m.group_id::text, m.from_user::text FROM messages m "
            "WHERE m._id = %s::uuid AND m.deleted_at IS NULL",
            (mid,),
        )
        row = self.cur.fetchone()
        if not row or not row[1]:
            return None
        group_id, author = row[0], row[1].lower()
        blocked_me = self._blocked_with(uid)
        if group_id:
            members = live_member_ids(self.cur, group_id)
            if uid not in members:
                return None
            if author != uid and (author not in members or author in blocked_me):
                return None
            recipients = [m for m in members if m != uid and m not in blocked_me]
            if author != uid:
                blocked_author = self._blocked_with(author)
                recipients = [m for m in recipients if m not in blocked_author]
            return {"group_id": group_id, "recipients": recipients}
        self.cur.execute(
            "SELECT user_id::text FROM message_recipients WHERE message_id = %s::uuid", (mid,),
        )
        participants = {author} | {str(r[0]).lower() for r in self.cur.fetchall()}
        if uid not in participants:
            return None
        others = participants - {uid}
        if not others or others & blocked_me:
            return None
        return {"group_id": "|".join(sorted(participants)), "recipients": sorted(others)}

    # -- writes -------------------------------------------------------------

    def _count(self, mid: str, emoji: str, uid: str) -> dict:
        self.cur.execute(
            "SELECT COUNT(*), BOOL_OR(user_id = %s::uuid) FROM message_reactions "
            "WHERE message_id = %s::uuid AND emoji = %s",
            (uid, mid, emoji),
        )
        count, mine = self.cur.fetchone()
        return {"emoji": emoji, "count": int(count), "viewer_reacted": bool(mine)}

    def add(self, message_id: str, emoji: str) -> dict | None:
        """Add the caller's reaction. ``{"changed", "reaction", "group_id",
        "recipients"}``, ``{"cap": CAP_*}`` when a cap refuses, or None."""
        uid, mid = _canon(self.user_id), _canon(message_id)
        if not (uid and mid) or not is_allowed_emoji(emoji):
            return None
        try:
            ctx = self._resolve(uid, mid)
            if ctx is None:
                self.conn.rollback()
                return None
            self.cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (mid,))
            self.cur.execute(
                "SELECT 1 FROM message_reactions WHERE message_id = %s::uuid AND user_id = %s::uuid AND emoji = %s",
                (mid, uid, emoji),
            )
            changed = False
            if not self.cur.fetchone():
                self.cur.execute(
                    "SELECT COUNT(DISTINCT emoji), COUNT(DISTINCT emoji) FILTER (WHERE user_id = %s::uuid), "
                    "BOOL_OR(emoji = %s) FROM message_reactions WHERE message_id = %s::uuid",
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
                    "INSERT INTO message_reactions (message_id, user_id, emoji) "
                    "VALUES (%s::uuid, %s::uuid, %s) ON CONFLICT DO NOTHING",
                    (mid, uid, emoji),
                )
                changed = self.cur.rowcount == 1
            reaction = self._count(mid, emoji, uid)
            self.conn.commit()
        except psycopg2.errors.ForeignKeyViolation:
            self.conn.rollback()  # message or user removed concurrently
            return None
        except Exception:
            self.conn.rollback()
            raise
        return {"changed": changed, "reaction": reaction, "message_id": mid,
                "group_id": ctx["group_id"], "recipients": ctx["recipients"]}

    def remove(self, message_id: str, emoji: str) -> dict | None:
        """Remove the caller's reaction (no-op when absent). Same shape as ``add``."""
        uid, mid = _canon(self.user_id), _canon(message_id)
        if not (uid and mid) or not is_allowed_emoji(emoji):
            return None
        try:
            ctx = self._resolve(uid, mid)
            if ctx is None:
                self.conn.rollback()
                return None
            self.cur.execute(
                "DELETE FROM message_reactions WHERE message_id = %s::uuid AND user_id = %s::uuid AND emoji = %s",
                (mid, uid, emoji),
            )
            changed = self.cur.rowcount == 1
            reaction = self._count(mid, emoji, uid)
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise
        return {"changed": changed, "reaction": reaction, "message_id": mid,
                "group_id": ctx["group_id"], "recipients": ctx["recipients"]}
