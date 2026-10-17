"""Recurring re-push of a published group announcement (task 20261016-announcement-recurring-reminder).

An announcement whose author set a repeat (daily / weekly / monthly) is
re-pushed after publish at each occurrence until the author clears the repeat,
the end date passes, the 52-occurrence / 365-day cap is hit, or it is deleted.
Mirrors ``announcement_reminder``: a 60 s poll job, claim-before-send,
``FOR UPDATE SKIP LOCKED``, per-row isolation, never raises.

Claim: one transaction selects due rows ``FOR UPDATE SKIP LOCKED`` (so
concurrent workers and overlapping runs never see the same row), computes the
next occurrence in Python (zoneinfo; see ``announcement_repeat_rules``),
advances ``next_repeat_at`` / ``repeat_push_count`` and commits BEFORE any
send. At-most-once: a failed send is logged, never retried.

No back-fill: the claim jumps ``next_repeat_at`` to the first occurrence
strictly after now and sends at most one push; a due time staler than
``ANNOUNCEMENT_REPEAT_STALE_AFTER_SECONDS`` is advanced past without a push.

Fail closed: flag off, an unknown interval/zone, unparseable state or a
departed/suspended author disarms the row (``next_repeat_at = NULL``, logged,
never deleted, no auto re-arm); a lookup failure leaves that row unclaimed
(sends nothing). Mute lookup keeps ``_recipients``' documented fail-open.

Recipients and caps: ``announcement_notifier._recipients(push_type=
"announcement_reminder")`` (same members/mute/block/opt-out/token rules and
500 recipient cap) plus a per-group rolling budget that also counts the
publish/creation pushes of other announcements. Alert is group title +
"Reminder: {title}" truncated; payload ids only; logs ids and counts only.
"""
from __future__ import annotations

import asyncio
import functools
import logging
from datetime import datetime, timezone

from backend.interactions import announcement_notifier as notifier
from backend.interactions import announcement_repeat_rules as rules
from db import DBManager

logger = logging.getLogger(__name__)

PUSH_TYPE = "announcement_reminder"
ANNOUNCEMENT_REPEAT_POLL_INTERVAL_SECONDS = rules.ANNOUNCEMENT_REPEAT_POLL_INTERVAL_SECONDS

_DUE_SELECT = (
    "SELECT _id, group_id, creator_id, title, publish_at, repeat_interval, repeat_until, repeat_tz, "
    "repeat_started_at, next_repeat_at, repeat_push_count FROM group_announcements "
    "WHERE repeat_interval IS NOT NULL AND next_repeat_at IS NOT NULL AND next_repeat_at <= now() "
    "AND deleted_at IS NULL AND publish_at <= now() "
    "ORDER BY next_repeat_at LIMIT %s FOR UPDATE SKIP LOCKED"
)


def _enabled() -> bool:
    return bool(rules.ANNOUNCEMENT_REPEAT_ENABLED and notifier._enabled())


def _author_eligible(db: DBManager, group_id: str, creator_id: str | None) -> bool:
    """The author still exists, is not suspended and is still a group member."""
    if not creator_id:
        return False
    db.cur.execute(
        "SELECT 1 FROM groups g JOIN users u ON u._id = %s "
        "WHERE g._id = %s AND %s = ANY(g.users) AND u.suspended_at IS NULL",
        (creator_id, group_id, creator_id),
    )
    return db.cur.fetchone() is not None


def _group_over_cap(db: DBManager, group_id: str, announcement_id: str) -> bool:
    """True when the group already used its rolling budget on OTHER
    announcements' pushes (this row's own earlier pushes don't count)."""
    window = rules.ANNOUNCEMENT_REPEAT_GROUP_CAP_WINDOW_SECONDS
    db.cur.execute(
        "SELECT count(*) FROM group_announcements WHERE group_id = %s AND _id <> %s AND ("
        " last_repeat_push_at > now() - make_interval(secs => %s)"
        " OR push_sent_at > now() - make_interval(secs => %s)"
        " OR creation_push_sent_at > now() - make_interval(secs => %s))",
        (group_id, announcement_id, window, window, window),
    )
    return db.cur.fetchone()[0] >= rules.ANNOUNCEMENT_REPEAT_GROUP_CAP


