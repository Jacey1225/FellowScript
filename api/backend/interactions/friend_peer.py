"""Friend-scoped reads for DM threads (task 20261030-user-profiles, security D4).

Kept out of ``friends.py``. ``dm_peer`` is the single gate for reading a DM
thread or a friend's data: the target must be an existing, unblocked friend of
the caller. Every refusal is the same ``None`` so routes return one uniform 404
(a stranger can no longer read another user's row or probe for existence).
``friend_view`` is an allow-list projection that never includes email or any
other private column.
"""
from __future__ import annotations

import uuid

from backend.interactions.attachments import generate_download_url
from backend.interactions.blocks import BlockManager


def dm_peer(manager, friend_id: str) -> dict | None:
    """The friend's users row, or None unless ``friend_id`` is a friend of
    ``manager.user_id`` who exists and is not blocked either way."""
    try:
        uuid.UUID(str(friend_id))
    except ValueError:
        return None
    manager.cur.execute(
        "SELECT 1 FROM user_friends WHERE user_id = %s AND friend_id = %s",
        (manager.user_id, friend_id),
    )
    is_friend = manager.cur.fetchone() is not None
    manager.conn.rollback()
    if not is_friend:
        return None
    result = manager.lookup("users", {"_id": friend_id})
    if not result:
        return None
    blocks = BlockManager(manager.user_id)
    try:
        if blocks.is_blocked(friend_id):
            return None
    finally:
        blocks.close()
    return list(result.values())[0]


def friend_view(friend_id: str, friend_data: dict) -> dict:
    """Allow-list projection of a friend's raw users row."""
    return {
        "user_id": str(friend_id),
        "username": friend_data.get("username", ""),
        "profile_photo_url": generate_download_url(friend_data.get("profile_photo_key")),
        "bio": friend_data.get("bio"),
    }
