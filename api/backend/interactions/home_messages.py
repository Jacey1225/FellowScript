"""Home announcement messages: validation, admin CRUD, and the public winner
selection (task 20261002-home-announcement-headline).

All writers take an open ``cur`` and never commit (the route owns the
transaction). Text is plain only: control/format characters are stripped,
whitespace collapsed, and anything that looks like markup or a link is rejected
(fail closed). The enabled-message cap is enforced under a transaction-scoped
advisory lock so two concurrent enables cannot both pass the count.

Public read: ``current_message()`` caches the (small) list of ENABLED rows for
``cache_ttl_seconds`` and evaluates windows against the clock on every call, so
a window boundary is never served late. Writers call ``invalidate()``. Any DB
failure answers "no message" (never raises) and is not cached.
"""
from __future__ import annotations

import logging
import threading
import time
import unicodedata
import uuid
from datetime import datetime, timezone

from backend.interactions.home_messages_config import get_home_messages_config
from db import DBManager

logger = logging.getLogger(__name__)

_LOCK_KEY = 0x484D5347  # "HMSG"; advisory lock serialising cap checks
_SELECT = "_id::text, text, enabled, starts_at, ends_at, priority, destination, created_at, updated_at"
_FORBIDDEN_SUBSTRINGS = ("<", ">", "://", "www.", "javascript:", "data:", "&#", "](")


class HomeMessageError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def clean_text(raw: str) -> str:
    """Normalise and validate announcement text; raises ``HomeMessageError`` (422)."""
    if not isinstance(raw, str):
        raise HomeMessageError(422, "Text is required")
    out = []
    for ch in raw:
        if ch in "\n\r\t" or unicodedata.category(ch) == "Zs":
            out.append(" ")
        elif unicodedata.category(ch)[0] == "C":
            continue  # control, format, surrogate, private-use, unassigned
        else:
            out.append(ch)
    text = " ".join("".join(out).split())
    if not text:
        raise HomeMessageError(422, "Text is required")
    limit = get_home_messages_config().text_max_length
    if len(text) > limit:
        raise HomeMessageError(422, f"Text is limited to {limit} characters")
    lowered = text.lower()
    if any(bad in lowered for bad in _FORBIDDEN_SUBSTRINGS):
        raise HomeMessageError(422, "Text must be plain text without markup or links")
    return text


def _parse_id(message_id: str) -> str:
    try:
        return str(uuid.UUID(message_id))
    except (ValueError, AttributeError, TypeError):
        raise HomeMessageError(404, "Message not found") from None


def _check_window(starts_at, ends_at) -> None:
    for v in (starts_at, ends_at):
        if v is not None and v.tzinfo is None:
            raise HomeMessageError(422, "Dates must include a timezone")
    if starts_at is not None and ends_at is not None and ends_at <= starts_at:
        raise HomeMessageError(422, "End must be after start")


def _row(r) -> dict:
    return {
        "id": r[0], "text": r[1], "enabled": r[2],
        "starts_at": r[3].isoformat() if r[3] else None,
        "ends_at": r[4].isoformat() if r[4] else None,
        "priority": r[5], "destination": r[6],
        "created_at": r[7].isoformat(), "updated_at": r[8].isoformat(),
    }


def _enforce_cap(cur, excluding_id: str | None) -> None:
    cur.execute("SELECT pg_advisory_xact_lock(%s)", (_LOCK_KEY,))
    cur.execute(
        "SELECT COUNT(*) FROM home_messages WHERE enabled AND (%s::uuid IS NULL OR _id <> %s::uuid)",
        (excluding_id, excluding_id),
    )
    cap = get_home_messages_config().max_enabled
    if cur.fetchone()[0] >= cap:
        raise HomeMessageError(409, f"At most {cap} messages can be enabled at once; disable one first")


def admin_list(cur) -> list[dict]:
    limit = get_home_messages_config().admin_list_limit
    cur.execute(
        f"SELECT {_SELECT} FROM home_messages ORDER BY created_at DESC LIMIT %s", (limit,)
    )
    return [_row(r) for r in cur.fetchall()]


