"""User profile routes (task 20261030-user-profiles).

* ``GET  /profiles/{target_id}``              tiered profile read
* ``PUT  /profile/{user_id}/bio``             edit own bio
* ``POST /profiles/{target_id}/friend-request``  id-keyed request
* ``POST /profiles/{target_id}/friend-accept``   id-keyed accept

Every route has an explicit auth dependency (deny-by-default). The caller id
always comes from the session; blocked, suspended and unknown targets are one
identical 404; the bio text and request bodies are never logged.
"""
from __future__ import annotations

import logging
import uuid

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field

from backend.auth.dependencies import get_current_user, require_match
from backend.interactions import friend_request_notifier
from backend.interactions.friend_accept import REFUSED_DETAIL
from backend.interactions.friends import FriendsManager
from backend.interactions.profile import ProfileManager
from backend.interactions.profile_bio import BioRejected, validate_bio
from backend.interactions.profile_config import BIO_REQUEST_CEILING, get_profile_config
from backend.interactions.profile_limits import (
    check_all, check_distinct_profile, friend_accept_dependency, friend_request_dependency,
)
from backend.rate_limiting import limiter

logger = logging.getLogger(__name__)

profile_router = APIRouter()

NOT_FOUND = "User not found"


class BioUpdate(BaseModel):
    """Strict body: unknown fields are rejected (no mass assignment)."""

    model_config = ConfigDict(extra="forbid")
    bio: str | None = Field(max_length=BIO_REQUEST_CEILING)


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(str(value))
        return True
    except ValueError:
        return False


@profile_router.get("/profiles/{target_id}")
@limiter.limit(lambda: get_profile_config().rate_limits["profile_read_ip"])
def read_profile(request: Request, target_id: str, current_user: str = Depends(get_current_user)) -> dict:
    """Tiered profile of ``target_id`` as seen by the signed-in caller.

    Returns ``{user_id, username, profile_photo_url, relationship: {state},
    editable}`` plus ``bio`` for self and friends only (absent for strangers).
    ``relationship.state`` is one of self | friends | request_sent |
    request_received | none.

    Raises:
        HTTPException 404: Unknown, malformed, suspended or blocked (either
            direction) target, or a suspended viewer: all identical.
        HTTPException 429: Over the read rate limit or the distinct-profile cap.
    """
    is_self = target_id == current_user
    if not is_self:
        check_all(current_user, (("profile_read_user", "profile-read"),))
    if not _is_uuid(target_id):
        raise HTTPException(status_code=404, detail=NOT_FOUND)
    if not is_self:
        check_distinct_profile(current_user, target_id)
    manager = ProfileManager(current_user)
    try:
        profile = manager.get_profile(target_id)
    finally:
        manager.close()
    if profile is None:
        logger.info("PROFILE_AUDIT event=profile_unavailable actor=%s", current_user)
        raise HTTPException(status_code=404, detail=NOT_FOUND)
    return profile


@profile_router.put("/profile/{user_id}/bio")
def update_bio(user_id: str, body: BioUpdate, current_user: str = Depends(require_match("user_id"))) -> dict:
    """Create, change or clear (``null`` / blank) the caller's own bio.

    Raises:
        HTTPException 403: Not your profile, suspended, or Terms not accepted.
        HTTPException 422: Too long, link/markup, or rejected by the content filter.
        HTTPException 429: Over the bio-edit rate limits.
    """
    check_all(current_user, (
        ("bio_edit_burst", "profile-bio-burst"),
        ("bio_edit_hour", "profile-bio-hour"),
    ))
    manager = ProfileManager(current_user)
    try:
        refusal = manager.bio_write_gate()
        if refusal == "terms":
            raise HTTPException(status_code=403, detail="Please accept the latest Terms to edit your bio.")
        if refusal:
            raise HTTPException(status_code=403, detail="Forbidden")
        try:
            bio = validate_bio(body.bio, get_profile_config().bio_max_length)
        except BioRejected as e:
            logger.info("PROFILE_AUDIT event=bio_rejected actor=%s reason=%s", current_user, e.code)
            raise HTTPException(status_code=422, detail=e.message) from None
        manager.set_bio(bio)
    finally:
        manager.close()
    logger.info("PROFILE_AUDIT event=bio_updated actor=%s cleared=%s", current_user, bio is None)
    return {"bio": bio}


@profile_router.post("/profiles/{target_id}/friend-request", status_code=204,
                     dependencies=[friend_request_dependency])
def request_friend(target_id: str, background: BackgroundTasks, current_user: str = Depends(get_current_user)) -> Response:
    """Send a friend request by user id. Same uniform semantics as the legacy
    username route: 204 whether or not the target exists, is blocked or
    suspended; 400 only for a request to yourself; 429 over limits/cap.
    Clients refetch ``GET /profiles/{id}`` for the resulting state."""
    if not _is_uuid(target_id):
        return Response(status_code=204)
    manager = FriendsManager(current_user)
    try:
        result = manager.send_add_request_by_id(target_id)
        if result and "error" in result:
            raise HTTPException(status_code=result.get("status", 400), detail=result["error"])
        if manager.new_request_recipient_id:  # essential push, never fails the request
            background.add_task(friend_request_notifier.notify_friend_request,
                                manager.new_request_recipient_id, current_user)
    finally:
        manager.close()
    return Response(status_code=204)


@profile_router.post("/profiles/{target_id}/friend-accept", status_code=204,
                     dependencies=[friend_accept_dependency])
def accept_friend(target_id: str, current_user: str = Depends(get_current_user)) -> Response:
    """Accept a pending request from ``target_id`` by user id (security D1).

    Raises:
        HTTPException 404: Uniform refusal: unknown, blocked, suspended, or no
            pending request from that user.
    """
    if not _is_uuid(target_id):
        raise HTTPException(status_code=404, detail=REFUSED_DETAIL)
    manager = FriendsManager(current_user)
    try:
        result = manager.add_friend_by_id(target_id)
    finally:
        manager.close()
    if result and "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return Response(status_code=204)
