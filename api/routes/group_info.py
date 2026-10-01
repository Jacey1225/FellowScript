"""Group info panel endpoints (task 20260929-group-info-panel).

Rename, group photo (presigned upload/confirm/remove), per-user mute, and
the attachment gallery. Every route is authenticated + self-scoped
(``require_match``) and *member-only*: deny-by-default with a 403 for a
non-member, checked before anything else touches the group. Any member may
rename or change the photo -- the same rule ``PUT /groups/{user_id}/{group_id}``
already applies; this router does not alter the permission model.

Photo flow mirrors ``routes/profile_photo.py``: the client asks for a
presigned S3 POST policy, uploads directly to S3 (the server never receives
bytes), then confirms; ``confirm`` re-validates the key belongs to *this*
group before persisting it.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, StrictInt

from backend.auth.dependencies import require_match
from backend.interactions.attachments import AttachmentConfigError, delete_object, generate_download_url
from backend.interactions.group_photo import generate_group_photo_upload_policy, is_group_photo_key
from backend.interactions.groups import GALLERY_PAGE_SIZE, GroupOwnerOnlyError, GroupsManager
from backend.interactions.invites import audit as invite_audit
from backend.interactions.invites_config import MIN_GROUP_MEMBERS_CAP, get_invites_config
from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message
from backend.rate_limiting import get_client_ip, limiter

group_info_router = APIRouter(prefix="/groups")
logger = logging.getLogger(__name__)


class GroupTitleRequest(BaseModel):
    """PUT /groups/{user_id}/{group_id}/title body."""
    title: str


class GroupMaxMembersRequest(BaseModel):
    """PUT .../max-members body. ``null`` clears the cap. StrictInt so a JSON
    bool/float/string is a 422, never coerced."""
    max_members: StrictInt | None = None


class GroupPhotoUploadUrlRequest(BaseModel):
    """POST .../photo/upload-url body. ``size_bytes`` is advisory only; real
    enforcement is the presigned policy's content-length-range."""
    content_type: str
    size_bytes: int | None = None


class GroupPhotoConfirmRequest(BaseModel):
    """POST .../photo/confirm body. Also used to restore a just-removed photo
    with the ``restore_key`` the remove call returned."""
    object_key: str


def _require_member(manager: GroupsManager) -> None:
    if not manager.is_member():
        raise HTTPException(status_code=403, detail="Not a member of this group")


