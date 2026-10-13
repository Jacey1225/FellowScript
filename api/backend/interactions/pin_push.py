"""Push for a newly pinned message (task 20261012-message-pins).

Sent to the other chat members (never the pinner) when the pin throttle claim
succeeded (see ``MessagePinsManager.pin``), so pin/unpin churn does not spam.
Eligibility per recipient, fail closed: ``message_pins`` flag on for the
recipient, not suspended, has a device token, no block with the pinner in
either direction, and for a group not muted (same comfort rule as chat push).
Content policy: the alert is "<pinner name> pinned a message", never the
message text or an attachment label (less than chat push reveals). Payload
carries identifiers only and reuses the chat-push deep link
(``action: "message"`` + ``group_id``). Logs carry counts and exception class
names only. The coroutine never raises and runs post-commit as a
BackgroundTask; psycopg2 work runs in an executor helper that opens and
closes its own ``DBManager``.
"""
from __future__ import annotations

import asyncio
import logging

from backend.interactions import flags
from backend.interactions.message_reactions import _canon
from backend.interactions.push_preferences import disabled_user_ids
from db import DBManager

logger = logging.getLogger(__name__)

FLAG = "message_pins"
NAME_MAX = 40


def _clip(text: str, limit: int = NAME_MAX) -> str:
    text = (text or "").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _prepare(chat_key: str, pinner_id: str, message_id: str, recipients: list[str]) -> list[dict]:
    pinner = _canon(pinner_id)
    mid = _canon(message_id)
    ids = [r for r in (_canon(x) for x in recipients) if r and r != pinner]
    if not pinner or not mid or not ids:
        return []
    db = DBManager()
    try:
        db.cur.execute("SELECT username FROM users WHERE _id = %s::uuid AND suspended_at IS NULL", (pinner,))
        row = db.cur.fetchone()
        if not row or not row[0]:
            return []
        name = _clip(row[0])
        db.cur.execute(
            "SELECT u._id::text, dt.token FROM users u JOIN device_tokens dt ON dt.user_id = u._id "
            "WHERE u._id = ANY(%s::uuid[]) AND u.suspended_at IS NULL",
            (ids,),
        )
        tokens = {r[0].lower(): r[1] for r in db.cur.fetchall() if r[1]}
        db.cur.execute(
            "SELECT blocked_id::text FROM blocked_users WHERE blocker_id = %s::uuid "
            "UNION SELECT blocker_id::text FROM blocked_users WHERE blocked_id = %s::uuid",
            (pinner, pinner),
        )
        blocked = {r[0].lower() for r in db.cur.fetchall()}
        muted: set[str] = set()
        if "|" not in chat_key:
            try:
                db.cur.execute(
                    "SELECT user_id::text FROM group_mutes WHERE group_id = %s::uuid AND user_id = ANY(%s::uuid[])",
                    (chat_key, ids),
                )
                muted = {r[0].lower() for r in db.cur.fetchall()}
            except Exception:  # noqa: BLE001 - mute is a comfort pref: fail open like chat push
                db.conn.rollback()
        db.conn.rollback()
        pref_off = disabled_user_ids(ids, "pins")  # task 20261012-notification-settings; fails open
        out = []
        for rid in ids:
            token = tokens.get(rid)
            if not token or rid in blocked or rid in muted or rid in pref_off or not flags.is_enabled(FLAG, rid):
                continue
            out.append({
                "token": token, "title": name, "body": "pinned a message",
                "data": {"group_id": chat_key, "action": "message", "message_id": mid},
            })
        return out
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


async def notify_message_pin(chat_key: str, pinner_id: str, message_id: str, recipients: list[str]) -> None:
    """Background task after a pin was newly added and the throttle claim won. Never raises."""
    from backend.interactions.push import send_push

    try:
        loop = asyncio.get_running_loop()
        batch = await loop.run_in_executor(None, _prepare, chat_key, pinner_id, message_id, recipients)
        sent = failed = 0
        for item in batch:
            try:
                ok = await send_push(item["token"], item["title"], item["body"], data=item["data"])
            except Exception as e:  # noqa: BLE001 - isolate per recipient
                logger.warning("PIN_PUSH recipient failed reason=%s", type(e).__name__)
                ok = False
            sent, failed = (sent + 1, failed) if ok else (sent, failed + 1)
        if batch:
            logger.info("PIN_PUSH sent=%d failed=%d", sent, failed)
    except Exception as e:  # noqa: BLE001 - a notification must never break a request
        logger.warning("PIN_PUSH aborted reason=%s", type(e).__name__)
