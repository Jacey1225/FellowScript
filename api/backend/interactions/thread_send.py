"""WebSocket send path for thread messages (flag ``threads``).

Client frame (on the user's one existing socket):
``{type: 'thread_message', thread_id, text, client_ref?, attachment_kind?,
attachment_key?, attachment_meta?}``. It is reached through ONE dispatch branch
in ``routes/messaging.py``; ``ConnectionManager.send_msg`` is not edited. The
group and the recipients are derived server-side from ``thread_id`` through the
shared ``send_guard`` helpers (``resolve_main_chat_recipients``,
``validate_attachment_key``); a client-supplied ``group_id`` / ``to_users`` /
``from_user`` is never read (``from_user`` is already overwritten with the
session user by the endpoint).

Order of checks (every denial is fail-closed and nothing is stored):
flag, frame shape, per-user rate limit, thread + membership + suspension,
current terms, attachment-key ownership, content filter, blocked set, save.
Replies go only to the sender's own socket as ``{type: 'error', reason,
detail}``: ``not_allowed`` (one uniform reason for flag off, bad shape, unknown
thread, non-member, suspended, foreign attachment key), ``rate_limited``,
``terms_reaccept_required``, ``message_rejected`` (content filter),
``send_failed`` (retriable infrastructure failure, e.g. the guard could not
read the database) and ``message_not_saved``.

Persistence is ONE statement through ``ConnectionManager._execute`` (the
reconnect-and-retry wrapper): insert the row, bump ``threads.last_activity_at``
and add the sender to ``thread_followers`` atomically.

Delivery: the live frame ``{type: 'thread_message', thread_id, group_id, id,
sender, body, created_at, seq, attachment_kind, attachment_meta,
attachment_url}`` carries a ``type`` and deliberately has neither ``from_user``
nor ``text``, so clients that render any frame with that pair (build 78, the
previous web bundle) ignore it. It goes to every online current member except
the sender and anyone in a block relationship with the sender. Push goes only
to FOLLOWERS who are offline, not blocked, not group-muted and not the sender
(the mute lookup fails open, like ``send_msg``). Logs carry ids only, never
text; expected denials are INFO.
"""
from __future__ import annotations

import json
import logging
import uuid

import psycopg2
from fastapi import HTTPException
from limits import parse as parse_rate

from backend import content_store
from backend.errors import SaveFailedError
from backend.interactions import flags
from backend.interactions.attachments import generate_download_url
from backend.interactions.paging import format_timestamp
from backend.interactions.push import send_push
from backend.interactions.send_guard import resolve_main_chat_recipients, validate_attachment_key
from backend.interactions.threads import canon
from backend.interactions.threads_config import get_threads_config
from backend.interactions.websockets import _ATTACHMENT_PUSH_LABELS, _GuardCursor, valid_client_ref
from backend.auth.terms import TERMS_REACCEPT_CODE, require_current_terms
from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message
from backend.rate_limiting import limiter
from schemas.message import ATTACHMENT_KINDS

logger = logging.getLogger(__name__)

_RATE_SCOPE = "thread-send"

_INSERT_SQL = (
    "WITH ins AS ("
    " INSERT INTO thread_messages (_id, thread_id, from_user, text, attachment_kind, attachment_key, attachment_meta) "
    " VALUES (%s::uuid, %s::uuid, %s::uuid, %s, %s, %s, %s::jsonb) RETURNING _id, created_at, seq), "
    "bump AS (UPDATE threads SET last_activity_at = (SELECT created_at FROM ins) WHERE _id = %s::uuid), "
    "fol AS (INSERT INTO thread_followers (thread_id, user_id) VALUES (%s::uuid, %s::uuid) ON CONFLICT DO NOTHING) "
    "SELECT _id::text, created_at, seq FROM ins"
)


async def _reply(manager, sender: str, reason: str, detail: str) -> None:
    ws = manager.active_connections.get(sender)
    if ws is None:
        return
    try:
        await ws.send_json({"type": "error", "reason": reason, "detail": detail})
    except Exception as e:  # noqa: BLE001
        logger.warning("Thread error frame to %s failed: %s", sender, type(e).__name__)


def _deny(sender: str, thread_id, cause: str) -> None:
    logger.info("thread_send rejected sender=%s thread=%s cause=%s", sender, thread_id or "-", cause)