@group_info_router.get("/{user_id}/{group_id}/info")
async def fetch_group_info(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Lightweight panel header data: title, photo, this caller's mute state,
    and the member roster (usernames).

    Returns:
        dict: ``{"group_id", "title", "photo_url" (None = initials
        fallback), "muted", "members", "max_members" (None = unlimited),
        "member_count", "is_owner", "max_members_ceiling"}``.

    Raises:
        HTTPException 403: caller is not a member. 404: group vanished.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
        exists, photo_key = manager.get_photo_key()
        group = manager.lookup("groups", {"_id": group_id})
        if not exists or not group:
            raise HTTPException(status_code=404, detail="Group not found")
        _, data = list(group.items())[0]
        member_ids = data.get("users") or []
        members: list[str] = []
        if member_ids:
            manager.cur.execute(
                "SELECT username FROM users WHERE _id = ANY(%s::uuid[]) ORDER BY username",
                (member_ids,),
            )
            members = [r[0] for r in manager.cur.fetchall()]
        max_members, is_owner, member_count = manager.get_member_cap_info()
        return {
            "group_id": group_id,
            "title": data.get("title", ""),
            "photo_url": generate_download_url(photo_key),
            "muted": manager.is_muted(),
            "members": members,
            "max_members": max_members,
            "member_count": member_count,
            "is_owner": is_owner,
            "max_members_ceiling": get_invites_config().max_group_members_ceiling,
        }
    finally:
        manager.close()


@group_info_router.put("/{user_id}/{group_id}/title")
@limiter.limit("30/minute")
async def rename_group(
    request: Request, user_id: str, group_id: str, body: GroupTitleRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Rename the group (title only; members untouched).

    Raises:
        HTTPException 403: not a member. 422: blank/overlong title or
        content-filter rejection.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
        try:
            check_clean(title=body.title)
        except ContentRejected as e:
            raise HTTPException(status_code=422, detail=rejection_message(e))
        try:
            title = manager.rename_group(body.title)
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
        return {"group_id": group_id, "title": title}
    finally:
        manager.close()


@group_info_router.put("/{user_id}/{group_id}/max-members")
@limiter.limit("30/minute")
async def set_group_max_members(
    request: Request, user_id: str, group_id: str, body: GroupMaxMembersRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Set or clear (``null``) the group's member cap. Group creator only.

    Raises:
        HTTPException 403: not a member, or not the group's creator.
        422: not an integer, outside the configured range, or below the
        group's current member count.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
        try:
            manager.set_max_members(
                body.max_members, get_invites_config().max_group_members_ceiling, MIN_GROUP_MEMBERS_CAP)
        except GroupOwnerOnlyError:
            raise HTTPException(status_code=403, detail="Only the group owner can change this")
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
        invite_audit("set_max_members", target=group_id, user=user_id,
                     max_members=body.max_members if body.max_members is not None else "none",
                     ip=get_client_ip(request))
        return {"group_id": group_id, "max_members": body.max_members}
    finally:
        manager.close()


@group_info_router.post("/{user_id}/{group_id}/photo/upload-url")
@limiter.limit("30/minute")
async def request_group_photo_upload_url(
    request: Request, user_id: str, group_id: str, info: GroupPhotoUploadUrlRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Issue a presigned S3 POST policy for a group-photo upload.

    Raises:
        HTTPException 400: unsupported content_type. 403: not a member.
        503: uploads not configured.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
    finally:
        manager.close()
    try:
        return generate_group_photo_upload_policy(user_id, group_id, info.content_type)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except AttachmentConfigError as e:
        logger.error("Group-photo upload requested but not configured: %s", e)
        raise HTTPException(status_code=503, detail="Group photo uploads are not available right now.")


@group_info_router.post("/{user_id}/{group_id}/photo/confirm")
@limiter.limit("30/minute")
async def confirm_group_photo(
    request: Request, user_id: str, group_id: str, info: GroupPhotoConfirmRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Persist a completed upload's key as the group's photo.

    Fails closed (403) unless ``object_key`` falls under this group's own
    ``group-photos/{group_id}/`` prefix -- another group's key, a user's
    profile-photo key, or a message attachment key can never be attached.
    The replaced photo object, if any, is deleted best-effort.

    Raises:
        HTTPException 403: not a member, or key not under this group's prefix.
        404: group no longer exists.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
        if not is_group_photo_key(group_id, info.object_key):
            raise HTTPException(status_code=403, detail="Invalid photo reference")
        exists, old_key = manager.get_photo_key()
        if not exists:
            raise HTTPException(status_code=404, detail="Group not found")
        manager.set_photo_key(info.object_key)
    finally:
        manager.close()
    if old_key and old_key != info.object_key:
        delete_object(old_key)
    return {"photo_url": generate_download_url(info.object_key)}


@group_info_router.delete("/{user_id}/{group_id}/photo")
@limiter.limit("30/minute")
async def remove_group_photo(
    request: Request, user_id: str, group_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Clear the group's photo (back to the initials fallback).

    The S3 object is deliberately NOT deleted here so the client can offer
    undo-after-the-fact: it restores by calling ``photo/confirm`` with the
    returned ``restore_key``. The object is deleted when a later confirm
    replaces it, or by the orphan sweep noted in the rollout plan.
    Idempotent: no photo set returns ``{"restore_key": None}``.

    Raises:
        HTTPException 403: not a member. 404: group no longer exists.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
        exists, old_key = manager.get_photo_key()
        if not exists:
            raise HTTPException(status_code=404, detail="Group not found")
        if old_key:
            manager.set_photo_key(None)
        return {"restore_key": old_key}
    finally:
        manager.close()


@group_info_router.put("/{user_id}/{group_id}/mute")
async def mute_group(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Mute push notifications for this group, for the caller only.
    Messages still arrive in-thread and the unread badge is unchanged.
    Idempotent.

    Raises:
        HTTPException 403: not a member.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
        manager.set_muted(True)
        return {"muted": True}
    finally:
        manager.close()


@group_info_router.delete("/{user_id}/{group_id}/mute")
async def unmute_group(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """Unmute this group for the caller. Idempotent.

    Raises:
        HTTPException 403: not a member.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
        manager.set_muted(False)
        return {"muted": False}
    finally:
        manager.close()


@group_info_router.get("/{user_id}/{group_id}/gallery")
async def fetch_group_gallery(
    user_id: str,
    group_id: str,
    kind: str | None = Query(default=None, description="Filter: image, video, gif, or file; omit for all"),
    cursor_timestamp: str | None = Query(default=None, description="next_cursor_timestamp from the previous page; supply with cursor_id"),
    cursor_id: str | None = Query(default=None, description="next_cursor_id from the previous page; supply with cursor_timestamp"),
    _: str = Depends(require_match("user_id")),
) -> dict:
    """One page (``GALLERY_PAGE_SIZE``) of the group's attachments, newest
    first. Blocked users' attachments are excluded. See
    ``GroupsManager.fetch_gallery`` for the response shape.

    Raises:
        HTTPException 403: not a member. 422: bad kind or cursor.
    """
    manager = GroupsManager(user_id, group_id)
    try:
        _require_member(manager)
        try:
            return manager.fetch_gallery(
                kind=kind, limit=GALLERY_PAGE_SIZE,
                cursor_timestamp=cursor_timestamp, cursor_id=cursor_id,
            )
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
    finally:
        manager.close()
