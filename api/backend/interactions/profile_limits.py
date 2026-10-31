"""Per-user rate limits for the profile feature (task 20261030-user-profiles, D6).

slowapi's default key is the client IP, which is weak for authenticated abuse,
so the per-user limits use the shared limiter's storage directly
(``limiter.limiter.hit``), the same pattern as ``routes/reports.py``. The
numbers come from ``config/profile.json``. Storage is the limiter's in-memory
store: per process, reset on restart, so limits are approximate across workers.

Scope is limited to the three named threats: friend-request spam, bio abuse and
profile enumeration. Nothing here logs request content; trips are logged with
the actor id and the limit name only.
"""
from __future__ import annotations

import logging
import threading
import time

from fastapi import Depends, HTTPException, Request
from limits import parse as parse_rate

from backend.auth.dependencies import get_current_user
from backend.interactions.profile_config import get_profile_config
from backend.rate_limiting import limiter

logger = logging.getLogger(__name__)

TOO_MANY = "You're going a little fast. Please try again in a bit."

_distinct_lock = threading.Lock()
_distinct_seen: dict[str, dict[str, float]] = {}


def _hit(rate_key: str, namespace: str, user_id: str) -> bool:
    """True if the call is allowed (counted), False once over the limit."""
    rate = parse_rate(get_profile_config().rate_limits[rate_key])
    return bool(limiter.limiter.hit(rate, namespace, user_id))


def _too_many(user_id: str, limit_name: str) -> HTTPException:
    logger.warning("PROFILE_AUDIT event=rate_limited actor=%s limit=%s", user_id, limit_name)
    return HTTPException(status_code=429, detail=TOO_MANY)


def check_all(user_id: str, specs: tuple[tuple[str, str], ...]) -> None:
    """Apply ``(rate_key, namespace)`` limits in order; raise 429 on the first trip."""
    for rate_key, namespace in specs:
        if not _hit(rate_key, namespace, user_id):
            raise _too_many(user_id, rate_key)


def check_distinct_profile(user_id: str, target_id: str) -> None:
    """Enumeration sweep guard: cap distinct profile ids read per user per window."""
    cfg = get_profile_config()
    now = time.monotonic()
    horizon = now - cfg.distinct_profile_window_seconds
    with _distinct_lock:
        seen = _distinct_seen.setdefault(user_id, {})
        for tid in [t for t, ts in seen.items() if ts < horizon]:
            del seen[tid]
        if target_id not in seen and len(seen) >= cfg.distinct_profile_cap:
            over = True
        else:
            seen[target_id] = now
            over = False
        if len(_distinct_seen) > 20000:  # bound memory: drop idle users
            for uid in [u for u, m in _distinct_seen.items() if not m]:
                del _distinct_seen[uid]
    if over:
        raise _too_many(user_id, "distinct_profile_cap")


def reset_for_tests() -> None:
    with _distinct_lock:
        _distinct_seen.clear()


def friend_request_guard(request: Request) -> None:
    """Route dependency for every friend-request entry point (legacy and id-keyed)."""
    user_id = get_current_user(request)
    check_all(user_id, (
        ("friend_request_hour", "profile-friend-request-hour"),
        ("friend_request_day", "profile-friend-request-day"),
    ))


def friend_accept_guard(request: Request) -> None:
    """Route dependency for every friend-accept entry point."""
    user_id = get_current_user(request)
    check_all(user_id, (("friend_accept_hour", "profile-friend-accept-hour"),))


def friend_decline_guard(request: Request) -> None:
    """Route dependency for the recipient-only friend-request decline."""
    user_id = get_current_user(request)
    check_all(user_id, (("friend_decline_hour", "profile-friend-decline-hour"),))


friend_decline_dependency = Depends(friend_decline_guard)
friend_request_dependency = Depends(friend_request_guard)
friend_accept_dependency = Depends(friend_accept_guard)
