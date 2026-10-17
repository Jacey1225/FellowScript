"""Essential push to the recipient of a new friend request (task 20261016).

Always sent: it never consults ``push_preferences``. The sender gets nothing.
Alert text is generic (no sender name, so nothing identifying transits APNs);
the payload carries only ``action``. Skipped for a missing token, a suspended
recipient, or a blocked relationship in either direction. Run as a post-commit
``BackgroundTask``: nothing ever raises out of ``notify_friend_request``, so a
push problem can never fail the request. Log lines carry no ids or names.
"""
from __future__ import annotations

import asyncio
import logging

from db import DBManager

logger = logging.getLogger(__name__)

PUSH_ACTION = "friend_request"
TITLE = "New friend request"
BODY = "Someone sent you a friend request"


def _prepare(recipient_id: str, sender_id: str) -> str | None:
    """Device token to push, or None when nothing should be sent."""
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT dt.token FROM users u JOIN device_tokens dt ON dt.user_id = u._id "
            "WHERE u._id = %s AND u.suspended_at IS NULL "
            "AND NOT EXISTS (SELECT 1 FROM blocked_users b WHERE "
            "(b.blocker_id = u._id AND b.blocked_id = %s) OR (b.blocker_id = %s AND b.blocked_id = u._id))",
            (recipient_id, sender_id, sender_id),
        )
        row = db.cur.fetchone()
        db.conn.rollback()
        return row[0] if row and row[0] else None
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


async def notify_friend_request(recipient_id: str, sender_id: str) -> None:
    """Background task after a friend request was stored. Never raises."""
    from backend.interactions.push import send_push

    try:
        loop = asyncio.get_running_loop()
        token = await loop.run_in_executor(None, _prepare, recipient_id, sender_id)
        if not token:
            return
        try:
            ok = await send_push(token, TITLE, BODY, data={"action": PUSH_ACTION})
        except Exception as e:  # noqa: BLE001 - incl. APNsConfigError: isolated, never raised
            logger.warning("FRIEND_REQUEST_PUSH sent=0 failed=1 reason=%s", type(e).__name__)
            return
        if not ok:
            logger.warning("FRIEND_REQUEST_PUSH sent=0 failed=1")
    except Exception as e:  # noqa: BLE001 - a notification must never break a request
        logger.warning("FRIEND_REQUEST_PUSH aborted reason=%s", type(e).__name__)
