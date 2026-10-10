"""Push notifications for message reactions and friend highlights
(task 20261010-reaction-highlight-push).

Two pushes, each behind its own flag (evaluated for the RECIPIENT, ships OFF):

- ``notify_message_reaction``: the author of a chat message hears that someone
  reacted. Never for a self-reaction, a soft-deleted message, a blocked pair
  (either direction), a suspended or muted-group recipient, or a removal.
  Coalescing is send-first-then-suppress: the first reaction claims the
  message's row in ``message_reaction_push_claims`` with one atomic upsert and
  pushes; reactions inside ``REACTION_COALESCE_SECONDS`` fail the claim and
  stay silent. The claim is durable and race-safe (single statement).
- ``notify_friend_highlight``: the highlighter's friends hear about the
  highlight. Recipients come from ``ActivityManager.friend_device_tokens``
  (friends with a token, blocks excluded both ways), are capped at
  ``MAX_FRIEND_RECIPIENTS`` per event, and must not have turned the setting off
  (``push_preferences.friend_highlight``, default on). At most one push per
  (highlighter, recipient) per hour via an atomic upsert on
  ``friend_highlight_push_claims``. Highlights have no private visibility in
  this codebase: they are already readable by accepted, unblocked friends
  (see highlight_search), so friends are the only audience.

Fail closed: any lookup error means no push. The claim is taken last, after
every eligibility check. Payloads carry identifiers only; the alert text is
name + emoji / name + reference. Logs carry counts and exception class names,
never names, emoji, references or ids. The public coroutines never raise and
run post-commit as BackgroundTasks, so a push failure never fails the request.
All psycopg2 work runs through ``run_in_executor`` in sync helpers that open
and close their own ``DBManager``.
"""
from __future__ import annotations

import asyncio
import logging
import uuid

from backend.interactions import flags
from db import DBManager

logger = logging.getLogger(__name__)

REACTION_FLAG = "message_reaction_push"
HIGHLIGHT_FLAG = "friend_highlight_push"
REACTION_ACTION = "message_reaction"
HIGHLIGHT_ACTION = "friend_highlight"
REACTION_COALESCE_SECONDS = 60
HIGHLIGHT_MIN_INTERVAL_SECONDS = 3600
MAX_FRIEND_RECIPIENTS = 200
NAME_MAX = 40


def _canon(value) -> str | None:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, AttributeError, TypeError):
        return None


def _clip(text: str, limit: int = NAME_MAX) -> str:
    text = (text or "").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


# -- reaction push --------------------------------------------------------------

def _prepare_reaction(message_id: str, reactor_id: str, emoji: str, group_id: str) -> dict | None:
    mid, reactor = _canon(message_id), _canon(reactor_id)
    if mid is None or reactor is None or not emoji:
        return None
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT m.from_user::text, m.group_id::text FROM messages m "
            "WHERE m._id = %s::uuid AND m.deleted_at IS NULL",
            (mid,),
        )
        row = db.cur.fetchone()
        if not row or not row[0]:
            db.conn.rollback()
            return None
        author, msg_group = row[0].lower(), row[1]
        if author == reactor or not flags.is_enabled(REACTION_FLAG, author):
            db.conn.rollback()
            return None
        db.cur.execute(
            "SELECT 1 FROM blocked_users WHERE (blocker_id = %s::uuid AND blocked_id = %s::uuid) "
            "OR (blocker_id = %s::uuid AND blocked_id = %s::uuid)",
            (author, reactor, reactor, author),
        )
        if db.cur.fetchone():
            db.conn.rollback()
            return None
        db.cur.execute(
            "SELECT u.username, (SELECT dt.token FROM device_tokens dt WHERE dt.user_id = %s::uuid) "
            "FROM users u WHERE u._id = %s::uuid",
            (author, reactor),
        )
        name_row = db.cur.fetchone()
        db.cur.execute(
            "SELECT 1 FROM users WHERE _id = %s::uuid AND suspended_at IS NULL", (author,),
        )
        author_ok = db.cur.fetchone() is not None
        if not name_row or not name_row[0] or not name_row[1] or not author_ok:
            db.conn.rollback()
            return None
        if msg_group:
            # Same comfort rule as chat push: a muted group stays silent.
            try:
                db.cur.execute(
                    "SELECT 1 FROM group_mutes WHERE group_id = %s::uuid AND user_id = %s::uuid",
                    (msg_group, author),
                )
                if db.cur.fetchone():
                    db.conn.rollback()
                    return None
            except Exception:  # noqa: BLE001 - mute lookup failing fails open (comfort pref)
                db.conn.rollback()
        db.conn.rollback()
        # Atomic claim, taken last: only the first reaction per window wins.
        db.cur.execute(
            "INSERT INTO message_reaction_push_claims (message_id, last_pushed_at) "
            "VALUES (%s::uuid, NOW()) ON CONFLICT (message_id) DO UPDATE SET last_pushed_at = NOW() "
            "WHERE message_reaction_push_claims.last_pushed_at < NOW() - make_interval(secs => %s) "
            "RETURNING 1",
            (mid, REACTION_COALESCE_SECONDS),
        )
        claimed = db.cur.fetchone()
        db.conn.commit()
        if not claimed:
            return None
        return {
            "token": name_row[1],
            "title": "New reaction",
            "body": f"{_clip(name_row[0])} reacted {emoji} to your message",
            "data": {"action": REACTION_ACTION, "group_id": group_id, "message_id": mid},
        }
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


