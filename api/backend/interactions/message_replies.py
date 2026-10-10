"""Reply to a specific chat message (flag ``chat_replies``).

Scope: group messages and DMs (both live in ``messages``). Group thread
messages (``thread_messages`` has its own send path) are deferred.

Rules:
- The client sends only the target message id (``reply_to``). Only that id is
  stored on the new row. NOTHING of the original (text, author) is copied: the
  label is derived per response by joining to the original, so edits show and a
  hard-deleted original is retained nowhere.
- Deny by default and fail closed at send. The target must be in the SAME
  conversation as the new message, not soft-deleted, authored by the sender or by
  someone the sender can currently see (live group member / the other DM party,
  no block with the sender in either direction). Every refusal raises
  ``ReplyInvalid`` with no detail, so the sender cannot probe for ids,
  membership or state.
- Reads: ``attach_replies`` batches the lookups for every history path. When the
  original is missing, soft-deleted, outside the conversation, or its author has
  a block relationship with the viewer, the payload carries ``reply_to_deleted:
  true`` and no text or author. Flag off for the viewer omits every reply key.
- Logs carry ids only, never message text.
"""
from __future__ import annotations

import logging
import re
import uuid

from backend import content_store
from backend.interactions import flags

logger = logging.getLogger(__name__)

FLAG = "chat_replies"

MAX_SNIPPET_LENGTH = 200
MAX_AUTHOR_LENGTH = 100

_ATTACHMENT_LABELS = {"image": "Photo", "video": "Video", "file": "File", "gif": "GIF"}
_WHITESPACE = re.compile(r"\s+")


class ReplyInvalid(Exception):
    """The reply target is not acceptable. Carries no detail on purpose."""


def _canon(value) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def make_snippet(text: str | None, attachment_kind: str | None) -> str:
    """One line, whitespace collapsed, at most ``MAX_SNIPPET_LENGTH`` characters
    (ellipsis included). A text-less attachment message gets its kind as label."""
    flat = _WHITESPACE.sub(" ", text or "").strip()
    if not flat:
        return _ATTACHMENT_LABELS.get(attachment_kind or "", "")
    if len(flat) > MAX_SNIPPET_LENGTH:
        flat = flat[: MAX_SNIPPET_LENGTH - 1].rstrip() + "…"
    return flat


def _blocked_between(cur, a: str, b: str) -> bool:
    cur.execute(
        "SELECT 1 FROM blocked_users WHERE (blocker_id = %s::uuid AND blocked_id = %s::uuid) "
        "OR (blocker_id = %s::uuid AND blocked_id = %s::uuid)",
        (a, b, b, a),
    )
    return cur.fetchone() is not None


def resolve_reply(cur, sender_id: str, group_id: str | None, recipients: list[str], target) -> dict:
    """Validate ``target`` for a new message and return its display values.

    ``cur`` is the send guard's cursor adapter (``execute/fetchone``). ``group_id``
    and ``recipients`` are the AUTHORIZED values from ``authorize_send`` (group:
    live member list; DM: exactly the other party). Returns the display values ``{"reply_to_id",
    "reply_to_text", "reply_to_author", "reply_to_author_id"}`` (not persisted). Raises
    ``ReplyInvalid`` for every refusal; other exceptions are infrastructure
    failures the caller reports as retriable.
    """
    tid = _canon(target)
    sender = _canon(sender_id)
    if tid is None or sender is None:
        raise ReplyInvalid()
    cur.execute(
        "SELECT from_user::text, group_id::text, text, attachment_kind FROM messages "
        "WHERE _id = %s::uuid AND deleted_at IS NULL",
        (tid,),
    )
    row = cur.fetchone()
    if not row or not row[0]:
        raise ReplyInvalid()
    author, target_group, stored_text, kind = row[0].lower(), row[1], row[2], row[3]

    if group_id:
        if target_group is None or target_group.lower() != str(group_id).lower():
            raise ReplyInvalid()
        members = {m.lower() for m in recipients}
        if sender not in members:
            raise ReplyInvalid()
        if author != sender and (author not in members or _blocked_between(cur, sender, author)):
            raise ReplyInvalid()
    else:
        if target_group is not None or len(recipients) != 1:
            raise ReplyInvalid()
        other = recipients[0].lower()
        if author not in (sender, other):
            raise ReplyInvalid()
        # The original must have been delivered within THIS pair (a DM to someone else is out).
        addressee = other if author == sender else sender
        cur.execute(
            "SELECT 1 FROM message_recipients WHERE message_id = %s::uuid AND user_id = %s::uuid",
            (tid, addressee),
        )
        if cur.fetchone() is None or _blocked_between(cur, sender, other):
            raise ReplyInvalid()

    cur.execute("SELECT username FROM users WHERE _id = %s::uuid", (author,))
    name_row = cur.fetchone()
    if not name_row or not name_row[0]:
        raise ReplyInvalid()
    try:
        text = content_store.open_(tid, content_store.F_MESSAGE_TEXT, stored_text)
    except content_store.ContentDecryptError:
        logger.warning("reply target undecryptable: message=%s", tid)
        raise ReplyInvalid()
    # Display values for the live frame / ack only; only ``reply_to_id`` is stored.
    return {
        "reply_to_id": tid,
        "reply_to_text": make_snippet(text, kind),
        "reply_to_author": str(name_row[0])[:MAX_AUTHOR_LENGTH],
        "reply_to_author_id": author,
    }


