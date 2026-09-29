"""Group push for announcements (task 20260929-announcement-push-widget).

Lives beside ``announcements.py`` rather than inside ``websockets.py``.

Two independently idempotent pushes per announcement, each guarded by an
atomic single-winner ``UPDATE ... WHERE <marker> IS NULL`` claim (the same
pattern as ``_fire_due_session_reminders``), so restarts, overlapping
scheduler runs and multiple workers can never double-send:

- ``push_sent_at``: the publish push. Sent at creation for an immediate row
  (a single push, ever) or by the scheduler at ``publish_at`` for a future
  row.
- ``creation_push_sent_at``: the "scheduled" heads-up sent at creation for a
  future-dated row.

At-most-once: the claim happens before the send and a failed send is logged,
never retried. Deleting before the scheduler fires cancels it (the claim
excludes tombstoned rows); editing ``publish_at`` before it fires simply
moves when the claim becomes eligible. Deleting after the creation push does
not recall it.

Recipients: every group member (the author included, per the user's
2026-09-29 confirmation) except members with no device token, members who
muted the group, and members in a blocked relationship with the author. A
mute-lookup failure fails OPEN (mute is a comfort preference, matching
``websockets.py``); every other lookup failure aborts that push, and a
per-recipient failure never aborts the fan-out.

Payloads carry identifiers only (``action``, ``group_id``,
``announcement_id``); the alert is group name + announcement title, never
the description. Log lines carry ids and counts, never titles.
"""

import asyncio
import functools
import logging
import uuid
from datetime import datetime, timezone

from db import DBManager

logger = logging.getLogger(__name__)

# Feature flag, independent of ANNOUNCEMENTS_ENABLED (both must be True).
ANNOUNCEMENT_PUSH_ENABLED = True

ANNOUNCEMENT_PUSH_POLL_INTERVAL_SECONDS = 60
# Rows claimed per scheduler tick; the remainder is picked up next tick.
ANNOUNCEMENT_PUSH_MAX_ROWS_PER_TICK = 20
# Hard bound on one fan-out's recipient count.
ANNOUNCEMENT_PUSH_MAX_RECIPIENTS = 500
# Per-group rate cap (applies to every author, paid included): more than this
# many announcement pushes in the window and the push is skipped (the
# announcement itself still posts).
ANNOUNCEMENT_PUSH_GROUP_HOURLY_CAP = 5
ANNOUNCEMENT_PUSH_CAP_WINDOW_SECONDS = 3600
# A claimed row whose publish_at is older than this is not pushed (mirrors
# SESSION_REMINDER_STALE_AFTER_SECONDS): protects against a long scheduler
# outage, a restore long after the fact, and the first tick after deploy
# seeing pre-existing rows.
ANNOUNCEMENT_PUSH_STALE_AFTER_SECONDS = 3600
ANNOUNCEMENT_PUSH_BODY_MAX = 100

KIND_PUBLISH = "publish"
KIND_SCHEDULED = "scheduled"


def _truncate(text: str, limit: int = ANNOUNCEMENT_PUSH_BODY_MAX) -> str:
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _enabled() -> bool:
    from backend.interactions.announcements import ANNOUNCEMENTS_ENABLED
    return bool(ANNOUNCEMENTS_ENABLED and ANNOUNCEMENT_PUSH_ENABLED)


# ── sync DB work (run in an executor) ─────────────────────────────────────

_ROW = "_id, group_id, creator_id, title, publish_at"