def _parse_frame(payload: dict) -> "dict | None":
    """Validated, normalised copy of the client frame, or None when malformed."""
    thread_id = canon(payload.get("thread_id"))
    text = payload.get("text", "")
    if text is None:
        text = ""
    if thread_id is None or not isinstance(text, str) or "\x00" in text:
        return None
    kind = payload.get("attachment_kind")
    key = payload.get("attachment_key")
    meta = payload.get("attachment_meta") or {}
    if kind is None:
        key, meta = None, {}
    else:
        if kind not in ATTACHMENT_KINDS or not isinstance(meta, dict):
            return None
        if kind == "gif":
            if not meta.get("url"):
                return None
            key = None
        elif not isinstance(key, str) or not key:
            return None
    if not text.strip() and kind is None:
        return None  # nothing to send
    if kind == "file" and not isinstance(meta.get("filename", ""), str):
        return None
    try:
        if "\\u0000" in json.dumps(meta):
            return None
    except (TypeError, ValueError):
        return None
    return {"thread_id": thread_id, "text": text, "kind": kind, "key": key, "meta": meta}


async def send_thread_message(manager, payload: dict) -> None:
    """Handle one ``thread_message`` frame from ``payload['from_user']``.

    Never raises into the socket loop for an expected failure; the sender is
    told over their own socket.
    """
    sender = payload.get("from_user", "")
    sender_id = canon(sender)
    if sender_id is None or not flags.is_enabled("threads", sender):
        _deny(sender, None, "flag_off_or_bad_sender")
        await _reply(manager, sender, "not_allowed", "Couldn't send your message.")
        return
    frame_in = _parse_frame(payload)
    if frame_in is None:
        _deny(sender, None, "bad_frame")
        await _reply(manager, sender, "not_allowed", "Couldn't send your message.")
        return
    thread_id, text = frame_in["thread_id"], frame_in["text"]
    kind, key, meta = frame_in["kind"], frame_in["key"], frame_in["meta"]

    cfg = get_threads_config()
    if not limiter.limiter.hit(parse_rate(cfg.send_rate), _RATE_SCOPE, sender_id):
        _deny(sender, thread_id, "rate_limited")
        await _reply(manager, sender, "rate_limited", "You're sending messages too quickly. Please wait a moment.")
        return

    # Thread -> its own group (never client-supplied), membership, suspension,
    # terms. Any infrastructure failure is the retriable send_failed.
    cur = _GuardCursor(manager)
    try:
        manager._execute("SELECT group_id::text FROM threads WHERE _id = %s::uuid", (thread_id,))
        row = manager.cur.fetchone()
        recipients = resolve_main_chat_recipients(cur, sender_id, row[0]) if row else None
        if recipients is not None:
            try:
                require_current_terms(cur, sender_id)
            except HTTPException as e:
                if isinstance(e.detail, dict) and e.detail.get("code") == TERMS_REACCEPT_CODE:
                    _deny(sender, thread_id, "terms")
                    await _reply(manager, sender, TERMS_REACCEPT_CODE,
                                 "Please review and accept the updated Terms to continue.")
                    return
                raise
    except Exception as e:  # noqa: BLE001 - fail closed
        logger.warning("thread_send guard failed closed: %s", type(e).__name__)
        await _reply(manager, sender, "send_failed", "Couldn't send your message. Please try again.")
        return
    if row is None or recipients is None:
        _deny(sender, thread_id, "not_member_or_unknown_thread")
        await _reply(manager, sender, "not_allowed", "Couldn't send your message.")
        return
    group_id = row[0]

    if not validate_attachment_key(sender_id, kind, key):
        _deny(sender, thread_id, "bad_attachment_key")
        await _reply(manager, sender, "not_allowed", "Couldn't send your message.")
        return

    try:
        check_clean(text=text, attachment_filename=meta.get("filename") if kind == "file" else None)
    except ContentRejected as e:
        await _reply(manager, sender, "message_rejected", rejection_message(e))
        return

    try:
        manager._execute(
            "SELECT blocked_id::text FROM blocked_users WHERE blocker_id = %s::uuid "
            "UNION SELECT blocker_id::text FROM blocked_users WHERE blocked_id = %s::uuid",
            (sender_id, sender_id),
        )
        blocked = {str(r[0]).lower() for r in manager.cur.fetchall()}
    except Exception as e:  # noqa: BLE001 - fail closed, nothing saved
        logger.error("Thread blocked-relationship check failed: %s", type(e).__name__)
        await _reply(manager, sender, "send_failed", "Couldn't send your message. Please try again.")
        return

    new_mid = str(uuid.uuid4())  # chosen here: part of the encryption AAD
    try:
        manager._execute(
            _INSERT_SQL,
            (new_mid, thread_id, sender_id, content_store.seal(new_mid, content_store.F_THREAD_MESSAGE_TEXT, text),
             kind, key, json.dumps(meta), thread_id, thread_id, sender_id),
        )
        saved = manager.cur.fetchone()
        if saved is None:
            raise SaveFailedError()
    except SaveFailedError as e:
        await _reply(manager, sender, "message_not_saved", e.message)
        return
    except Exception as e:  # noqa: BLE001 - e.g. the thread was removed with its group meanwhile
        if isinstance(e, (psycopg2.InterfaceError, psycopg2.OperationalError)):
            logger.error("Thread message insert failed after reconnect retry: %s", type(e).__name__)
        else:
            logger.warning("Thread message insert failed: %s", type(e).__name__)
        await _reply(manager, sender, "message_not_saved", SaveFailedError().message)
        return
    message_id, created_at, seq = saved[0], format_timestamp(saved[1]), int(saved[2])

    client_ref = valid_client_ref(payload.get("client_ref"))
    if client_ref is not None:
        ws = manager.active_connections.get(sender)
        if ws is not None:
            try:
                await ws.send_json({
                    "type": "ack", "client_ref": client_ref, "id": message_id,
                    "group_id": group_id, "thread_id": thread_id, "timestamp": created_at,
                })
            except Exception as e:  # noqa: BLE001
                logger.warning("Thread ack send to %s failed: %s", sender, type(e).__name__)

    await _deliver(manager, sender_id, sender, group_id, thread_id, recipients, blocked, {
        "message_id": message_id, "created_at": created_at, "seq": seq,
        "text": text, "kind": kind, "key": key, "meta": meta,
    })


