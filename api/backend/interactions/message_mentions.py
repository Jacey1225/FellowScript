"""@mentions in chat messages (flag ``chat_mentions``).

Scope: DMs, group main chat and group thread messages (``messages`` and
``thread_messages``). Stored as ``mentions`` JSONB: a list of
``{"user_id", "start", "length"}`` with UTF-16 code unit offsets into the stored
text. The stored text keeps the literal ``@<username>``; usernames are never
stored, they are resolved at read time (rename safe).

Rules:
- Sender flag off: the ``mentions`` key is ignored entirely (plain message).
- Sender flag on: every entry is validated (``validate``); ANY failure rejects
  the whole send with nothing saved. ``MentionInvalid`` carries no detail so a
  sender cannot probe membership, blocks or suspension.
- Reads: ``attach_mentions`` batches the lookups for every history path and is
  the ONLY emitter of the key (the raw column is in
  ``groups._INTERNAL_MESSAGE_COLUMNS``). No-op while the flag is off for the
  viewer.
- Logs carry ids only, never message text or mention contents.
"""
from __future__ import annotations

import logging
import uuid

from backend.interactions import flags

logger = logging.getLogger(__name__)

FLAG = "chat_mentions"
MAX_MENTIONS = 10

# Attachment kinds whose text is built server side, so mentions are refused.
# (Mirrors shared_objects.SHARED_KINDS; kept literal to avoid an import cycle.)
_SHARED_KINDS = frozenset({"shared_verse", "shared_note"})
_ENTRY_KEYS = frozenset({"user_id", "start", "length"})
_TABLES = ("messages", "thread_messages")


class MentionInvalid(Exception):
    """A mention is not acceptable. Carries no detail on purpose."""


class MentionsTooMany(Exception):
    """More than ``MAX_MENTIONS`` entries."""


def _canon(value) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def utf16_len(text: str) -> int:
    """Length of ``text`` in UTF-16 code units. Raises on a lone surrogate."""
    return len(text.encode("utf-16-le")) // 2


def validate(cur, sender_id: str, recipients: list[str], text: str,
             attachment_kind: str | None, raw) -> "tuple[list[dict], list[dict]] | None":
    """Validate the client ``mentions`` value for a flag-on sender.

    ``cur`` has ``execute/fetchall`` (the send guard's cursor adapter).
    ``recipients`` are the AUTHORIZED recipients (group: live member list; DM:
    the other party). ``text`` is the FINAL stored text. Returns ``None`` for a
    plain message (absent, null or empty list), else ``(stored, public)``:
    the canonical list to persist and the same list with current usernames.
    Raises ``MentionsTooMany`` / ``MentionInvalid``; other exceptions are
    infrastructure failures the caller reports as retriable.
    """
    if raw is None:
        return None
    if not isinstance(raw, list):
        raise MentionInvalid()
    if not raw:
        return None
    if len(raw) > MAX_MENTIONS:
        raise MentionsTooMany()
    if attachment_kind in _SHARED_KINDS:
        raise MentionInvalid()
    sender = _canon(sender_id)
    if sender is None or not isinstance(text, str):
        raise MentionInvalid()
    try:
        encoded = text.encode("utf-16-le")
    except UnicodeEncodeError:
        raise MentionInvalid()
    total_units = len(encoded) // 2
    allowed = {r.lower() for r in recipients if isinstance(r, str)}

    stored: list[dict] = []
    seen: set[str] = set()
    prev_end = 0
    for entry in raw:
        if not isinstance(entry, dict) or set(entry.keys()) != _ENTRY_KEYS:
            raise MentionInvalid()
        uid, start, length = _canon(entry["user_id"]), entry["start"], entry["length"]
        if uid is None or not _is_int(start) or not _is_int(length):
            raise MentionInvalid()
        if start < 0 or length < 2 or uid == sender or uid not in allowed or uid in seen:
            raise MentionInvalid()
        if start < prev_end or start + length > total_units:
            raise MentionInvalid()
        seen.add(uid)
        prev_end = start + length
        stored.append({"user_id": uid, "start": start, "length": length})

    cur.execute(
        "SELECT _id::text, username FROM users WHERE _id = ANY(%s::uuid[]) AND suspended_at IS NULL",
        (sorted(seen),),
    )
    names = {str(r[0]).lower(): r[1] for r in cur.fetchall()}
    if set(names) != seen:
        raise MentionInvalid()  # unknown or suspended
    cur.execute(
        "SELECT blocked_id::text FROM blocked_users WHERE blocker_id = %s::uuid "
        "UNION SELECT blocker_id::text FROM blocked_users WHERE blocked_id = %s::uuid",
        (sender, sender),
    )
    blocked = {str(r[0]).lower() for r in cur.fetchall()}
    if blocked & seen:
        raise MentionInvalid()

    for m in stored:
        expected = ("@" + str(names[m["user_id"]])).encode("utf-16-le")
        if encoded[2 * m["start"]: 2 * (m["start"] + m["length"])] != expected:
            raise MentionInvalid()  # also catches a range splitting a surrogate pair
    public = [{**m, "username": names[m["user_id"]]} for m in stored]
    return stored, public


def _public(stored: list, names: dict[str, str]) -> list[dict]:
    out = []
    for m in stored:
        entry = {"user_id": str(m["user_id"]).lower(), "start": m["start"], "length": m["length"]}
        name = names.get(entry["user_id"])
        if name is not None:
            entry["username"] = name
        out.append(entry)
    return out


def resolve_public(db, stored_by_id: dict[str, list]) -> dict[str, list[dict]]:
    """``{message_id: public mentions}`` with current usernames, one query."""
    ids = sorted({str(m["user_id"]).lower() for v in stored_by_id.values() for m in v})
    names: dict[str, str] = {}
    if ids:
        db.cur.execute("SELECT _id::text, username FROM users WHERE _id = ANY(%s::uuid[])", (ids,))
        names = {str(r[0]).lower(): r[1] for r in db.cur.fetchall()}
    return {mid: _public(v, names) for mid, v in stored_by_id.items()}


def attach_mentions(db, messages: list[dict], viewer_id: str, table: str = "messages") -> None:
    """Add ``mentions`` (with current usernames) to every message dict (with an
    ``id``) that has them, in place, in a fixed number of queries. Messages
    without mentions are untouched (key absent). No-op while the flag is off
    for the viewer."""
    if table not in _TABLES:
        raise ValueError("unknown message table")
    if not messages or not flags.is_enabled(FLAG, viewer_id):
        return
    ids = [i for i in (_canon(str(m["id"])) for m in messages if m.get("id")) if i]
    if not ids:
        return
    try:
        db.cur.execute(
            f"SELECT _id::text, mentions FROM {table} WHERE _id = ANY(%s::uuid[]) AND mentions IS NOT NULL",
            (ids,),
        )
        stored = {r[0].lower(): r[1] for r in db.cur.fetchall() if isinstance(r[1], list) and r[1]}
        resolved = resolve_public(db, stored) if stored else {}
    finally:
        db.conn.rollback()  # read-only; release the snapshot
    for m in messages:
        pub = resolved.get(str(m.get("id", "")).lower())
        if pub:
            m["mentions"] = pub


def clip_for_preview(public: list[dict], emitted_text: str, ellipsis: bool) -> list[dict]:
    """Mentions that still lie fully inside a truncated preview text (pins)."""
    limit = utf16_len(emitted_text) - (1 if ellipsis else 0)
    return [m for m in public if m["start"] + m["length"] <= limit]
