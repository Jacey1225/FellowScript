"""Per-user push notification preferences (task 20261012-notification-settings).

One optional ``push_preferences`` row per user; one BOOLEAN column per
user-toggleable push type, default on, missing row = on.

Type grouping (the API keys, also the column names):

- ``messages``: chat messages (DM/group) and thread replies
- ``pins``: someone pinned a message
- ``reactions``: someone reacted to your message
- ``friend_highlight``: a friend highlighted a verse
- ``announcements``: group announcements (published / scheduled heads-up)
- ``session_reminders``: new session scheduled, session starting
- ``reminders``: daily "gentle nudge"/"it's been a while" and scheduled agent events
- ``friend_activity``: friend came back/active, and friend nudges
- ``join_requests``: a join request to a group you own

Essential pushes are NOT toggleable and never consult this module: incoming
call ring (alert + VoIP) and the join-request approval notice to the requester.

Failure posture: a lookup error for a toggleable type falls back to the
default (send), because these are comfort preferences and a best-effort push
must never fail the originating request. A stored opt-out is always respected.
Logs carry exception class names only, never user ids.
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from typing import Iterable

from db import DBManager

logger = logging.getLogger(__name__)

PUSH_TYPES: tuple[str, ...] = (
    "messages",
    "pins",
    "reactions",
    "friend_highlight",
    "announcements",
    "session_reminders",
    "reminders",
    "friend_activity",
    "join_requests",
)
_TYPE_SET = frozenset(PUSH_TYPES)


def _canon(value) -> str | None:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, AttributeError, TypeError):
        return None


def defaults() -> dict[str, bool]:
    return {t: True for t in PUSH_TYPES}


def get_preferences(user_id: str) -> dict[str, bool]:
    """All known types for ``user_id``; raises on DB error (API surface)."""
    db = DBManager()
    try:
        cols = ", ".join(PUSH_TYPES)  # constants only, never user input
        db.cur.execute(f"SELECT {cols} FROM push_preferences WHERE user_id = %s", (user_id,))
        row = db.cur.fetchone()
        db.conn.rollback()
        if row is None:
            return defaults()
        return {t: bool(v) for t, v in zip(PUSH_TYPES, row)}
    finally:
        db.close()


def set_preferences(user_id: str, updates: dict[str, bool]) -> dict[str, bool]:
    """Upsert a subset of known types; returns the full resulting map."""
    if not updates or any(k not in _TYPE_SET for k in updates):
        raise ValueError("unknown or empty preference update")
    keys = list(updates)  # validated against the constant set above
    cols = ", ".join(keys)
    placeholders = ", ".join(["%s"] * len(keys))
    assigns = ", ".join(f"{k} = EXCLUDED.{k}" for k in keys)
    db = DBManager()
    try:
        try:
            db.cur.execute(
                f"INSERT INTO push_preferences (user_id, {cols}, updated_at) "
                f"VALUES (%s, {placeholders}, NOW()) "
                f"ON CONFLICT (user_id) DO UPDATE SET {assigns}, updated_at = NOW()",
                (user_id, *[updates[k] for k in keys]),
            )
            db.conn.commit()
        except Exception:
            db.conn.rollback()
            raise
    finally:
        db.close()
    return get_preferences(user_id)


def disabled_user_ids(user_ids: Iterable[str], push_type: str) -> set[str]:
    """Lower-cased ids among ``user_ids`` that opted out of ``push_type``.

    Sync (own connection). Fails open: any error returns an empty set.
    """
    if push_type not in _TYPE_SET:
        raise ValueError(f"unknown push type: {push_type!r}")
    ids = [c for c in (_canon(u) for u in user_ids) if c]
    if not ids:
        return set()
    try:
        db = DBManager()
    except Exception as e:  # noqa: BLE001
        logger.warning("PUSH_PREF lookup failed reason=%s", type(e).__name__)
        return set()
    try:
        db.cur.execute(
            f"SELECT user_id::text FROM push_preferences "
            f"WHERE user_id = ANY(%s::uuid[]) AND {push_type} = FALSE",
            (ids,),
        )
        out = {r[0].lower() for r in db.cur.fetchall()}
        db.conn.rollback()
        return out
    except Exception as e:  # noqa: BLE001 - comfort pref: fail open
        try:
            db.conn.rollback()
        except Exception:  # noqa: BLE001
            pass
        logger.warning("PUSH_PREF lookup failed reason=%s", type(e).__name__)
        return set()
    finally:
        db.close()


def is_push_enabled(user_id: str, push_type: str) -> bool:
    """True unless ``user_id`` opted out of ``push_type`` (sync, fails open)."""
    cid = _canon(user_id)
    if cid is None:
        return True
    return cid not in disabled_user_ids([cid], push_type)


async def async_disabled_user_ids(user_ids: Iterable[str], push_type: str) -> set[str]:
    """``disabled_user_ids`` off the event loop."""
    ids = list(user_ids)
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, disabled_user_ids, ids, push_type)


async def async_is_push_enabled(user_id: str, push_type: str) -> bool:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, is_push_enabled, user_id, push_type)