def _claim_on_create(db: DBManager, announcement_id: str) -> tuple | None:
    """Claim the creation-time push. Immediate/past rows claim the publish
    marker (and the creation marker, so nothing else ever fires); future rows
    claim only the creation marker. Returns ``(row, kind)`` or None."""
    try:
        db.cur.execute(
            "UPDATE group_announcements "
            "SET push_sent_at = now(), creation_push_sent_at = COALESCE(creation_push_sent_at, now()) "
            "WHERE _id = %s AND push_sent_at IS NULL AND deleted_at IS NULL AND publish_at <= now() "
            f"RETURNING {_ROW}",
            (announcement_id,),
        )
        row = db.cur.fetchone()
        if row:
            db.conn.commit()
            return row, KIND_PUBLISH
        db.cur.execute(
            "UPDATE group_announcements SET creation_push_sent_at = now() "
            "WHERE _id = %s AND creation_push_sent_at IS NULL AND push_sent_at IS NULL "
            "AND deleted_at IS NULL AND publish_at > now() "
            f"RETURNING {_ROW}",
            (announcement_id,),
        )
        row = db.cur.fetchone()
        db.conn.commit()
        return (row, KIND_SCHEDULED) if row else None
    except Exception:
        db.conn.rollback()
        raise


def _claim_due(db: DBManager) -> list[tuple]:
    """Atomically claim up to a tick's worth of due, unsent, live rows.
    ``FOR UPDATE SKIP LOCKED`` keeps concurrent workers from blocking or
    double-claiming."""
    try:
        db.cur.execute(
            "UPDATE group_announcements SET push_sent_at = now() WHERE _id IN ("
            " SELECT _id FROM group_announcements"
            " WHERE push_sent_at IS NULL AND deleted_at IS NULL AND publish_at <= now()"
            " ORDER BY publish_at LIMIT %s FOR UPDATE SKIP LOCKED)"
            f" RETURNING {_ROW}",
            (ANNOUNCEMENT_PUSH_MAX_ROWS_PER_TICK,),
        )
        rows = db.cur.fetchall()
        db.conn.commit()
        return rows
    except Exception:
        db.conn.rollback()
        raise


def _over_cap(db: DBManager, group_id: str) -> bool:
    """True when this group has already used its hourly push budget. The
    just-claimed row counts itself, hence ``>``."""
    db.cur.execute(
        "SELECT count(*) FROM group_announcements WHERE group_id = %s AND ("
        " push_sent_at > now() - make_interval(secs => %s)"
        " OR creation_push_sent_at > now() - make_interval(secs => %s))",
        (group_id, ANNOUNCEMENT_PUSH_CAP_WINDOW_SECONDS, ANNOUNCEMENT_PUSH_CAP_WINDOW_SECONDS),
    )
    return db.cur.fetchone()[0] > ANNOUNCEMENT_PUSH_GROUP_HOURLY_CAP


def _recipients(db: DBManager, group_id: str, creator_id: str | None) -> tuple[str, list[tuple[str, str]]]:
    """``(group_title, [(user_id, device_token), ...])`` after mute/block/
    no-token filtering. Raises on member or token lookup failure."""
    db.cur.execute("SELECT title, users FROM groups WHERE _id = %s", (group_id,))
    row = db.cur.fetchone()
    if not row:
        return "", []
    group_title, users = row[0], [str(u) for u in (row[1] or [])]
    if not users:
        return group_title, []

    excluded: set[str] = set()
    try:
        db.cur.execute(
            "SELECT user_id FROM group_mutes WHERE group_id = %s AND user_id = ANY(%s::uuid[])",
            (group_id, users),
        )
        excluded |= {str(r[0]) for r in db.cur.fetchall()}
    except Exception as e:  # fails open, see module docstring
        db.conn.rollback()
        logger.error("Announcement-push mute lookup failed for group %s: %s", group_id, e)
    if creator_id:
        db.cur.execute(
            "SELECT blocked_id FROM blocked_users WHERE blocker_id = %s "
            "UNION SELECT blocker_id FROM blocked_users WHERE blocked_id = %s",
            (creator_id, creator_id),
        )
        excluded |= {str(r[0]) for r in db.cur.fetchall()}

    eligible = [u for u in users if u not in excluded]
    if not eligible:
        return group_title, []
    db.cur.execute(
        "SELECT user_id, token FROM device_tokens WHERE user_id = ANY(%s::uuid[])",
        (eligible,),
    )
    tokens = {str(r[0]): r[1] for r in db.cur.fetchall()}
    targets = [(u, tokens[u]) for u in eligible if tokens.get(u)]
    return group_title, targets[:ANNOUNCEMENT_PUSH_MAX_RECIPIENTS]


