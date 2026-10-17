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
- ``announcement_reminder``: one hour before a scheduled announcement goes live (default ON)
- ``prayer_reminder`` / ``check_in_reminder`` / ``deep_question_reminder``:
  opt-in daily reminders (default OFF, each with a local ``*_time`` "HH:MM")

Essential pushes are NOT toggleable and never consult this module: incoming
call ring (alert + VoIP), the join-request push to the group owner, the
join-request approval notice to the requester, friend requests, and "a new
member joined" to existing members. ``join_requests`` used to be a toggle; PUT
still accepts it (ignored) and GET still reports it as always ``true`` so the
shipped client keeps decoding.

Failure posture: a lookup error for a default-ON type falls back to the
default (send), because these are comfort preferences and a best-effort push
must never fail the originating request. A stored opt-out is always respected.
Default-OFF types fail CLOSED: a missing row or any lookup error means "not
enabled", so a user who never opted in is never pushed because of a DB error.
Logs carry exception class names only, never user ids.
"""
from __future__ import annotations

import asyncio
import logging
import re
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
    "announcement_reminder",
    "prayer_reminder",
    "check_in_reminder",
    "deep_question_reminder",
)
_TYPE_SET = frozenset(PUSH_TYPES)

# Types whose default (missing row / column) is OFF; everything else defaults ON.
DEFAULT_OFF_TYPES: frozenset[str] = frozenset(
    {"prayer_reminder", "check_in_reminder", "deep_question_reminder"}
)

# Legacy toggle keys: accepted on PUT and ignored, reported on GET as constant True.
LEGACY_IGNORED_KEYS: tuple[str, ...] = ("join_requests",)

# Per-type local time of day (``HH:MM``), only for the opt-in reminders.
TIME_KEYS: tuple[str, ...] = (
    "prayer_reminder_time",
    "check_in_reminder_time",
    "deep_question_reminder_time",
)
_TIME_SET = frozenset(TIME_KEYS)
DEFAULT_TIMES: dict[str, str] = {
    "prayer_reminder_time": "08:00",
    "check_in_reminder_time": "18:00",
    "deep_question_reminder_time": "20:00",
}
_TIME_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


def is_valid_time(value) -> bool:
    return isinstance(value, str) and _TIME_RE.match(value) is not None


def _canon(value) -> str | None:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, AttributeError, TypeError):
        return None


def defaults() -> dict:
    out: dict = {t: t not in DEFAULT_OFF_TYPES for t in PUSH_TYPES}
    out.update(DEFAULT_TIMES)
    for k in LEGACY_IGNORED_KEYS:
        out[k] = True
    return out


def get_preferences(user_id: str) -> dict:
    """All known keys for ``user_id``; raises on DB error (API surface).

    Booleans for every type, ``HH:MM`` strings for the reminder times, and the
    legacy ``join_requests`` key as constant ``True``.
    """
    db = DBManager()
    try:
        cols = ", ".join((*PUSH_TYPES, *(f"to_char({k}, 'HH24:MI')" for k in TIME_KEYS)))  # constants only
        db.cur.execute(f"SELECT {cols} FROM push_preferences WHERE user_id = %s", (user_id,))
        row = db.cur.fetchone()
        db.conn.rollback()
        if row is None:
            return defaults()
        out: dict = {t: bool(v) for t, v in zip(PUSH_TYPES, row)}
        out.update({k: str(v) for k, v in zip(TIME_KEYS, row[len(PUSH_TYPES):])})
        for k in LEGACY_IGNORED_KEYS:
            out[k] = True
        return out
    finally:
        db.close()


def set_preferences(user_id: str, updates: dict) -> dict:
    """Upsert a subset of known keys; returns the full resulting map.

    Legacy keys are dropped silently (an update of only legacy keys writes
    nothing). Booleans must be ``bool``, times valid ``HH:MM``.
    """
    updates = {k: v for k, v in updates.items() if k not in LEGACY_IGNORED_KEYS}
    if not updates:
        return get_preferences(user_id)
    for k, v in updates.items():
        if k in _TYPE_SET:
            if not isinstance(v, bool):
                raise ValueError("preference values must be booleans")
        elif k in _TIME_SET:
            if not is_valid_time(v):
                raise ValueError("reminder time must be HH:MM")
        else:
            raise ValueError("unknown or empty preference update")
    keys = list(updates)  # validated against the constant sets above
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

    Sync (own connection). Default-ON types fail open (any error returns an
    empty set). Default-OFF types fail CLOSED: "disabled" is everyone who has
    not explicitly enabled the type, and any error disables everyone.
    """
    if push_type not in _TYPE_SET:
        raise ValueError(f"unknown push type: {push_type!r}")
    ids = [c for c in (_canon(u) for u in user_ids) if c]
    if not ids:
        return set()
    default_off = push_type in DEFAULT_OFF_TYPES
    on_error = {i.lower() for i in ids} if default_off else set()
    try:
        db = DBManager()
    except Exception as e:  # noqa: BLE001
        logger.warning("PUSH_PREF lookup failed reason=%s", type(e).__name__)
        return on_error
    try:
        if default_off:
            db.cur.execute(
                f"SELECT user_id::text FROM push_preferences "
                f"WHERE user_id = ANY(%s::uuid[]) AND {push_type} = TRUE",
                (ids,),
            )
            enabled = {r[0].lower() for r in db.cur.fetchall()}
            db.conn.rollback()
            return {i.lower() for i in ids} - enabled
        db.cur.execute(
            f"SELECT user_id::text FROM push_preferences "
            f"WHERE user_id = ANY(%s::uuid[]) AND {push_type} = FALSE",
            (ids,),
        )
        out = {r[0].lower() for r in db.cur.fetchall()}
        db.conn.rollback()
        return out
    except Exception as e:  # noqa: BLE001 - see docstring for the per-type posture
        try:
            db.conn.rollback()
        except Exception:  # noqa: BLE001
            pass
        logger.warning("PUSH_PREF lookup failed reason=%s", type(e).__name__)
        return on_error
    finally:
        db.close()


def is_push_enabled(user_id: str, push_type: str) -> bool:
    """True unless ``user_id`` opted out of ``push_type`` (sync). Default-OFF
    types are True only on an explicit opt-in and are False on any error."""
    cid = _canon(user_id)
    if cid is None:
        return push_type not in DEFAULT_OFF_TYPES
    return cid not in disabled_user_ids([cid], push_type)


async def async_disabled_user_ids(user_ids: Iterable[str], push_type: str) -> set[str]:
    """``disabled_user_ids`` off the event loop."""
    ids = list(user_ids)
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, disabled_user_ids, ids, push_type)


async def async_is_push_enabled(user_id: str, push_type: str) -> bool:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, is_push_enabled, user_id, push_type)