async def _deliver(manager, sender_id, sender, group_id, thread_id, recipients, blocked, msg) -> None:
    """Live frames to online members, push to offline followers. Best effort."""
    sender_name = "FellowScript"
    try:
        manager._execute("SELECT username FROM users WHERE _id = %s::uuid", (sender_id,))
        r = manager.cur.fetchone()
        if r:
            sender_name = r[0]
    except Exception as e:  # noqa: BLE001
        logger.warning("Could not resolve thread sender username: %s", type(e).__name__)

    targets = [u for u in recipients if u != sender_id and u not in blocked]
    frame = {
        "type": "thread_message",
        "thread_id": thread_id,
        "group_id": group_id,
        "id": msg["message_id"],
        "sender": sender_name,
        "body": msg["text"],
        "created_at": msg["created_at"],
        "seq": msg["seq"],
        "attachment_kind": msg["kind"],
        "attachment_meta": msg["meta"],
        "attachment_url": generate_download_url(msg["key"]) if msg["key"] else None,
    }

    # Push candidates: followers among the targets, minus muted. Looked up only
    # when someone is offline.
    followers: set[str] = set()
    tokens: dict[str, str] = {}
    muted: set[str] = set()
    offline_possible = any(manager.active_connections.get(u) is None for u in targets)
    if offline_possible:
        try:
            manager._execute("SELECT user_id::text FROM thread_followers WHERE thread_id = %s::uuid", (thread_id,))
            followers = {str(r[0]).lower() for r in manager.cur.fetchall()} & set(targets)
        except Exception as e:  # noqa: BLE001
            logger.warning("Thread follower lookup failed: %s", type(e).__name__)
        if followers:
            try:
                manager._execute(
                    "SELECT user_id::text, token FROM device_tokens WHERE user_id = ANY(%s::uuid[])",
                    (list(followers),),
                )
                tokens = {str(r[0]).lower(): r[1] for r in manager.cur.fetchall()}
            except Exception as e:  # noqa: BLE001
                logger.error("Thread device-token lookup failed: %s", type(e).__name__)
            try:
                manager._execute(
                    "SELECT user_id::text FROM group_mutes WHERE group_id = %s::uuid AND user_id = ANY(%s::uuid[])",
                    (group_id, list(followers)),
                )
                muted = {str(r[0]).lower() for r in manager.cur.fetchall()}
            except Exception as e:  # noqa: BLE001 - fails open (a muted follower may get a push)
                logger.warning("Thread group-mute lookup failed: %s", type(e).__name__)

    if msg["text"]:
        body = msg["text"] if len(msg["text"]) <= 100 else msg["text"][:97] + "…"
    else:
        body = _ATTACHMENT_PUSH_LABELS.get(msg["kind"], "")
    push_data = {"action": "thread_message", "group_id": group_id, "thread_id": thread_id}

    for uid in targets:
        ws = manager.active_connections.get(uid)
        if ws is not None:
            try:
                await ws.send_json(frame)
                continue
            except Exception as e:  # noqa: BLE001 - stale socket: evict, fall through to push
                logger.warning("Thread frame to %s failed, evicting stale connection: %s", uid, type(e).__name__)
                manager.active_connections.pop(uid, None)
        token = tokens.get(uid)
        if uid in followers and token and uid not in muted:
            try:
                await send_push(token, sender_name, body, data=push_data)
            except Exception as e:  # noqa: BLE001
                logger.error("Thread push to %s failed: %s", uid, type(e).__name__)
