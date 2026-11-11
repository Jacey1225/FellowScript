"""Atomic friend-request acceptance (task 20261030-user-profiles, security D1).

Accepting a friendship must require a pending request FROM the target TO the
caller. The request row is consumed with ``DELETE ... RETURNING`` inside one
transaction, which both proves it existed and locks it against a concurrent
accept or block cleanup; the block / suspended re-check, the two ``user_friends``
inserts and the reverse-request cleanup all commit together or not at all.
Every refusal (unknown user, suspended, blocked, no pending request) is the same
``False`` so callers can return one uniform response (no existence or block
oracle).
"""
from __future__ import annotations

import logging

from psycopg2 import Error as PgError

from backend.errors import SaveFailedError

logger = logging.getLogger(__name__)

REFUSED_DETAIL = "No pending friend request found"


def accept_pending_request(conn, cur, caller_id: str, target_id: str) -> bool:
    """True if ``caller_id`` and ``target_id`` are friends afterwards.

    Idempotent only when the friendship row already exists (and the pair is not
    blocked). Raises ``SaveFailedError`` on a database error (nothing committed).
    """
    try:
        cur.execute(
            "DELETE FROM friend_requests WHERE to_user_id = %s AND from_user_id = %s RETURNING 1",
            (caller_id, target_id),
        )
        had_request = cur.fetchone() is not None
        cur.execute(
            "SELECT (SELECT COUNT(*) FROM users WHERE _id = %s AND suspended_at IS NULL), "
            "EXISTS(SELECT 1 FROM blocked_users WHERE (blocker_id = %s AND blocked_id = %s) "
            "OR (blocker_id = %s AND blocked_id = %s))",
            (target_id, caller_id, target_id, target_id, caller_id),
        )
        target_ok, blocked = cur.fetchone()
        if not target_ok or blocked:
            conn.rollback()
            logger.info("PROFILE_AUDIT event=accept_refused actor=%s reason=%s", caller_id,
                        "blocked" if blocked else "unavailable")
            return False
        if not had_request:
            cur.execute(
                "SELECT 1 FROM user_friends WHERE user_id = %s AND friend_id = %s",
                (caller_id, target_id),
            )
            already = cur.fetchone() is not None
            conn.rollback()
            if not already:
                logger.info("PROFILE_AUDIT event=accept_refused actor=%s reason=no_pending_request", caller_id)
            return already
        cur.execute(
            "INSERT INTO user_friends (user_id, friend_id) VALUES (%s, %s), (%s, %s) ON CONFLICT DO NOTHING",
            (caller_id, target_id, target_id, caller_id),
        )
        cur.execute(
            "DELETE FROM friend_requests WHERE to_user_id = %s AND from_user_id = %s",
            (target_id, caller_id),
        )
        conn.commit()
        return True
    except PgError as e:
        conn.rollback()
        logger.error("DB_WRITE_FAILURE op=accept_friend error=%s", type(e).__name__)
        raise SaveFailedError() from e