def public_fields(info: dict) -> dict:
    """Payload keys for a visible original (derived, never stored)."""
    return {
        "reply_to_id": info["reply_to_id"],
        "reply_to_text": info["reply_to_text"],
        "reply_to_author": info["reply_to_author"],
        "reply_to_author_id": info["reply_to_author_id"],
    }


def deleted_fields(reply_to_id: str | None) -> dict:
    """Payload keys when the original is unavailable to the viewer."""
    return {"reply_to_id": reply_to_id, "reply_to_deleted": True}


def blocked_with(cur, user_id: str) -> set[str]:
    """Lowercase ids with a block relationship to ``user_id`` in either direction."""
    cur.execute(
        "SELECT blocked_id::text FROM blocked_users WHERE blocker_id = %s::uuid "
        "UNION SELECT blocker_id::text FROM blocked_users WHERE blocked_id = %s::uuid",
        (user_id, user_id),
    )
    return {str(r[0]).lower() for r in cur.fetchall()}


def _visible_originals(cur, viewer: str, rows: list) -> dict[str, dict]:
    """``{reply_to_id: info}`` for the originals ``viewer`` may see. ``rows`` are
    ``(reply_to_id, group_id)`` pairs of the replies being rendered. One query
    for the originals, one for the block set, one per distinct group."""
    from backend.interactions.groups import live_member_ids  # lazy: groups imports this module
    targets = sorted({r[0] for r in rows})
    cur.execute(
        "SELECT t._id::text, t.from_user::text, t.group_id::text, t.text, t.attachment_kind, u.username, "
        "t.from_user = %s::uuid OR EXISTS (SELECT 1 FROM message_recipients mr "
        "WHERE mr.message_id = t._id AND mr.user_id = %s::uuid) "
        "FROM messages t LEFT JOIN users u ON u._id = t.from_user "
        "WHERE t._id = ANY(%s::uuid[]) AND t.deleted_at IS NULL",
        (viewer, viewer, targets),
    )
    found = {r[0]: r for r in cur.fetchall()}
    blocked = blocked_with(cur, viewer) if found else set()
    members: dict[str, set[str]] = {}
    out: dict[str, dict] = {}
    for tid, reply_group in rows:
        row = found.get(tid)
        if row is None or tid in out:
            continue
        _, author, group, text, kind, username, in_dm = row
        author = (author or "").lower()
        if not author or author in blocked or (group or "").lower() != (reply_group or "").lower():
            continue
        if group:
            if group not in members:
                members[group] = set(live_member_ids(cur, group))
            if author != viewer and author not in members[group]:
                continue
        elif not in_dm:
            continue
        try:
            plain = content_store.open_(tid, content_store.F_MESSAGE_TEXT, text)
        except content_store.ContentDecryptError:
            logger.warning("reply original undecryptable: message=%s", tid)
            continue
        out[tid] = {
            "reply_to_id": tid, "reply_to_text": make_snippet(plain, kind),
            "reply_to_author": (username or "")[:MAX_AUTHOR_LENGTH], "reply_to_author_id": author,
        }
    return out


def attach_replies(db, messages: list[dict], viewer_id: str) -> None:
    """Add the reply keys to every message dict (with an ``id``) that is a reply,
    in place, in a fixed number of queries (no per-message lookups). Non-replies
    are untouched, so old data keeps its shape. No-op while the flag is off for
    the viewer."""
    if not messages or not flags.is_enabled(FLAG, viewer_id):
        return
    viewer = _canon(viewer_id)
    ids = [i for i in (_canon(str(m["id"])) for m in messages if m.get("id")) if i]
    if viewer is None or not ids:
        return
    try:
        db.cur.execute(
            "SELECT _id::text, reply_to_id::text, group_id::text FROM messages "
            "WHERE _id = ANY(%s::uuid[]) AND reply_to_id IS NOT NULL",
            (ids,),
        )
        replies = {r[0].lower(): (r[1], r[2]) for r in db.cur.fetchall()}
        visible = _visible_originals(db.cur, viewer, list(replies.values())) if replies else {}
    finally:
        db.conn.rollback()  # read-only; release the snapshot
    for m in messages:
        pair = replies.get(str(m.get("id", "")).lower())
        if pair is None:
            continue
        info = visible.get(pair[0])
        m.update(public_fields(info) if info else deleted_fields(pair[0]))
