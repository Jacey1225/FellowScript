"""Isolation and load shedding for the public (unauthenticated) Explorer API.

Why this exists: ``get_current_user`` and every plain ``def`` route share
anyio's default 40-token thread limiter. Public, scrape-able endpoints that
ran their blocking psycopg2 work there could starve the whole API. Public
handlers are therefore thin ``async def`` functions that call
``await run_public(sync_impl, ...)``: the sync work runs on a DEDICATED
``anyio.CapacityLimiter``, so saturating it leaves the default pool (auth,
WebSocket, capabilities) untouched.

Rules baked in (contract-v2 section 6.8, decision J25):
* No hard-coded defaults live here. ``configure(concurrency, max_waiting)`` is
  called exactly once at startup by the listings config validator; ``run_public``
  before that raises ``RuntimeError`` (config stays the single source).
* Overload and statement timeouts answer 429 ``{"code": "busy"}`` with a
  ``Retry-After`` header, never 5xx: the CloudWatch watchdog treats every
  nginx 5xx line as a detection that can cost an LLM triage call.
* Statement timeouts are counted in-process and surfaced as ONE aggregated
  WARNING per minute (never ERROR, never per request, no ids or query text).
  Without it database trouble on the public API would produce no 5xx, no ERROR
  line and no watchdog signal.
"""
from __future__ import annotations

import functools
import logging
import math
import threading
import time
from contextlib import contextmanager

import anyio
import anyio.to_thread
import psycopg2
import psycopg2.errors
from fastapi import HTTPException, Request

from backend.observability import feature_summary
from backend.rate_limiting import limiter
from db import _connect

logger = logging.getLogger(__name__)

# Set ONCE by configure(); None means "not configured yet".
_concurrency: int | None = None
_max_waiting: int | None = None
_limiter: "anyio.CapacityLimiter | None" = None
# Requests admitted (running on the limiter or queued for it). Counted here,
# synchronously, because anyio's own tasks_waiting only moves after a task has
# yielded, so a burst of concurrent callers would all read 0 and none be shed.
_outstanding = 0

# Aggregated statement-timeout reporting.
_TIMEOUT_REPORT_SECONDS = 60.0
_timeout_lock = threading.Lock()
_timeout_count = 0
_timeout_window_start = time.monotonic()

GLOBAL_SCOPE = "public_global"
_GLOBAL_KEY = "public-global"


def configure(concurrency: int, max_waiting: int) -> None:
    """Set the dedicated pool size and the waiting-queue length that triggers
    shedding. Called once at startup; calling again with the same values is a
    no-op, with different values a ``RuntimeError`` (use ``reset_for_tests``).
    """
    global _concurrency, _max_waiting
    for name, value, minimum in (("concurrency", concurrency, 1), ("max_waiting", max_waiting, 0)):
        if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
            raise ValueError(f"public_guard.configure: {name} must be an int >= {minimum}")
    if _concurrency is not None:
        if (_concurrency, _max_waiting) == (concurrency, max_waiting):
            return
        raise RuntimeError("public_guard.configure() was already called with different values")
    _concurrency, _max_waiting = concurrency, max_waiting


def reset_for_tests() -> None:
    """Forget configuration, the limiter and timeout counters, and clear the
    shared rate-limit storage (so the global backstop starts empty)."""
    global _concurrency, _max_waiting, _limiter, _outstanding, _timeout_count, _timeout_window_start
    _outstanding = 0
    _concurrency = _max_waiting = None
    _limiter = None
    with _timeout_lock:
        _timeout_count = 0
        _timeout_window_start = time.monotonic()
    limiter.reset()


def _get_limiter() -> "anyio.CapacityLimiter":
    global _limiter
    if _limiter is None:
        _limiter = anyio.CapacityLimiter(_concurrency)
    return _limiter


def _busy(retry_after: int) -> HTTPException:
    return HTTPException(
        status_code=429,
        detail={"code": "busy"},
        headers={"Retry-After": str(max(1, min(5, retry_after)))},
    )


def _record_timeout() -> None:
    feature_summary.incr("public_timeout")
    feature_summary.incr("public_429")
    with _timeout_lock:
        global _timeout_count
        _timeout_count += 1
    _maybe_report_timeouts()


def _maybe_report_timeouts() -> None:
    """Emit one aggregated WARNING when a full window has elapsed and there is
    something to report; the count and window then reset."""
    global _timeout_count, _timeout_window_start
    now = time.monotonic()
    with _timeout_lock:
        if now - _timeout_window_start < _TIMEOUT_REPORT_SECONDS:
            return
        count, _timeout_count = _timeout_count, 0
        _timeout_window_start = now
    if count:
        logger.warning("Public API statement timeouts in the last minute: %d", count)


async def run_public(fn, *args):
    """Run blocking ``fn(*args)`` on the dedicated public limiter.

    Sheds with 429 ``busy`` when the waiting queue is already at
    ``max_waiting``; a database statement timeout inside ``fn`` also maps to
    429 ``busy``. Any other exception propagates unchanged.
    """
    if _concurrency is None:
        raise RuntimeError("public_guard.configure() was not called")
    _maybe_report_timeouts()
    global _outstanding
    lim = _get_limiter()
    waiting = max(0, _outstanding - _concurrency)
    if waiting >= _max_waiting:
        feature_summary.incr("public_busy")
        feature_summary.incr("public_429")
        raise _busy(math.ceil((waiting + 1) / _concurrency))
    _outstanding += 1  # no await between the check above and this increment
    try:
        return await anyio.to_thread.run_sync(functools.partial(fn, *args), limiter=lim)
    except psycopg2.errors.QueryCanceled:
        _record_timeout()
        raise _busy(1)
    finally:
        _outstanding -= 1


@contextmanager
def public_connection(statement_timeout_ms: int):
    """Dedicated per-request connection with ``SET LOCAL statement_timeout``.

    One transaction: the timeout applies to every statement in the block, the
    block commits on success, rolls back on error, and the connection is
    always closed. A timeout surfaces as ``psycopg2.errors.QueryCanceled``,
    which ``run_public`` maps to 429 ``busy``. The caller supplies the timeout
    from config (no default here).
    """
    if isinstance(statement_timeout_ms, bool) or not isinstance(statement_timeout_ms, int) or statement_timeout_ms < 1:
        raise ValueError("statement_timeout_ms must be a positive int")
    conn = _connect()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT set_config('statement_timeout', %s, true)", (str(statement_timeout_ms),))
        yield conn
        conn.commit()
    except BaseException:
        try:
            conn.rollback()
        except Exception:
            pass
        raise
    finally:
        conn.close()


def global_key(request: Request) -> str:
    """Key function with no per-client component: one bucket for everyone."""
    return _GLOBAL_KEY


def global_limit(rate):
    """Key-less global backstop shared across public routes, so rotating IPs
    cannot saturate the pool. ``rate`` is a rate string or a callable returning
    one (read from config at call time). Use as a decorator; tests clear it
    with ``reset_for_tests()`` (or ``limiter.reset()``)."""
    return limiter.shared_limit(rate, scope=GLOBAL_SCOPE, key_func=global_key)