def _decide(db: DBManager, row: tuple, now: datetime) -> tuple[bool, dict]:
    """``(send, column_updates)`` for one locked, due row."""
    (aid, group_id, creator_id, _title, publish_at, interval, until, tz, started, due, count) = row
    aid, group_id = str(aid), str(group_id)
    creator_id = str(creator_id) if creator_id else None
    disarm = {"next_repeat_at": None}
    if interval not in rules.REPEAT_INTERVALS or publish_at is None or due is None:
        logger.warning("Announcement repeat disarmed, invalid state: announcement=%s", aid)
        return False, disarm
    try:
        if tz:
            rules.normalize_repeat_tz(tz)
        end = rules.effective_end(until, started)
    except ValueError:
        logger.warning("Announcement repeat disarmed, invalid zone: announcement=%s", aid)
        return False, disarm
    if end is None or due > end or count >= rules.ANNOUNCEMENT_REPEAT_MAX_OCCURRENCES:
        logger.info("Announcement repeat finished: announcement=%s count=%d", aid, count)
        return False, disarm
    if not _author_eligible(db, group_id, creator_id):
        logger.info("Announcement repeat stopped, author no longer eligible: announcement=%s", aid)
        return False, disarm

    send = True
    age = (now - due).total_seconds()
    if age > rules.ANNOUNCEMENT_REPEAT_STALE_AFTER_SECONDS:
        logger.info("Announcement repeat skipped as stale: announcement=%s age=%.0fs", aid, age)
        send = False
    elif _group_over_cap(db, group_id, aid):
        logger.warning("Announcement repeat skipped, group cap reached: group=%s announcement=%s", group_id, aid)
        send = False

    new_count = count + 1 if send else count
    updates: dict = {
        "next_repeat_at": rules.next_armed(publish_at, interval, tz, now, end, new_count),
    }
    if send:
        updates["repeat_push_count"] = new_count
        updates["last_repeat_push_at"] = now
    return send, updates


def _claim_due(db: DBManager) -> list[tuple]:
    """Atomically advance every due row and return those to push. One
    transaction; each row is isolated by a savepoint, so a failure leaves
    that row unclaimed (nothing sent) without aborting the others."""
    claimed: list[tuple] = []
    try:
        db.cur.execute("SELECT now()")
        now = db.cur.fetchone()[0].astimezone(timezone.utc)
        db.cur.execute(_DUE_SELECT, (rules.ANNOUNCEMENT_REPEAT_MAX_ROWS_PER_TICK,))
        rows = db.cur.fetchall()
        for row in rows:
            aid = str(row[0])
            try:
                db.cur.execute("SAVEPOINT repeat_row")
                send, updates = _decide(db, row, now)
                cols = ", ".join(f"{c} = %s" for c in updates)
                db.cur.execute(
                    f"UPDATE group_announcements SET {cols} WHERE _id = %s AND next_repeat_at = %s",
                    (*updates.values(), aid, row[9]),
                )
                if db.cur.rowcount != 1:
                    raise RuntimeError("claim lost")
                db.cur.execute("RELEASE SAVEPOINT repeat_row")
                if send:
                    claimed.append(row)
            except Exception as e:  # noqa: BLE001 - one row never aborts the rest
                db.cur.execute("ROLLBACK TO SAVEPOINT repeat_row")
                logger.warning("Announcement repeat claim aborted: announcement=%s reason=%s",
                               aid, type(e).__name__)
        db.conn.commit()
        return claimed
    except Exception:
        db.conn.rollback()
        raise


def _prepare(db: DBManager, row: tuple):
    announcement_id, group_id = str(row[0]), str(row[1])
    creator_id, title = str(row[2]) if row[2] else None, row[3]
    group_title, targets = notifier._recipients(db, group_id, creator_id, push_type=PUSH_TYPE)
    if not targets:
        return None
    data = {"action": "announcement", "group_id": group_id, "announcement_id": announcement_id}
    return (group_title or "Announcement", notifier._truncate(f"Reminder: {title}"), data, targets)


async def fire_due_announcement_repeats() -> None:
    """Scheduler job: re-push each due repeating announcement once per
    occurrence. Never raises."""
    if not _enabled():
        return
    loop = asyncio.get_running_loop()
    db = None
    try:
        db = DBManager()
        rows = await loop.run_in_executor(None, functools.partial(_claim_due, db))
        for row in rows:
            try:
                prepared = await loop.run_in_executor(None, functools.partial(_prepare, db, row))
                if not prepared:
                    continue
                sent, failed = await notifier._send(prepared)
                logger.info("Announcement repeat: announcement=%s sent=%d failed=%d", row[0], sent, failed)
            except Exception as e:  # noqa: BLE001
                logger.warning("Announcement repeat aborted reason=%s", type(e).__name__)
    except Exception as e:  # noqa: BLE001
        logger.warning("Announcement-repeat scheduler job error reason=%s", type(e).__name__)
    finally:
        if db is not None:
            db.close()
