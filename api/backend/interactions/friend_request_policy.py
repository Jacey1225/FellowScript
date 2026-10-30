"""Eligibility rules for sending a friend request (task 20261030-user-profiles).

Kept out of ``friends.py`` (already large). A request is only recorded when the
target exists, is not suspended, is not blocked in either direction and is not
already a friend. Callers treat False as a silent no-op (security D5).
"""
from __future__ import annotations

from backend.interactions.profile_config import get_profile_config


def request_allowed(cur, caller_id: str, target_id: str) -> bool:
    cur.execute(
        "SELECT EXISTS(SELECT 1 FROM users WHERE _id = %s AND suspended_at IS NULL), "
        "EXISTS(SELECT 1 FROM blocked_users WHERE (blocker_id = %s AND blocked_id = %s) "
        "OR (blocker_id = %s AND blocked_id = %s)), "
        "EXISTS(SELECT 1 FROM user_friends WHERE user_id = %s AND friend_id = %s)",
        (target_id, caller_id, target_id, target_id, caller_id, caller_id, target_id),
    )
    exists, blocked, friends = cur.fetchone()
    return bool(exists) and not blocked and not friends


def outstanding_cap_hit(cur, caller_id: str) -> bool:
    cur.execute("SELECT COUNT(*) FROM friend_requests WHERE from_user_id = %s", (caller_id,))
    return cur.fetchone()[0] >= get_profile_config().max_outstanding_friend_requests