def create(cur, actor: str, text: str, priority: int, starts_at, ends_at, enabled: bool) -> dict:
    clean = clean_text(text)
    _check_window(starts_at, ends_at)
    if enabled:
        _enforce_cap(cur, None)
    cur.execute(
        "INSERT INTO home_messages (text, enabled, starts_at, ends_at, priority, created_by, updated_by) "
        f"VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING {_SELECT}",
        (clean, enabled, starts_at, ends_at, priority, actor, actor),
    )
    invalidate()
    return _row(cur.fetchone())


def update(cur, actor: str, message_id: str, changes: dict) -> dict:
    """Apply only the keys present in ``changes`` (text, priority, starts_at, ends_at, enabled)."""
    mid = _parse_id(message_id)
    cur.execute(f"SELECT {_SELECT} FROM home_messages WHERE _id = %s FOR UPDATE", (mid,))
    existing = cur.fetchone()
    if existing is None:
        raise HomeMessageError(404, "Message not found")
    cur_row = _row(existing)
    text = clean_text(changes["text"]) if "text" in changes else cur_row["text"]
    priority = changes.get("priority", cur_row["priority"])
    starts_at = changes["starts_at"] if "starts_at" in changes else existing[3]
    ends_at = changes["ends_at"] if "ends_at" in changes else existing[4]
    enabled = changes.get("enabled", cur_row["enabled"])
    _check_window(starts_at, ends_at)
    if enabled and not cur_row["enabled"]:
        _enforce_cap(cur, mid)
    cur.execute(
        "UPDATE home_messages SET text=%s, enabled=%s, starts_at=%s, ends_at=%s, priority=%s, "
        f"updated_at=NOW(), updated_by=%s WHERE _id=%s RETURNING {_SELECT}",
        (text, enabled, starts_at, ends_at, priority, actor, mid),
    )
    invalidate()
    return _row(cur.fetchone())


def delete(cur, message_id: str) -> None:
    mid = _parse_id(message_id)
    cur.execute("DELETE FROM home_messages WHERE _id = %s", (mid,))
    if cur.rowcount == 0:
        raise HomeMessageError(404, "Message not found")
    invalidate()


# -- public read ----------------------------------------------------------------

_lock = threading.Lock()
_cache: list[tuple] | None = None
_cache_at = 0.0


def invalidate() -> None:
    global _cache, _cache_at
    with _lock:
        _cache = None
        _cache_at = 0.0


def _load_enabled() -> list[tuple]:
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT _id::text, text, destination, starts_at, ends_at, priority, created_at "
            "FROM home_messages WHERE enabled"
        )
        return db.cur.fetchall()
    finally:
        db.close()


def _enabled_rows() -> list[tuple]:
    global _cache, _cache_at
    ttl = get_home_messages_config().cache_ttl_seconds
    now = time.monotonic()
    with _lock:
        if _cache is not None and now - _cache_at < ttl:
            return _cache
    rows = _load_enabled()
    with _lock:
        _cache = rows
        _cache_at = time.monotonic()
    return rows


def current_message(now: datetime | None = None) -> dict | None:
    """The winning active message (priority desc, then newest) or ``None``.

    Never raises: any failure is logged (word "failed", not ERROR, per the
    watchdog convention) and answered as "no message".
    """
    try:
        rows = _enabled_rows()
    except Exception:  # noqa: BLE001 - fail soft on anything
        logger.warning("home message lookup failed; serving no message")
        return None
    when = now or datetime.now(timezone.utc)
    active = [
        r for r in rows
        if (r[3] is None or r[3] <= when) and (r[4] is None or when < r[4])
    ]
    if not active:
        return None
    # priority desc, then created_at desc (id as a final stable tiebreak)
    best = sorted(active, key=lambda r: (r[5], r[6], r[0]), reverse=True)[0]
    return {"id": best[0], "text": best[1], "destination": best[2]}
