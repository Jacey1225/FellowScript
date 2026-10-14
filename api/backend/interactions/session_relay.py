"""Presence tracking and the deterministic "designated transcript relay" rule
for live-call transcription (task 20261013-session-call-live-transcript-summary,
backend step 2).

Chime delivers transcript text only to attendee clients, so exactly ONE client
per call forwards it to the server. The server, not the client, decides which:

  1. The session creator, if present in the call and eligible.
  2. Otherwise the earliest-joined remaining present, eligible participant.

"Present" = joined via a call-join endpoint (or re-joined) and not left, and
seen (join, relay-status poll, or ingest) within ``relay_stale_seconds``. A
client that crashes therefore loses the role after the stale window without
needing a leave signal. "Eligible" = the caller-supplied predicate (paid plan,
fail closed). The rule is re-evaluated on every call, so the role moves to the
next participant when the creator drops and returns to the creator if they
re-join. Ingest rejects anyone who is not the current relay.

State is in-process memory only (same single-worker limitation as
session_transcript). It holds user ids and timestamps, never transcript text.
"""
from __future__ import annotations

import itertools
import threading
import time
from typing import Callable

from backend.interactions.session_transcription_config import get_session_transcription_config

_lock = threading.Lock()
_seq = itertools.count()
_presence: dict[str, dict[str, dict]] = {}   # session -> user -> {"order": int, "seen": float}
_ingest_log: dict[str, list[float]] = {}      # session -> request timestamps (last 60s)


def _now() -> float:
    return time.time()


def _is_fresh(entry: dict, now: float, stale: int) -> bool:
    return now - entry["seen"] <= stale


def _purge_locked(now: float) -> None:
    ttl = get_session_transcription_config().ttl_seconds
    for sid in list(_presence):
        users = _presence[sid]
        for uid in [u for u, e in users.items() if now - e["seen"] > ttl]:
            del users[uid]
        if not users:
            del _presence[sid]
    for sid in list(_ingest_log):
        if sid not in _presence:
            del _ingest_log[sid]


def record_join(session_id: str, user_id: str) -> None:
    """A user joined (or re-joined) the call. A stale/left prior entry counts
    as a fresh join, so a re-joiner goes to the back of the fallback order."""
    stale = get_session_transcription_config().relay_stale_seconds
    with _lock:
        now = _now()
        _purge_locked(now)
        users = _presence.setdefault(session_id, {})
        cur = users.get(user_id)
        if cur is None or not _is_fresh(cur, now, stale):
            users[user_id] = {"order": next(_seq), "seen": now}
        else:
            cur["seen"] = now


def touch(session_id: str, user_id: str) -> bool:
    """Proof of life for a user who is still in the call. False (and no
    change) when they never joined, left, or already went stale: they must
    re-join through the join endpoint."""
    stale = get_session_transcription_config().relay_stale_seconds
    with _lock:
        now = _now()
        entry = _presence.get(session_id, {}).get(user_id)
        if entry is None or not _is_fresh(entry, now, stale):
            return False
        entry["seen"] = now
        return True


def record_leave(session_id: str, user_id: str) -> None:
    with _lock:
        users = _presence.get(session_id)
        if users:
            users.pop(user_id, None)
            if not users:
                del _presence[session_id]


def present_users(session_id: str) -> list[str]:
    """Fresh participants, earliest-joined first."""
    stale = get_session_transcription_config().relay_stale_seconds
    with _lock:
        now = _now()
        users = _presence.get(session_id, {})
        fresh = [(e["order"], u) for u, e in users.items() if _is_fresh(e, now, stale)]
    return [u for _, u in sorted(fresh)]


def others_present(session_id: str, user_id: str, is_eligible: Callable[[str], bool]) -> bool:
    """True if any user other than ``user_id`` is still present and eligible
    (fail closed on predicate errors: an erroring candidate does not count)."""
    for uid in present_users(session_id):
        if uid == str(user_id):
            continue
        try:
            if is_eligible(uid):
                return True
        except Exception:
            continue
    return False


def designated_relay(session_id: str, creator_id: str, is_eligible: Callable[[str], bool]) -> str | None:
    """The one user allowed to ingest right now, or None. Creator first, then
    join order; a candidate whose eligibility check is False or raises is
    skipped (fail closed)."""
    present = present_users(session_id)
    creator_id = str(creator_id or "")
    ordered = ([creator_id] if creator_id in present else []) + [u for u in present if u != creator_id]
    for uid in ordered:
        try:
            if is_eligible(uid):
                return uid
        except Exception:
            continue
    return None


def allow_ingest_request(session_id: str) -> bool:
    """Per-session sliding-window limit (ingest_max_requests_per_minute)."""
    limit = get_session_transcription_config().ingest_max_requests_per_minute
    with _lock:
        now = _now()
        log = [t for t in _ingest_log.get(session_id, []) if now - t < 60]
        if len(log) >= limit:
            _ingest_log[session_id] = log
            return False
        log.append(now)
        _ingest_log[session_id] = log
        return True


def clear(session_id: str) -> None:
    with _lock:
        _presence.pop(session_id, None)
        _ingest_log.pop(session_id, None)


def reset_for_tests() -> None:
    with _lock:
        _presence.clear()
        _ingest_log.clear()
