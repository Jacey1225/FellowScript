"""Group announcements endpoints (task 20260929-group-announcements).

Own module (not appended to ``group_info.py``) on its own ``/groups`` router.
Every route is authenticated + self-scoped (``require_match``) and
member-only: deny-by-default 403 for non-members, checked first. Creating is
gated for free-plan users via ``check_limit(user, "announcements")`` (same
403 body shape as notes). Edit/delete/restore: announcement creator or group
creator only. Banner: presigned upload mirroring group photos; the key is
attached via create/update and re-validated against this group's prefix.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from backend.auth.dependencies import require_match
from backend.interactions.announcement_banner import generate_announcement_banner_upload_policy
from backend.interactions.announcements import (
    ANNOUNCEMENTS_ENABLED, AnnouncementForbidden, AnnouncementNotFound,
    AnnouncementsManager, parse_publish_at,
)
from backend.interactions.attachments import AttachmentConfigError
from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message
from backend.rate_limiting import limiter
from backend.subscription.limits import check_limit

group_announcements_router = APIRouter(prefix="/groups")
logger = logging.getLogger(__name__)


class AnnouncementCreateRequest(BaseModel):
    title: str
    description: str = ""
    banner_key: str | None = None
    publish_at: str | None = None  # ISO-8601 with offset; None = publish now


class AnnouncementUpdateRequest(BaseModel):
    """Only fields present in the body are applied (banner_key: null clears)."""
    title: str | None = None
    description: str | None = None
    banner_key: str | None = None
    publish_at: str | None = None


class BannerUploadUrlRequest(BaseModel):
    content_type: str
    size_bytes: int | None = None  # advisory; S3 policy enforces size


def _open(user_id: str, group_id: str) -> AnnouncementsManager:
    """Feature-flag + membership gate. Caller must close on success; closed
    here on failure."""
    if not ANNOUNCEMENTS_ENABLED:
        raise HTTPException(status_code=404, detail="Not found")
    manager = AnnouncementsManager(user_id, group_id)
    try:
        if not manager.is_member():
            raise HTTPException(status_code=403, detail="Not a member of this group")
    except Exception:
        manager.close()
        raise
    return manager


def _clean(**fields: str | None) -> None:
    try:
        check_clean(**fields)
    except ContentRejected as e:
        raise HTTPException(status_code=422, detail=rejection_message(e))


def _publish_at(value: str | None):
    try:
        return parse_publish_at(value)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))


@group_announcements_router.get("/{user_id}/{group_id}/announcements")
async def list_announcements(user_id: str, group_id: str, _: str = Depends(require_match("user_id"))) -> dict:
    """List visible announcements plus the caller's usage (for upgrade UI).

    Raises: 403 not a member."""
    manager = _open(user_id, group_id)
    try:
        result = manager.list_announcements()
    finally:
        manager.close()
    result["gate"] = check_limit(user_id, "announcements")
    return result


@group_announcements_router.post("/{user_id}/{group_id}/announcements", status_code=201)
@limiter.limit("30/minute")
async def create_announcement(
    request: Request, user_id: str, group_id: str, body: AnnouncementCreateRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Create an announcement.

    Raises: 403 not a member / foreign banner key / free limit reached (body
    is the limits dict, as for notes); 422 validation or content filter.
    """
    manager = _open(user_id, group_id)
    try:
        _clean(title=body.title, description=body.description)
        publish_at = _publish_at(body.publish_at)
        gate = check_limit(user_id, "announcements")
        if not gate["allowed"]:
            raise HTTPException(status_code=403, detail=gate)
        try:
            return manager.create_announcement(body.title, body.description, body.banner_key, publish_at)
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
        except AnnouncementForbidden:
            raise HTTPException(status_code=403, detail="Invalid banner reference")
    finally:
        manager.close()


@group_announcements_router.get("/{user_id}/{group_id}/announcements/{announcement_id}")
async def get_announcement(
    user_id: str, group_id: str, announcement_id: str, _: str = Depends(require_match("user_id")),
) -> dict:
    """Raises: 403 not a member; 404 missing/not visible."""
    manager = _open(user_id, group_id)
    try:
        return manager.get_announcement(announcement_id)
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    finally:
        manager.close()


@group_announcements_router.put("/{user_id}/{group_id}/announcements/{announcement_id}")
@limiter.limit("30/minute")
async def update_announcement(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    body: AnnouncementUpdateRequest, _: str = Depends(require_match("user_id")),
) -> dict:
    """Edit (creator or group creator). Not counted against the free limit.

    Raises: 403 not a member / not allowed / foreign banner key; 404;
    422 validation, content filter, or publish_at change after publishing.
    """
    fields = {k: getattr(body, k) for k in body.model_fields_set}
    manager = _open(user_id, group_id)
    try:
        _clean(title=fields.get("title"), description=fields.get("description"))
        if "publish_at" in fields:
            fields["publish_at"] = _publish_at(fields["publish_at"])
        try:
            return manager.update_announcement(announcement_id, fields)
        except AnnouncementNotFound:
            raise HTTPException(status_code=404, detail="Announcement not found")
        except AnnouncementForbidden:
            raise HTTPException(status_code=403, detail="Not allowed to edit this announcement")
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
    finally:
        manager.close()


@group_announcements_router.delete("/{user_id}/{group_id}/announcements/{announcement_id}")
@limiter.limit("30/minute")
async def delete_announcement(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Soft delete; undo via ``.../restore`` within the grace window.

    Raises: 403 not a member / not allowed; 404."""
    manager = _open(user_id, group_id)
    try:
        manager.delete_announcement(announcement_id)
        return {"deleted": True, "id": announcement_id}
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    except AnnouncementForbidden:
        raise HTTPException(status_code=403, detail="Not allowed to delete this announcement")
    finally:
        manager.close()


@group_announcements_router.post("/{user_id}/{group_id}/announcements/{announcement_id}/restore")
@limiter.limit("30/minute")
async def restore_announcement(
    request: Request, user_id: str, group_id: str, announcement_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Undo a delete within the grace window. Raises: 403; 404 if not deleted
    or the grace window has lapsed."""
    manager = _open(user_id, group_id)
    try:
        return manager.restore_announcement(announcement_id)
    except AnnouncementNotFound:
        raise HTTPException(status_code=404, detail="Announcement not found")
    except AnnouncementForbidden:
        raise HTTPException(status_code=403, detail="Not allowed to restore this announcement")
    finally:
        manager.close()


@group_announcements_router.post("/{user_id}/{group_id}/announcements/banner/upload-url")
@limiter.limit("30/minute")
async def request_banner_upload_url(
    request: Request, user_id: str, group_id: str, info: BannerUploadUrlRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Presigned S3 POST policy for a banner. Raises: 400 bad content_type;
    403 not a member; 503 uploads not configured."""
    manager = _open(user_id, group_id)
    manager.close()
    try:
        return generate_announcement_banner_upload_policy(user_id, group_id, info.content_type)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except AttachmentConfigError as e:
        logger.error("Announcement banner upload requested but not configured: %s", e)
        raise HTTPException(status_code=503, detail="Banner uploads are not available right now.")
