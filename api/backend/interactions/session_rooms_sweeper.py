"""Lifecycle sweeper for discussion rooms (scheduler job). Task 20261009-discussion-rooms.

Runs REGARDLESS of the ``discussion_rooms`` flag, like the join-request sweeper:
it is the only job that mutates rooms while the flag is off, so a rollback never
leaves live rooms or billed meetings behind. Passes, in order:

1. mark stale members left (``left_at = last_seen``: the heartbeat lapsed);
2. end active rooms whose main session is gone-live (the recurring advance
   cleared ``chime_meeting_id``, or the main call was never/no longer set);
3. end active rooms with no live member past ``empty_grace_seconds``;
4. probe up to ``sweep_chime_checks_per_run`` active rooms that HAVE live members
   and end any whose Chime meeting is confirmed gone (NotFound). Any other probe
   outcome acts on nothing (fail closed). The end is conditional on the stored
   meeting id still being the probed one, so a concurrent stale-meeting recreate
   in ``join`` is never overridden;
5. ``DeleteMeeting`` for up to the same budget of ended rooms that still hold a
   meeting id, blanking the id only on confirmed success (retried next run);
6. purge ended rooms older than ``ended_retention_seconds``.

Session deletion cascades room rows; its route collects room meeting ids first
and deletes them best-effort. Chime calls are budgeted per run to stay far below
the account's 10 requests/second GetMeeting/DeleteMeeting quota.

R-SCHED: ``run_session_rooms_sweeper_job`` is a thin ``async def``; all work is
in ``sweep_once`` through ``loop.run_in_executor``. Logs counts only, never ids,
titles or usernames, and never the bare word ERROR for ordinary conditions.
"""
from __future__ import annotations

import asyncio
import logging

from backend.interactions import chime_meetings
from backend.interactions.session_rooms import _expired_empty_sql
from backend.interactions.session_rooms_config import get_session_rooms_config
from db import DBManager

logger = logging.getLogger(__name__)

JOB_ID = "session_rooms_sweep"


def sweep_once(db: DBManager | None = None) -> dict:
    cfg = get_session_rooms_config()
    own = db is None
    db = db or DBManager()
    counts = {"stale_members": 0, "main_gone": 0, "empty": 0, "meeting_gone": 0, "meetings_deleted": 0, "purged": 0}
    try:
        cur = db.cur
        cur.execute(
            "UPDATE session_room_members SET left_at = last_seen WHERE left_at IS NULL "
            "AND last_seen <= NOW() - (%s * INTERVAL '1 second')",
            (cfg.member_stale_seconds,),
        )
        counts["stale_members"] = cur.rowcount
        cur.execute(
            "UPDATE session_rooms r SET ended_at = NOW() WHERE r.ended_at IS NULL AND EXISTS ("
            " SELECT 1 FROM devotions d WHERE d._id = r.session_id AND COALESCE(d.chime_meeting_id, '') = '')"
        )
        counts["main_gone"] = cur.rowcount
        cur.execute(
            "UPDATE session_rooms r SET ended_at = NOW() WHERE " + _expired_empty_sql("r"),
            (cfg.member_stale_seconds, cfg.empty_grace_seconds),
        )
        counts["empty"] = cur.rowcount
        db.conn.commit()

        if cfg.sweep_chime_checks_per_run > 0:
            cur.execute(
                "SELECT r.id, r.chime_meeting_id FROM session_rooms r WHERE r.ended_at IS NULL "
                "AND r.chime_meeting_id <> '' AND EXISTS (SELECT 1 FROM session_room_members m "
                "WHERE m.room_id = r.id AND m.left_at IS NULL) ORDER BY random() LIMIT %s",
                (cfg.sweep_chime_checks_per_run,),
            )
            for room_id, meeting_id in cur.fetchall():
                if chime_meetings.meeting_exists(meeting_id) is False:
                    cur.execute(
                        "UPDATE session_rooms SET ended_at = NOW() WHERE id = %s AND ended_at IS NULL "
                        "AND chime_meeting_id = %s",
                        (room_id, meeting_id),
                    )
                    if cur.rowcount:
                        cur.execute(
                            "UPDATE session_room_members SET left_at = NOW() WHERE room_id = %s AND left_at IS NULL",
                            (room_id,),
                        )
                        counts["meeting_gone"] += 1
            db.conn.commit()

            cur.execute(
                "SELECT id, chime_meeting_id FROM session_rooms WHERE ended_at IS NOT NULL "
                "AND chime_meeting_id <> '' ORDER BY ended_at LIMIT %s",
                (cfg.sweep_chime_checks_per_run,),
            )
            for room_id, meeting_id in cur.fetchall():
                if chime_meetings.delete_meeting(meeting_id):
                    cur.execute(
                        "UPDATE session_rooms SET chime_meeting_id = '', chime_meeting = '{}' "
                        "WHERE id = %s AND chime_meeting_id = %s",
                        (room_id, meeting_id),
                    )
                    counts["meetings_deleted"] += 1
            db.conn.commit()

        cur.execute(
            "DELETE FROM session_rooms WHERE ended_at IS NOT NULL AND chime_meeting_id = '' "
            "AND ended_at < NOW() - (%s * INTERVAL '1 second')",
            (cfg.ended_retention_seconds,),
        )
        counts["purged"] = cur.rowcount
        db.conn.commit()
        return counts
    except Exception:
        db.conn.rollback()
        raise
    finally:
        if own:
            db.close()


async def run_session_rooms_sweeper_job() -> None:
    loop = asyncio.get_running_loop()
    try:
        counts = await loop.run_in_executor(None, sweep_once)
    except Exception as e:
        logger.warning("SESSION_ROOMS sweep failed: %s", type(e).__name__)
        return
    if any(v for k, v in counts.items() if k != "stale_members") or counts["stale_members"]:
        logger.info("SESSION_ROOMS sweep %s", counts)
