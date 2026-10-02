"""Drain ``pending_s3_deletes``: S3 keys queued by group/member/user deletion.

Request paths only ENQUEUE inside their own transaction (``lifecycle``); they
never flush. This module's 60 s scheduler job (R-SCHED) is the only deleter:

- ``run_s3_outbox_job`` is a thin ``async def``; all database and S3 work runs
  in ``flush_batch`` through ``loop.run_in_executor`` (no blocking call on the
  event loop).
- A batch is at most ``BATCH_SIZE`` rows claimed ``FOR UPDATE SKIP LOCKED``;
  rows at ``MAX_ATTEMPTS`` are given up on (kept, never retried).
- Logging: one aggregated WARNING per run when anything did not delete, with
  counts only (never a key). At most one ``S3_DELETE_DENIED`` ERROR per key
  prefix per 24 h (an IAM gap is an operator action, not a per-key event).
  Non-error lines say "failed" (the watchdog treats the bare word as a
  detection).
"""
from __future__ import annotations

import asyncio
import logging
import threading
import time

from db import DBManager
from backend.interactions.attachments import delete_object_status

logger = logging.getLogger(__name__)

FLUSH_INTERVAL_SECONDS = 60
BATCH_SIZE = 200
MAX_ATTEMPTS = 20
DENIED_LOG_INTERVAL_SECONDS = 24 * 60 * 60

_denied_lock = threading.Lock()
_denied_logged_at: dict[str, float] = {}


def _prefix_of(key: str) -> str:
    return key.split("/", 1)[0] if "/" in key else "(root)"


def _log_denied_once_per_day(prefixes: set[str]) -> None:
    now = time.monotonic()
    for prefix in sorted(prefixes):
        with _denied_lock:
            last = _denied_logged_at.get(prefix)
            if last is not None and now - last < DENIED_LOG_INTERVAL_SECONDS:
                continue
            _denied_logged_at[prefix] = now
        logger.error("S3_DELETE_DENIED prefix=%s", prefix)


def reset_for_tests() -> None:
    with _denied_lock:
        _denied_logged_at.clear()


def flush_batch(delete_fn=delete_object_status) -> dict[str, int]:
    """Process one batch synchronously. Returns counts:
    ``deleted``, ``denied``, ``failed``, ``gave_up`` (rows that just hit the
    attempt cap) and ``claimed``. ``delete_fn(key) -> 'ok'|'denied'|'error'``
    is injectable so tests need no S3."""
    counts = {"claimed": 0, "deleted": 0, "denied": 0, "failed": 0, "gave_up": 0}
    denied_prefixes: set[str] = set()
    db = DBManager()
    try:
        db.cur.execute(
            "SELECT key, attempts FROM pending_s3_deletes WHERE attempts < %s "
            "ORDER BY enqueued_at, key LIMIT %s FOR UPDATE SKIP LOCKED",
            (MAX_ATTEMPTS, BATCH_SIZE),
        )
        rows = db.cur.fetchall()
        counts["claimed"] = len(rows)
        for key, attempts in rows:
            status = delete_fn(key)
            if status == "ok":
                db.cur.execute("DELETE FROM pending_s3_deletes WHERE key = %s", (key,))
                counts["deleted"] += 1
                continue
            if status == "denied":
                counts["denied"] += 1
                denied_prefixes.add(_prefix_of(key))
            else:
                counts["failed"] += 1
            db.cur.execute(
                "UPDATE pending_s3_deletes SET attempts = attempts + 1, "
                "last_attempt_at = NOW() WHERE key = %s",
                (key,),
            )
            if attempts + 1 >= MAX_ATTEMPTS:
                counts["gave_up"] += 1
        db.conn.commit()
    except Exception:
        db.conn.rollback()
        raise
    finally:
        db.close()

    if denied_prefixes:
        _log_denied_once_per_day(denied_prefixes)
    if counts["denied"] or counts["failed"] or counts["gave_up"]:
        logger.warning(
            "S3_OUTBOX_FLUSH partial: deleted=%d denied=%d failed=%d gave_up=%d",
            counts["deleted"], counts["denied"], counts["failed"], counts["gave_up"],
        )
    return counts


async def run_s3_outbox_job() -> None:
    """Scheduler entry (every ``FLUSH_INTERVAL_SECONDS``): thin async wrapper."""
    loop = asyncio.get_running_loop()
    try:
        await loop.run_in_executor(None, flush_batch)
    except Exception as e:  # noqa: BLE001 - a failed run is retried next tick
        logger.warning("S3_OUTBOX_FLUSH run failed: %s", type(e).__name__)
