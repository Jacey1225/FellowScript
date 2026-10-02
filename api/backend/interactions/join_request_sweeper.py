"""Expiry and retention sweeper for join requests (scheduler job).

Runs REGARDLESS of the ``join_requests`` flag: it is the only job that mutates
rows while the flag is off, so a pending row can never sit forever after a
rollback. Three passes, each in small batches that lock request rows with
``FOR UPDATE SKIP LOCKED`` (never waits on a row an approve or deny holds, and
never takes a group lock, so it cannot join a lock cycle):

1. pending older than ``pending_expiry_days`` -> ``expired``;
2. pending rows of a group whose owner is gone (``creator_id`` NULL or no longer
   in ``groups.users``) -> ``expired`` (nobody can approve them);
3. decided rows (approved, denied, withdrawn, expired) older than
   ``retention_days`` (and never younger than ``cooldown_days``) are deleted.
   A denied row carrying the owner's "do not let this person ask again"
   (``block_reapply``) is kept with its note cleared instead of deleted, so the
   owner's decision does not silently lapse; it holds ids and a status only.

R-SCHED: ``run_join_request_sweeper_job`` is a thin ``async def``; all database
work is in ``sweep_once`` through ``loop.run_in_executor``. A run that changed
rows logs one INFO line with counts; a run with failures logs ONE aggregated
WARNING with counts (never ids, notes or titles). The bare word ERROR never
appears here (the watchdog treats it as a detection).

Also registers the ``pending_join_requests`` FEATURE_SUMMARY gauge.
"""
from __future__ import annotations

import asyncio
import logging

from backend.interactions.join_requests_config import get_join_requests_config
from backend.observability import feature_summary
from db import DBManager

logger = logging.getLogger(__name__)

JOB_ID = "join_request_sweep"
SWEEP_INTERVAL_SECONDS = 600
BATCH_SIZE = 200
MAX_ROUNDS = 10  # batches per pass per run; the rest is picked up next tick

_EXPIRE_AGED = (
    "UPDATE group_join_requests SET status = 'expired', decided_at = NOW() WHERE id IN ("
    " SELECT id FROM group_join_requests WHERE status = 'pending'"
    " AND created_at < NOW() - make_interval(days => %s)"
    " ORDER BY created_at LIMIT %s FOR UPDATE SKIP LOCKED)"
)

_EXPIRE_OWNERLESS = (
    "UPDATE group_join_requests SET status = 'expired', decided_at = NOW() WHERE id IN ("
    " SELECT r.id FROM group_join_requests r JOIN groups g ON g._id = r.group_id"
    " WHERE r.status = 'pending'"
    " AND (g.creator_id IS NULL OR NOT (g.creator_id::text = ANY(COALESCE(g.users, '{}'))))"
    " ORDER BY r.created_at LIMIT %s FOR UPDATE OF r SKIP LOCKED)"
)

_DELETE_DECIDED = (
    "DELETE FROM group_join_requests WHERE id IN ("
    " SELECT id FROM group_join_requests"
    " WHERE status IN ('approved', 'denied', 'withdrawn', 'expired') AND NOT (status = 'denied' AND block_reapply)"
    " AND COALESCE(decided_at, created_at) < NOW() - make_interval(days => %s)"
    " ORDER BY COALESCE(decided_at, created_at) LIMIT %s FOR UPDATE SKIP LOCKED)"
)

_CLEAR_BLOCKED_NOTES = (
    "UPDATE group_join_requests SET note = NULL WHERE id IN ("
    " SELECT id FROM group_join_requests"
    " WHERE status = 'denied' AND block_reapply AND note IS NOT NULL"
    " AND COALESCE(decided_at, created_at) < NOW() - make_interval(days => %s)"
    " ORDER BY COALESCE(decided_at, created_at) LIMIT %s FOR UPDATE SKIP LOCKED)"
)


def _run_pass(db: DBManager, sql_text: str, params: tuple) -> int:
    """Run one batched statement until a batch comes back short; returns rows changed."""
    total = 0
    for _ in range(MAX_ROUNDS):
        db.cur.execute("SELECT set_config('lock_timeout', %s, true)", (f"{get_join_requests_config().lock_timeout_ms}ms",))
        db.cur.execute(sql_text, params)
        changed = db.cur.rowcount
        db.conn.commit()
        total += changed
        if changed < BATCH_SIZE:
            break
    return total


def sweep_once() -> dict:
    """One sweep. Returns ``{"expired_aged", "expired_ownerless", "purged", "cleared", "failed"}``.
    Each pass is isolated: a failing pass is counted and the others still run."""
    cfg = get_join_requests_config()
    counts = {"expired_aged": 0, "expired_ownerless": 0, "purged": 0, "cleared": 0, "failed": 0}
    retention = max(cfg.retention_days, cfg.cooldown_days)  # never inside a cooldown window
    passes = (
        ("expired_aged", _EXPIRE_AGED, (cfg.pending_expiry_days, BATCH_SIZE)),
        ("expired_ownerless", _EXPIRE_OWNERLESS, (BATCH_SIZE,)),
        ("purged", _DELETE_DECIDED, (retention, BATCH_SIZE)),
        ("cleared", _CLEAR_BLOCKED_NOTES, (retention, BATCH_SIZE)),
    )
    db = DBManager()
    try:
        for name, statement, params in passes:
            try:
                counts[name] = _run_pass(db, statement, params)
            except Exception:  # noqa: BLE001 - one bad pass must not stop the others
                db.conn.rollback()
                counts["failed"] += 1
    finally:
        db.close()
    summary = " ".join(f"{k}={v}" for k, v in counts.items())
    if counts["failed"]:
        logger.warning("JOIN_REQUEST_SWEEP partial: %s", summary)
    elif any(v for k, v in counts.items() if k != "failed"):
        logger.info("JOIN_REQUEST_SWEEP %s", summary)
    return counts


async def run_join_request_sweeper_job() -> None:
    """Scheduler entry: thin async wrapper, all DB work off the event loop."""
    loop = asyncio.get_running_loop()
    try:
        await loop.run_in_executor(None, sweep_once)
    except Exception as e:  # noqa: BLE001 - a failed run is retried next tick
        logger.warning("JOIN_REQUEST_SWEEP run failed: %s", type(e).__name__)


def pending_count() -> int:
    """Gauge for the hourly FEATURE_SUMMARY line (runs in a worker thread)."""
    db = DBManager()
    try:
        db.cur.execute("SELECT count(*) FROM group_join_requests WHERE status = 'pending'")
        return int(db.cur.fetchone()[0])
    finally:
        db.close()


feature_summary.register_gauge("pending_join_requests", pending_count)
