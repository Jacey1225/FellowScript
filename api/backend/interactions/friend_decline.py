"""Recipient-only decline of a pending friend request (task 20261030-profile-everywhere, step 11).

Deletes the pending ``friend_requests`` row addressed TO the caller FROM the
target. Nothing else is touched: no friendship, no block, no cooldown row. The
caller id always comes from the session, so only a request's recipient can
remove it. The function reports nothing about whether a row existed, so the
route returns one uniform 204 (unknown / blocked / suspended / no request alike).
"""
from __future__ import annotations

import logging

from psycopg2 import Error as PgError

from backend.errors import SaveFailedError

logger = logging.getLogger(__name__)


def decline_pending_request(conn, cur, caller_id: str, sender_id: str) -> None:
    """Delete the request from ``sender_id`` to ``caller_id`` if present.

    Raises ``SaveFailedError`` on a database error (nothing committed).
    """
    try:
        cur.execute(
            "DELETE FROM friend_requests WHERE to_user_id = %s::uuid AND from_user_id = %s::uuid",
            (caller_id, sender_id),
        )
        conn.commit()
    except PgError:
        conn.rollback()
        logger.exception("PROFILE_AUDIT event=decline_failed actor=%s", caller_id)
        raise SaveFailedError("Could not decline the friend request") from None
    # Same line whether or not a row existed: no existence oracle in the logs.
    logger.info("PROFILE_AUDIT event=friend_declined actor=%s", caller_id)
