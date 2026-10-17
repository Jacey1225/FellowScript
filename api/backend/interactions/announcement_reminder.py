"""One-hour-before reminder for scheduled announcements (task 20261016).

A group announcement created with a future ``publish_at`` pushes its members
about an hour before it goes live, to members with the ``announcement_reminder``
toggle on (default ON, own toggle separate from ``announcements``).

Eligibility is evaluated by one atomic single-winner claim on
``group_announcements.reminder_push_sent_at`` (the same claim-before-send
pattern as ``announcement_notifier``), so restarts, overlapping runs and
multiple workers send at most once. The claim only matches rows that are:

- not deleted and not yet published (``push_sent_at IS NULL`` and
  ``publish_at > now()``), so immediate/past rows never get a reminder;
- inside the final hour (``publish_at <= now() + 1 hour``);
- scheduled at least an hour ahead at creation (``created_at <= publish_at - 1
  hour``): an announcement created with under an hour to go gets no reminder (its
  creation-time "scheduled" heads-up already covers it).

Rescheduling is handled in ``Announcements.update`` (sets the marker when the
new time is under an hour away, clears it otherwise), and a delete excludes the
row from the claim. Recipients, mute/block rules, the token filter and the
recipient cap are those of ``announcement_notifier._recipients``. The alert is
group name + announcement title, never the description; the payload carries
identifiers only. A failed send is logged, never retried.
"""
from __future__ import annotations

import asyncio
import functools
import logging

from backend.interactions import announcement_notifier as notifier
from db import DBManager

logger = logging.getLogger(__name__)

ANNOUNCEMENT_REMINDER_POLL_INTERVAL_SECONDS = 60
ANNOUNCEMENT_REMINDER_LEAD_SECONDS = 3600
ANNOUNCEMENT_REMINDER_MAX_ROWS_PER_TICK = 20
PUSH_TYPE = "announcement_reminder"


def _claim_due(db: DBManager) -> list[tuple]:
    try:
        db.cur.execute(
            "UPDATE group_announcements SET reminder_push_sent_at = now() WHERE _id IN ("
            " SELECT _id FROM group_announcements"
            " WHERE reminder_push_sent_at IS NULL AND push_sent_at IS NULL AND deleted_at IS NULL"
            "  AND publish_at > now() AND publish_at <= now() + make_interval(secs => %s)"
            "  AND created_at <= publish_at - make_interval(secs => %s)"
            " ORDER BY publish_at LIMIT %s FOR UPDATE SKIP LOCKED)"
            f" RETURNING {notifier._ROW}",
            (ANNOUNCEMENT_REMINDER_LEAD_SECONDS, ANNOUNCEMENT_REMINDER_LEAD_SECONDS,
             ANNOUNCEMENT_REMINDER_MAX_ROWS_PER_TICK),
        )
        rows = db.cur.fetchall()
        db.conn.commit()
        return rows
    except Exception:
        db.conn.rollback()
        raise


def _prepare(db: DBManager, row: tuple):
    announcement_id, group_id, creator_id, title = str(row[0]), str(row[1]), str(row[2]) if row[2] else None, row[3]
    group_title, targets = notifier._recipients(db, group_id, creator_id, push_type=PUSH_TYPE)
    if not targets:
        return None
    data = {"action": "announcement", "group_id": group_id, "announcement_id": announcement_id}
    return (group_title or "Announcement",
            notifier._truncate(f"Starting in about an hour: {title}"), data, targets)


async def fire_due_announcement_reminders() -> None:
    """Scheduler job: remind each due, unreminded, live announcement once. Never raises."""
    if not notifier._enabled():
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
                logger.info("Announcement reminder: announcement=%s sent=%d failed=%d", row[0], sent, failed)
            except Exception as e:  # noqa: BLE001 - one row never aborts the rest
                logger.warning("Announcement reminder aborted reason=%s", type(e).__name__)
    except Exception as e:  # noqa: BLE001
        logger.warning("Announcement-reminder scheduler job error reason=%s", type(e).__name__)
    finally:
        if db is not None:
            db.close()
