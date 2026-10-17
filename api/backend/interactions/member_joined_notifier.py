"""Essential push to existing members when someone joins their group (task 20261016).

Fires on every way a user becomes a member: invite-link redemption, join-request
approval and a direct member-list edit (``PUT /group/{user}/{group}``). Always
sent: it never consults ``push_preferences``. Group creation is not a "join".

Recipients: the group's current members minus the new member(s), minus members
in a blocked relationship with any new member (in either direction), minus
suspended users and members with no device token, and minus members who muted
the group (a mute lookup failure fails OPEN, like the owner join-request push),
capped at ``MEMBER_JOINED_MAX_RECIPIENTS``. One push per recipient however many
people were added in one edit. Per-recipient failures are isolated.

Privacy: alert text is generic (title = group title, body names nobody); the
payload carries ``action`` and ``group_id`` only. Log lines carry counts only.
Run as a post-commit ``BackgroundTask``; nothing raises out of the public
coroutines, so a push problem never fails the join.
"""
from __future__ import annotations

import asyncio
import logging
import uuid

from db import DBManager

logger = logging.getLogger(__name__)

PUSH_ACTION = "member_joined"
BODY = "A new member joined your group"
TITLE_MAX = 60
MEMBER_JOINED_MAX_RECIPIENTS = 500


def _canon(value) -> str | None:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, AttributeError, TypeError):
        return None


def _truncate(text: str, limit: int = TITLE_MAX) -> str:
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _prepare(group_id: str, new_member_ids: list[str]) -> dict | None:
    gid = _canon(group_id)
    joined = [c for c in (_canon(u) for u in new_member_ids) if c]
    if gid is None or not joined:
        return None
    db = DBManager()
    try:
        db.cur.execute("SELECT title, COALESCE(users, '{}') FROM groups WHERE _id = %s", (gid,))
        row = db.cur.fetchone()
        db.conn.rollback()
        if not row:
            return None
        title = row[0]
        existing = [c for c in (_canon(u) for u in row[1]) if c and c not in set(joined)]
        if not existing:
            return None
        muted: set[str] = set()
        try:
            db.cur.execute(
                "SELECT user_id::text FROM group_mutes WHERE group_id = %s AND user_id = ANY(%s::uuid[])",
                (gid, existing),
            )
            muted = {r[0] for r in db.cur.fetchall()}
            db.conn.rollback()
        except Exception:  # noqa: BLE001 - mute is a comfort preference: fail open
            db.conn.rollback()
        db.cur.execute(
            "SELECT u._id::text, dt.token FROM users u JOIN device_tokens dt ON dt.user_id = u._id "
            "WHERE u._id = ANY(%s::uuid[]) AND u.suspended_at IS NULL "
            "AND NOT EXISTS (SELECT 1 FROM blocked_users b WHERE "
            "(b.blocker_id = u._id AND b.blocked_id = ANY(%s::uuid[])) "
            "OR (b.blocked_id = u._id AND b.blocker_id = ANY(%s::uuid[])))",
            (existing, joined, joined),
        )
        targets = [(r[0], r[1]) for r in db.cur.fetchall() if r[1] and r[0] not in muted]
        db.conn.rollback()
        if not targets:
            return None
        return {
            "title": _truncate(title or "Your group"),
            "data": {"action": PUSH_ACTION, "group_id": gid},
            "targets": targets[:MEMBER_JOINED_MAX_RECIPIENTS],
        }
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()


async def notify_members_of_new_members(group_id: str, new_member_ids: list[str]) -> None:
    """Background task after one or more users were added. Never raises."""
    from backend.interactions.member_joined_line import record_member_joined
    from backend.interactions.push import send_push

    # G2: persist the in-chat "member joined" system line first (every add path
    # funnels through here). Isolated: never raises, never blocks the push.
    try:
        await asyncio.get_running_loop().run_in_executor(
            None, record_member_joined, group_id, list(new_member_ids))
    except Exception as e:  # noqa: BLE001
        logger.warning("MEMBER_JOINED_LINE aborted reason=%s", type(e).__name__)

    try:
        loop = asyncio.get_running_loop()
        prepared = await loop.run_in_executor(None, _prepare, group_id, list(new_member_ids))
        if not prepared:
            return
        sent = failed = 0
        for _uid, token in prepared["targets"]:
            try:
                if await send_push(token, prepared["title"], BODY, data=prepared["data"]):
                    sent += 1
                else:
                    failed += 1
            except Exception:  # noqa: BLE001 - per-recipient isolation (incl. APNsConfigError)
                failed += 1
        logger.info("MEMBER_JOINED_PUSH sent=%d failed=%d", sent, failed)
    except Exception as e:  # noqa: BLE001 - a notification must never break a join
        logger.warning("MEMBER_JOINED_PUSH aborted reason=%s", type(e).__name__)


async def notify_members_of_approved_request(request_id: str) -> None:
    """Background task after a join-request approval appended the applicant."""
    rid = _canon(request_id)
    if rid is None:
        return
    try:
        loop = asyncio.get_running_loop()

        def _lookup() -> tuple[str, str] | None:
            db = DBManager()
            try:
                db.cur.execute(
                    "SELECT group_id::text, user_id::text FROM group_join_requests WHERE id = %s", (rid,)
                )
                row = db.cur.fetchone()
                db.conn.rollback()
                return (row[0], row[1]) if row else None
            finally:
                db.close()

        found = await loop.run_in_executor(None, _lookup)
        if found:
            await notify_members_of_new_members(found[0], [found[1]])
    except Exception as e:  # noqa: BLE001
        logger.warning("MEMBER_JOINED_PUSH aborted reason=%s", type(e).__name__)