def _prepare(db: DBManager, row: tuple, kind: str) -> tuple[str, str, dict, list[tuple[str, str]]] | None:
    """Everything a send needs, or None when nothing should be sent."""
    announcement_id, group_id, creator_id, title, publish_at = (
        str(row[0]), str(row[1]), str(row[2]) if row[2] else None, row[3], row[4],
    )
    if kind == KIND_PUBLISH:
        age = (datetime.now(timezone.utc) - publish_at).total_seconds()
        if age > ANNOUNCEMENT_PUSH_STALE_AFTER_SECONDS:
            logger.info("Announcement push skipped as stale: announcement=%s age=%.0fs", announcement_id, age)
            return None
    if _over_cap(db, group_id):
        logger.warning("Announcement push skipped, group hourly cap reached: group=%s announcement=%s",
                       group_id, announcement_id)
        return None
    group_title, targets = _recipients(db, group_id, creator_id)
    if not targets:
        return None
    body = _truncate(title)
    if kind == KIND_SCHEDULED:
        body = _truncate(f"New announcement scheduled: {title}")
    data = {"action": "announcement", "group_id": group_id, "announcement_id": announcement_id}
    return group_title or "Announcement", body, data, targets


# ── async fan-out ─────────────────────────────────────────────────────────

async def _send(prepared: tuple[str, str, dict, list[tuple[str, str]]]) -> tuple[int, int]:
    from backend.interactions.push import send_push

    title, body, data, targets = prepared
    sent = failed = 0
    for uid, token in targets:
        try:
            if await send_push(token, title, body, data=data):
                sent += 1
            else:
                failed += 1
        except Exception as e:  # per-recipient isolation (incl. APNsConfigError)
            failed += 1
            logger.error("Announcement push failed (announcement=%s user=%s): %s",
                         data["announcement_id"], uid, e)
    return sent, failed


async def _deliver(loop, db: DBManager, row: tuple, kind: str) -> None:
    announcement_id = str(row[0])
    try:
        prepared = await loop.run_in_executor(None, functools.partial(_prepare, db, row, kind))
        if not prepared:
            return
        sent, failed = await _send(prepared)
        logger.info("Announcement push (%s): announcement=%s sent=%d failed=%d",
                    kind, announcement_id, sent, failed)
    except Exception as e:
        logger.error("Announcement push aborted (announcement=%s): %s", announcement_id, e)


async def notify_on_create(announcement_id: str) -> None:
    """Background task run after a create response. Never raises."""
    if not _enabled():
        return
    try:
        uuid.UUID(str(announcement_id))
    except ValueError:
        return
    loop = asyncio.get_running_loop()
    db = None
    try:
        db = DBManager()
        claimed = await loop.run_in_executor(None, functools.partial(_claim_on_create, db, announcement_id))
        if claimed:
            await _deliver(loop, db, *claimed)
    except Exception as e:
        logger.error("Announcement creation push error (announcement=%s): %s", announcement_id, e)
    finally:
        if db is not None:
            db.close()


async def fire_due_announcement_pushes() -> None:
    """Scheduler job: push each due, unsent, non-deleted announcement once."""
    if not _enabled():
        return
    loop = asyncio.get_running_loop()
    db = None
    try:
        db = DBManager()
        rows = await loop.run_in_executor(None, functools.partial(_claim_due, db))
        for row in rows:
            await _deliver(loop, db, row, KIND_PUBLISH)
    except Exception as e:
        logger.error("Announcement-push scheduler job error: %s", e)
    finally:
        if db is not None:
            db.close()
