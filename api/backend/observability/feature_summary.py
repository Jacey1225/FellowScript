"""Hourly FEATURE_SUMMARY INFO line: the visibility surface for traffic that is
deliberately NOT logged per request (public 404s, 429s, shed load, probes).

In-process counters (single uvicorn process) plus gauges read at emit time.
Counts only: no ids, no usernames, no query text, no PII. Counters reset on
every emission, so each line is "since the previous line".

Callers: ``incr("public_429")`` etc. Later tasks register their own counter or
gauge (JRQ registers ``pending_join_requests``). The emit job is a thin
``async def`` (R-SCHED): all DB work runs via ``run_in_executor``.

Log wording: INFO only; the word ERROR never appears (watchdog rule).
"""
from __future__ import annotations

import asyncio
import logging
import re
import threading
from typing import Callable

logger = logging.getLogger(__name__)

_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
_lock = threading.Lock()

# Counters (reset each hour). Order is the order printed.
_counters: dict[str, int] = {
    "public_requests": 0,
    "public_404": 0,
    "public_429": 0,
    "public_busy": 0,
    "public_timeout": 0,
    "probe_off_hits": 0,
}
# Gauges: name -> fn() -> int, read when the line is built.
_gauges: dict[str, Callable[[], int]] = {}


def register_counter(name: str) -> None:
    if not _NAME_RE.fullmatch(name):
        raise ValueError("invalid counter name")
    with _lock:
        _counters.setdefault(name, 0)


def incr(name: str, n: int = 1) -> None:
    """Add to a counter; an unregistered name is ignored (never raises on a hot path)."""
    with _lock:
        if name in _counters:
            _counters[name] += n


def register_gauge(name: str, fn: Callable[[], int]) -> None:
    """Register (or replace) a gauge; ``fn`` runs in a worker thread at emit time."""
    if not _NAME_RE.fullmatch(name):
        raise ValueError("invalid gauge name")
    with _lock:
        _gauges[name] = fn


def snapshot_and_reset() -> dict[str, int]:
    with _lock:
        snap = dict(_counters)
        for k in _counters:
            _counters[k] = 0
    return snap


def _outbox_backlog() -> int:
    from db import DBManager

    db = DBManager()
    try:
        db.cur.execute("SELECT count(*) FROM pending_s3_deletes")
        return int(db.cur.fetchone()[0])
    finally:
        db.close()


register_gauge("outbox_backlog", _outbox_backlog)
# JRQ replaces this with the real count of pending join requests.
register_gauge("pending_join_requests", lambda: 0)


def build_line() -> str:
    """Synchronous: reads gauges (may touch the DB) and resets the counters."""
    values = snapshot_and_reset()
    with _lock:
        gauges = dict(_gauges)
    for name, fn in gauges.items():
        try:
            values[name] = int(fn())
        except Exception:  # noqa: BLE001 - a gauge must never break the line
            values[name] = -1
    return "FEATURE_SUMMARY " + " ".join(f"{k}={v}" for k, v in values.items())


def emit() -> None:
    logger.info(build_line())


async def run_feature_summary_job() -> None:
    """Scheduler entry: thin async wrapper, sync work off the event loop."""
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, emit)
