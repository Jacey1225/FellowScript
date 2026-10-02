"""Push notifications for join requests (flag ``join_request_push``).

Modeled on ``announcement_notifier.py``: a post-commit ``BackgroundTask`` per
event, an atomic single-winner claim before the send, mute respected (a mute
lookup failure fails OPEN), per-recipient isolation, and nothing ever raises
out of the public coroutines.

Two pushes only:

- ``notify_owner_of_request(request_id)``: the owner hears about a new request.
  One push per group per ``notify_window_minutes``: the claim is an atomic
  ``UPDATE ... SET owner_notified_at`` guarded by ``NOT EXISTS`` of a claim in
  the window, serialised per group by an advisory lock so two concurrent
  requests cannot both win. A request that arrives inside the window is not
  pushed (the owner list and the pending count still show it).
- ``notify_requester_approved(request_id)``: the applicant hears the request was
  approved. Denial, expiry and withdrawal are never pushed.

Both are gated by ``flags.is_enabled('join_request_push', owner_id)``: the flag
is evaluated for the OWNER, and the claim is taken only after every eligibility
check passed so a flag-off or no-token run never burns the window.

Privacy (analysis ``reading_and_privacy_rules``): alert text is generic and
names no applicant, note or request id; the owner's alert title is the group's
own title (an owner-facing surface). The payload carries ``action`` and
``group_id`` only. Log lines carry counts only: no usernames, notes, titles or
ids; the bare word ERROR never appears (watchdog rule).

R-SCHED: the public functions are ``async def``; all psycopg2 work runs through
``loop.run_in_executor`` in plain sync helpers that open and close their own
``DBManager``.
"""
from __future__ import annotations

import asyncio
import logging

from backend.interactions import flags
from backend.interactions.join_requests import canon
from backend.interactions.join_requests_config import get_join_requests_config
from db import DBManager

logger = logging.getLogger(__name__)

PUSH_ACTION = "join_request"
TITLE_MAX = 60
OWNER_BODY = "New request to join your group"
APPROVED_BODY = "Your request to join was approved"


def _truncate(text: str, limit: int = TITLE_MAX) -> str:
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _token(db: DBManager, user_id: str) -> str | None:
    db.cur.execute("SELECT token FROM device_tokens WHERE user_id = %s", (user_id,))
    row = db.cur.fetchone()
    return row[0] if row and row[0] else None


def _owner_present(db: DBManager, group_id: str, owner_id: str) -> bool:
    """Owner exists, is not suspended and is a current member."""
    db.cur.execute(
        "SELECT 1 FROM groups g JOIN users u ON u._id = g.creator_id "
        "WHERE g._id = %s AND g.creator_id = %s AND u.suspended_at IS NULL "
        "AND %s = ANY(COALESCE(g.users, '{}'))",
        (group_id, owner_id, owner_id),
    )
    return db.cur.fetchone() is not None


def _owner_muted(db: DBManager, group_id: str, owner_id: str) -> bool:
    """Mute is a comfort preference, so a lookup failure fails open."""
    try:
        db.cur.execute(
            "SELECT 1 FROM group_mutes WHERE group_id = %s AND user_id = %s", (group_id, owner_id)
        )
        muted = db.cur.fetchone() is not None
        db.conn.rollback()
        return muted
    except Exception:  # noqa: BLE001
        db.conn.rollback()
        return False


def _prepare_owner_push(request_id: str) -> dict | None:
    """Everything the owner push needs (claim taken last), or None."""
    rid = canon(request_id)
    if rid is None:
        return None
    window = get_join_requests_config().notify_window_minutes
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT r.group_id::text, g.creator_id::text, g.title FROM group_join_requests r "
            "JOIN groups g ON g._id = r.group_id WHERE r.id = %s AND r.status = 'pending'",
            (rid,),
        )
        row = db.cur.fetchone()
        db.conn.rollback()
        if row is None or row[1] is None:
            return None
        group_id, owner_id, title = row
        if not flags.is_enabled("join_request_push", owner_id):
            return None
        if not _owner_present(db, group_id, owner_id):
            db.conn.rollback()
            return None
        db.conn.rollback()
        if _owner_muted(db, group_id, owner_id):
            return None
        token = _token(db, owner_id)
        db.conn.rollback()
        if token is None:
            return None
        # Atomic claim: one push per group per window, serialised per group.
        db.cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (f"jrq-notify:{group_id}",))
        db.cur.execute(
            "UPDATE group_join_requests SET owner_notified_at = NOW() "
            "WHERE id = %s AND status = 'pending' AND owner_notified_at IS NULL "
            "AND NOT EXISTS (SELECT 1 FROM group_join_requests o WHERE o.group_id = %s "
            "AND o.owner_notified_at > NOW() - make_interval(mins => %s)) RETURNING 1",
            (rid, group_id, window),
        )
        claimed = db.cur.fetchone()
        db.conn.commit()
        if not claimed:
            return None
        return {"token": token, "title": _truncate(title or "Join request"), "body": OWNER_BODY,
                "data": {"action": PUSH_ACTION, "group_id": group_id}}
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


def _prepare_approved_push(request_id: str) -> dict | None:
    rid = canon(request_id)
    if rid is None:
        return None
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT r.user_id::text, r.group_id::text, g.creator_id::text, g.title "
            "FROM group_join_requests r JOIN groups g ON g._id = r.group_id "
            "WHERE r.id = %s AND r.status = 'approved'",
            (rid,),
        )
        row = db.cur.fetchone()
        db.conn.rollback()
        if row is None:
            return None
        applicant, group_id, owner_id, title = row
        if owner_id is None or not flags.is_enabled("join_request_push", owner_id):
            return None
        token = _token(db, applicant)
        db.conn.rollback()
        if token is None:
            return None
        return {"token": token, "title": _truncate(title or "Join request"), "body": APPROVED_BODY,
                "data": {"action": PUSH_ACTION, "group_id": group_id}}
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


async def _deliver(prepare, request_id: str, kind: str) -> None:
    from backend.interactions.push import send_push

    try:
        loop = asyncio.get_running_loop()
        prepared = await loop.run_in_executor(None, prepare, request_id)
        if not prepared:
            return
        try:
            ok = await send_push(prepared["token"], prepared["title"], prepared["body"], data=prepared["data"])
        except Exception as e:  # incl. APNsConfigError: isolated, counted, never raised
            logger.warning("JOIN_REQUEST_PUSH kind=%s sent=0 failed=1 reason=%s", kind, type(e).__name__)
            return
        if not ok:
            logger.warning("JOIN_REQUEST_PUSH kind=%s sent=0 failed=1", kind)
    except Exception as e:  # noqa: BLE001 - a notification must never break a request
        logger.warning("JOIN_REQUEST_PUSH kind=%s aborted reason=%s", kind, type(e).__name__)


async def notify_owner_of_request(request_id: str) -> None:
    """Background task after a request was created. Never raises."""
    await _deliver(_prepare_owner_push, request_id, "owner")


async def notify_requester_approved(request_id: str) -> None:
    """Background task after an approval that appended the member. Never raises."""
    await _deliver(_prepare_approved_push, request_id, "approved")
