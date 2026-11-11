"""Profile reads and bio writes (task 20261030-user-profiles, security D2/D3/D7).

Everything returned for another user comes from an explicit allow-list built
here; no ``SELECT *`` row is ever passed through. Relationship state is derived
from ``user_friends`` / ``friend_requests`` / ``blocked_users`` in the same
single query that checks visibility, so a blocked or suspended target is
indistinguishable from a nonexistent one (``get_profile`` returns None for all
of them). The bio text is never logged.
"""
from __future__ import annotations

import logging
import uuid

from db import DBManager
from backend.interactions.attachments import generate_download_url
from schemas.users import CURRENT_TERMS_VERSION

logger = logging.getLogger(__name__)

_PROFILE_SQL = (
    "SELECT u.username, u.profile_photo_key, u.bio, "
    "EXISTS(SELECT 1 FROM user_friends WHERE user_id = %(v)s AND friend_id = u._id), "
    "EXISTS(SELECT 1 FROM friend_requests WHERE from_user_id = %(v)s AND to_user_id = u._id), "
    "EXISTS(SELECT 1 FROM friend_requests WHERE from_user_id = u._id AND to_user_id = %(v)s), "
    "EXISTS(SELECT 1 FROM blocked_users WHERE (blocker_id = %(v)s AND blocked_id = u._id) "
    "OR (blocker_id = u._id AND blocked_id = %(v)s)), "
    "COALESCE((SELECT suspended_at IS NOT NULL FROM users WHERE _id = %(v)s), TRUE) "
    "FROM users u WHERE u._id = %(t)s AND u.suspended_at IS NULL"
)


class ProfileManager(DBManager):
    """Profile reads for a viewer and bio writes for that same user."""

    def __init__(self, viewer_id: str) -> None:
        super().__init__()
        self.viewer_id = viewer_id

    def get_profile(self, target_id: str) -> dict | None:
        """The viewer's tiered view of ``target_id``, or None (callers answer 404)
        if the target is missing, suspended or blocked either way, or the viewer
        is suspended/missing.

        Tiers: stranger -> user_id, username, profile_photo_url, relationship;
        friend -> plus ``bio`` (None when unset); self -> plus ``bio`` and
        ``editable``. ``bio`` is ABSENT, not null, for a stranger.
        """
        self.cur.execute(_PROFILE_SQL, {"v": self.viewer_id, "t": target_id})
        row = self.cur.fetchone()
        self.conn.rollback()
        if row is None:
            return None
        username, photo_key, bio, is_friend, sent, received, blocked, viewer_suspended = row
        is_self = str(target_id) == str(self.viewer_id)
        if viewer_suspended or (blocked and not is_self):
            return None
        if is_self:
            state = "self"
        elif is_friend:
            state = "friends"
        elif received:
            state = "request_received"
        elif sent:
            state = "request_sent"
        else:
            state = "none"
        out = {
            "user_id": str(target_id),
            "username": username,
            "profile_photo_url": generate_download_url(photo_key),
            "relationship": {"state": state},
            "editable": is_self,
        }
        if is_self or is_friend:
            out["bio"] = bio
        return out

    def bio_write_gate(self) -> str | None:
        """None if the viewer may edit their bio, else a short refusal reason."""
        self.cur.execute(
            "SELECT suspended_at IS NOT NULL, terms_accepted_at IS NOT NULL, terms_version "
            "FROM users WHERE _id = %s",
            (self.viewer_id,),
        )
        row = self.cur.fetchone()
        self.conn.rollback()
        if row is None or row[0]:
            return "unavailable"
        if not row[1] or row[2] != CURRENT_TERMS_VERSION:
            return "terms"
        return None

    def set_bio(self, bio: str | None) -> None:
        """Write the viewer's own bio (already validated). Raises on DB error so
        the route never reports a save that did not land."""
        try:
            self.cur.execute("UPDATE users SET bio = %s WHERE _id = %s", (bio, self.viewer_id))
            if self.cur.rowcount != 1:
                raise RuntimeError("bio update matched no row")
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise


def public_identity(target_id: str) -> dict | None:
    """Allow-list identity (user_id, username, profile_photo_url) for the legacy
    ``GET /user/{id}``, or None if the user does not exist."""
    try:
        uuid.UUID(str(target_id))
    except ValueError:
        return None
    db = DBManager()
    try:
        db.cur.execute("SELECT username, profile_photo_key FROM users WHERE _id = %s", (target_id,))
        row = db.cur.fetchone()
        db.conn.rollback()
    finally:
        db.close()
    if row is None:
        return None
    return {
        "user_id": str(target_id),
        "username": row[0],
        "profile_photo_url": generate_download_url(row[1]),
    }


def legacy_user_view(target_id: str, is_self: bool, self_data: dict | None) -> dict | None:
    """Response for the legacy ``GET /user/{id}`` (security D2).

    Other users: an allow-list of user_id, username and profile_photo_url plus
    the historical blank keys (email "", mfa_enabled false, friend_requests [],
    suspended_at null) kept only so older clients' decoders (iOS FSUser requires
    ``email``) keep working. Self: the existing owner record (``self_data``,
    minus hash_pass and the raw photo key) plus ``bio``. Bio is never returned
    for another user here; use ``GET /profiles/{id}``.
    """
    if is_self:
        if self_data is None:
            return None
        data = {k: v for k, v in self_data.items() if k not in ("hash_pass", "profile_photo_key")}
        data["profile_photo_url"] = generate_download_url(self_data.get("profile_photo_key"))
        data["bio"] = _own_bio(target_id)
        return {"user_id": target_id, **data}
    ident = public_identity(target_id)
    if ident is None:
        return None
    return {
        **ident,
        "email": "",
        "mfa_enabled": False,
        "friend_requests": [],
        "suspended_at": None,
    }


def _own_bio(user_id: str) -> str | None:
    db = DBManager()
    try:
        db.cur.execute("SELECT bio FROM users WHERE _id = %s", (user_id,))
        row = db.cur.fetchone()
        db.conn.rollback()
    finally:
        db.close()
    return row[0] if row else None
