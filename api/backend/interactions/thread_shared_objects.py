"""Verse and note shares inside THREAD messages (task 20261030-thread-share-notes-verses).

Reuses ``shared_objects`` end to end; this module only adds the two thread-specific pieces.

Send side (``resolve_thread_share``): same server-built payload and fallback text as chat
(``shared_objects.resolve_share``), same ``chat_shared_objects`` flag (the ``threads`` flag is
checked by ``thread_send`` first). Refusals raise ``ShareRejected`` (the caller replies with the
uniform ``not_allowed``); nothing client-supplied is stored.

Read side (``thread_note_grant``): the thread message IS the grant, exactly like a chat message.
The viewer may read the note only when ALL hold, otherwise ``None`` (one uniform 404 at the route,
no oracle): the thread message exists, is not soft-deleted and is a ``shared_note``; the viewer is
a live, non-suspended member of the thread's group; the sender is still a live member of that
group; there is no block pair between viewer and sender; and the sender is still allowed to share
that note (``sender_may_share_note``, re-checked at read time). The permission rule itself is
unchanged. Read-only; logs carry ids only.
"""
from __future__ import annotations

import logging

from backend.interactions import flags
from backend.interactions import shared_objects
from backend.interactions.groups import live_member_ids
from backend.interactions.message_reactions import _canon

logger = logging.getLogger(__name__)


def resolve_thread_share(manager, sender_id: str, kind: str, client_meta) -> tuple[dict, str]:
    """Server-built ``(attachment_meta, fallback_text)`` for a share into a thread."""
    if not flags.is_enabled(shared_objects.FLAG, sender_id):
        raise shared_objects.ShareRejected("flag_off")
    return shared_objects.resolve_share(manager, sender_id, kind, client_meta)


def thread_note_grant(reader, uid: str, mid: str) -> "tuple[str, str] | None":
    """``(note_id, sender_id)`` when thread message ``mid`` grants ``uid`` a read of its shared
    note, else ``None``. ``reader`` is a ``SharedNoteReader`` (has ``cur`` and ``_blocked_with``).
    Does not load the note; the caller re-checks ``sender_may_share_note`` on it."""
    if not flags.is_enabled("threads", uid):
        return None
    reader.cur.execute(
        "SELECT t.group_id::text, tm.from_user::text, tm.attachment_kind, tm.attachment_meta "
        "FROM thread_messages tm JOIN threads t ON t._id = tm.thread_id "
        "WHERE tm._id = %s::uuid AND tm.deleted_at IS NULL",
        (mid,),
    )
    row = reader.cur.fetchone()
    if not row or row[2] != shared_objects.KIND_NOTE or not row[0] or not row[1]:
        return None
    group_id, sender = row[0], row[1].lower()
    members = live_member_ids(reader.cur, group_id)
    if uid not in members or sender not in members:
        return None
    reader.cur.execute("SELECT 1 FROM users WHERE _id = %s::uuid AND suspended_at IS NULL", (uid,))
    if reader.cur.fetchone() is None:
        return None
    if uid != sender and sender in reader._blocked_with(uid):
        return None
    meta = row[3] if isinstance(row[3], dict) else {}
    nid = _canon(meta.get("note_id"))
    if nid is None:
        return None
    return nid, sender
