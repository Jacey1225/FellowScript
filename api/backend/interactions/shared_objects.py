"""Verse and note shares inside DM / group chat messages (task 20261012-share-verses-notes-in-chat).

Two extra values of ``messages.attachment_kind`` (``SHARED_KINDS``): ``shared_verse``
and ``shared_note``. They carry no object key; the payload lives in
``attachment_meta`` and is ALWAYS built here on the server from validated input,
never copied from the client frame:

- ``shared_verse``: client sends ``{book, chapter, verse, verse_end?}``. The
  reference must be real (``bible_text.is_valid_reference``), the range is capped
  by config, and the text comes from the server's own Bible data (WEB).
- ``shared_note``: client sends ``{note_id}``. The sender may share only a note
  they OWN (personal or group), or a group note that is editable by the whole
  group (``group_id`` set, ``public`` true, not a reply) in a group they are a
  live member of. Anything else is refused. The card fields (title, preview,
  date, owner, group/personal) are a snapshot taken at send time.

Old clients: ``text`` is overwritten with a plain fallback line (the verse
quoted with its reference, or ``Shared a note: <title>``), so a client that does
not know the kind renders an ordinary text bubble. A new client renders the
widget from ``attachment_meta`` and ignores ``text``. Push uses the same line
(note previews are truncated to the title only).

Read access (the share grant): the message IS the grant. ``open_shared_note``
lets a viewer read the note only when ALL hold, otherwise ``None`` (one uniform
404 at the route, no oracle): the message is not soft-deleted, the viewer can
see the message (live group member or DM participant, no block pair, via the
reactions ``_resolve`` rule), the message is a ``shared_note`` whose ``note_id``
still exists, and the message's SENDER is still allowed to share that note (so
a note that became private, or a sender who left the group of an editable group
note, stops being readable). Read-only: nothing here writes; the grant covers
exactly one note, never the author's others, and the payload carries no reply
or reshare capability. Deleting the message revokes the grant; restoring it
restores the grant. The note itself is a live view (later edits are visible).

Logs carry ids only.
"""
from __future__ import annotations

import logging
import uuid
from functools import lru_cache

from backend.config_loader import load_section
from backend.interactions import flags
from backend.interactions.bible_text import is_valid_reference, verse_text
from backend.interactions.chat_config import CONFIG_PATH
from backend.interactions.groups import live_member_ids
from backend.interactions.message_reactions import MessageReactionsManager, _canon

logger = logging.getLogger(__name__)

FLAG = "chat_shared_objects"
CONFIG_SECTION = "shared_objects"
KIND_VERSE = "shared_verse"
KIND_NOTE = "shared_note"
SHARED_KINDS = frozenset({KIND_VERSE, KIND_NOTE})


class ShareRejected(Exception):
    """The share payload is invalid or not permitted; the sender gets ``not_allowed``."""


@lru_cache(maxsize=1)
def _config() -> dict:
    return load_section(
        CONFIG_PATH, CONFIG_SECTION,
        required_keys=("note_title_max_chars", "note_preview_max_chars", "verse_max_range", "view_rate"),
        types={"note_title_max_chars": int, "note_preview_max_chars": int,
               "verse_max_range": int, "view_rate": str},
        rate_keys=("view_rate",),
    )


def view_rate() -> str:
    return _config()["view_rate"]


def _clip(value, limit: int) -> str:
    s = " ".join(str(value or "").split())
    return s if len(s) <= limit else s[: max(0, limit - 1)].rstrip() + "…"


def _int(value) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def build_verse(meta) -> tuple[dict, str]:
    """``(attachment_meta, fallback_text)`` for a verse share, or raises ``ShareRejected``."""
    if not isinstance(meta, dict):
        raise ShareRejected("bad_verse")
    book, chapter, verse = meta.get("book"), _int(meta.get("chapter")), _int(meta.get("verse"))
    end = meta.get("verse_end")
    end = verse if end is None else _int(end)
    if chapter is None or verse is None or end is None:
        raise ShareRejected("bad_verse")
    if end < verse or end - verse + 1 > _config()["verse_max_range"]:
        raise ShareRejected("bad_verse_range")
    if not (is_valid_reference(book, chapter, verse) and is_valid_reference(book, chapter, end)):
        raise ShareRejected("bad_verse")
    parts = []
    for v in range(verse, end + 1):
        t = verse_text(book, chapter, v)
        if not t:
            raise ShareRejected("verse_text_unavailable")
        parts.append(t.strip())
    text = " ".join(parts)
    ref = f"{book} {chapter}:{verse}" + (f"-{end}" if end != verse else "")
    out = {"book": book, "chapter": chapter, "verse": verse, "verse_end": end,
           "reference": ref, "text": text, "translation": "WEB"}
    return out, f"“{text}” — {ref}"