async def notify_message_reaction(message_id: str, reactor_id: str, emoji: str, group_id: str) -> None:
    """Background task after a reaction was newly added. Never raises."""
    from backend.interactions.push import send_push

    try:
        loop = asyncio.get_running_loop()
        prepared = await loop.run_in_executor(
            None, _prepare_reaction, message_id, reactor_id, emoji, group_id,
        )
        if not prepared:
            return
        try:
            ok = await send_push(prepared["token"], prepared["title"], prepared["body"], data=prepared["data"])
        except Exception as e:  # noqa: BLE001 - incl. APNsConfigError: isolated, never raised
            logger.warning("REACTION_PUSH sent=0 failed=1 reason=%s", type(e).__name__)
            return
        if not ok:
            logger.warning("REACTION_PUSH sent=0 failed=1")
    except Exception as e:  # noqa: BLE001 - a notification must never break a request
        logger.warning("REACTION_PUSH aborted reason=%s", type(e).__name__)


# -- friend highlight push ------------------------------------------------------

def _prepare_highlights(highlighter_id: str, book: str, chapter: int, verse: int) -> list[dict]:
    hid = _canon(highlighter_id)
    if hid is None:
        return []
    from backend.interactions.activity import ActivityManager

    am = ActivityManager()
    try:
        candidates = am.friend_device_tokens(hid)  # blocks excluded both ways
        am.conn.rollback()
        db = am
        db.cur.execute("SELECT username FROM users WHERE _id = %s::uuid AND suspended_at IS NULL", (hid,))
        row = db.cur.fetchone()
        db.conn.rollback()
        if not row or not row[0]:
            return []
        name = _clip(row[0])
        recipients: dict[str, str] = {}
        for friend_id, token in candidates:
            fid = _canon(friend_id)
            if fid and token and fid != hid and fid not in recipients:
                recipients[fid] = token
            if len(recipients) >= MAX_FRIEND_RECIPIENTS:
                break
        if not recipients:
            return []
        db.cur.execute(
            "SELECT user_id::text FROM push_preferences "
            "WHERE user_id = ANY(%s::uuid[]) AND friend_highlight = FALSE",
            (list(recipients),),
        )
        opted_out = {r[0].lower() for r in db.cur.fetchall()}
        db.cur.execute(
            "SELECT _id::text FROM users WHERE _id = ANY(%s::uuid[]) AND suspended_at IS NULL",
            (list(recipients),),
        )
        active = {r[0].lower() for r in db.cur.fetchall()}
        db.conn.rollback()
        out: list[dict] = []
        reference = f"{book} {chapter}:{verse}"
        for rid, token in recipients.items():
            if rid in opted_out or rid not in active or not flags.is_enabled(HIGHLIGHT_FLAG, rid):
                continue
            # Atomic claim per pair, taken last: one push per hour.
            db.cur.execute(
                "INSERT INTO friend_highlight_push_claims (highlighter_id, recipient_id, last_pushed_at) "
                "VALUES (%s::uuid, %s::uuid, NOW()) "
                "ON CONFLICT (highlighter_id, recipient_id) DO UPDATE SET last_pushed_at = NOW() "
                "WHERE friend_highlight_push_claims.last_pushed_at < NOW() - make_interval(secs => %s) "
                "RETURNING 1",
                (hid, rid, HIGHLIGHT_MIN_INTERVAL_SECONDS),
            )
            claimed = db.cur.fetchone()
            db.conn.commit()
            if not claimed:
                continue
            out.append({
                "token": token,
                "title": "Friend highlight",
                "body": f"{name} highlighted {reference}",
                "data": {"action": HIGHLIGHT_ACTION, "friend_id": hid, "book": book,
                         "chapter": chapter, "verse": verse},
            })
        return out
    except Exception:
        am.conn.rollback()
        raise
    finally:
        am.close()


async def notify_friend_highlight(highlighter_id: str, book: str, chapter: int, verse: int) -> None:
    """Background task after a highlight was saved. Never raises."""
    from backend.interactions.push import send_push

    try:
        loop = asyncio.get_running_loop()
        batch = await loop.run_in_executor(
            None, _prepare_highlights, highlighter_id, book, chapter, verse,
        )
        sent = failed = 0
        for item in batch:
            try:
                ok = await send_push(item["token"], item["title"], item["body"], data=item["data"])
            except Exception as e:  # noqa: BLE001 - isolate per recipient
                logger.warning("HIGHLIGHT_PUSH recipient failed reason=%s", type(e).__name__)
                ok = False
            sent, failed = (sent + 1, failed) if ok else (sent, failed + 1)
        if batch:
            logger.info("HIGHLIGHT_PUSH sent=%d failed=%d", sent, failed)
    except Exception as e:  # noqa: BLE001 - a notification must never break a request
        logger.warning("HIGHLIGHT_PUSH aborted reason=%s", type(e).__name__)