def sender_may_share_note(mgr, sender_id: str, note: dict) -> bool:
    """Authorization rule for putting ``note`` into a chat. Deny by default."""
    if not note or note.get("is_reply"):
        return False
    if str(note.get("user_id") or "").lower() == sender_id:
        return True
    group_id = note.get("group_id")
    if group_id and note.get("public") is True:
        return sender_id in live_member_ids(mgr.cur, str(group_id))
    return False


def _load_note(mgr, note_id: str) -> dict | None:
    found = mgr.lookup("notes", {"_id": note_id})
    if not found:
        return None
    return list(found.values())[0]


def build_note(mgr, sender_id: str, meta) -> tuple[dict, str]:
    """``(attachment_meta, fallback_text)`` for a note share, or raises ``ShareRejected``."""
    nid = _canon(meta.get("note_id")) if isinstance(meta, dict) else None
    if nid is None:
        raise ShareRejected("bad_note")
    note = _load_note(mgr, nid)
    if note is None or not sender_may_share_note(mgr, sender_id, note):
        raise ShareRejected("note_not_shareable")  # uniform: missing and forbidden look the same
    cfg = _config()
    title = _clip(note.get("title"), cfg["note_title_max_chars"]) or "Untitled note"
    ts = note.get("timestamp") or note.get("created_at")
    owner = str(note.get("user_id") or "").lower()
    mgr.cur.execute("SELECT username FROM users WHERE _id = %s::uuid", (owner,))
    row = mgr.cur.fetchone()
    out = {
        "note_id": nid,
        "title": title,
        "preview": _clip(note.get("text"), cfg["note_preview_max_chars"]),
        "timestamp": ts.isoformat() if hasattr(ts, "isoformat") else str(ts or ""),
        "is_group_note": bool(note.get("group_id")),
        "owner_username": row[0] if row else "",
        "owner_id": owner,
    }
    return out, f"Shared a note: {title}"


def resolve_share(mgr, sender_id: str, kind: str, client_meta) -> tuple[dict, str]:
    """Server-built ``(attachment_meta, fallback_text)`` for a shared kind."""
    if kind == KIND_VERSE:
        return build_verse(client_meta)
    if kind == KIND_NOTE:
        return build_note(mgr, sender_id, client_meta)
    raise ShareRejected("unknown_kind")


class SharedNoteReader(MessageReactionsManager):
    """Read-only access to a note through the chat message that shares it."""

    def open_note(self, message_id: str) -> dict | None:
        uid, mid = _canon(self.user_id), _canon(message_id)
        if not (uid and mid):
            return None
        try:
            if self._resolve(uid, mid) is None:
                return None
            self.cur.execute(
                "SELECT attachment_kind, attachment_meta, from_user::text FROM messages "
                "WHERE _id = %s::uuid AND deleted_at IS NULL", (mid,),
            )
            row = self.cur.fetchone()
            if not row or row[0] != KIND_NOTE or not row[2]:
                return None
            sender = row[2].lower()
            nid = _canon((row[1] or {}).get("note_id"))
            if nid is None:
                return None
            note = _load_note(self, nid)
            # Re-check at read time that the sender could still share this note.
            if note is None or not sender_may_share_note(self, sender, note):
                return None
            self.cur.execute(
                "SELECT book, chapter::text, verse::text FROM note_verses WHERE note_id = %s::uuid ORDER BY position",
                (nid,),
            )
            verses = [[r[0], r[1], r[2]] for r in self.cur.fetchall()]
            owner = str(note.get("user_id") or "")
            self.cur.execute("SELECT username FROM users WHERE _id = %s::uuid", (owner,))
            u = self.cur.fetchone()
            sent_by = None
            if sender != owner.lower():
                self.cur.execute("SELECT username FROM users WHERE _id = %s::uuid", (sender,))
                s = self.cur.fetchone()
                sent_by = s[0] if s else None
            return {
                "read_only": True,
                "note_id": nid,
                "user": owner,
                "username": u[0] if u else "",
                "title": note.get("title"),
                "text": note.get("text"),
                "is_group_note": bool(note.get("group_id")),
                "timestamp": str(note.get("timestamp") or ""),
                "created_at": str(note.get("created_at") or ""),
                "verses": verses,
                "replies": [],
                "shared_by": sent_by,
            }
        finally:
            self.conn.rollback()  # read-only; release the snapshot
