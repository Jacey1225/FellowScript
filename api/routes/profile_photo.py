"""Profile-photo upload/confirm/remove endpoints (task 20260905-profile-photo).

Mirrors ``routes/messaging.py``'s ``POST /message/upload-url/{user_id}``
wire contract exactly: the client requests a presigned S3 POST policy over
plain HTTP, uploads the raw bytes directly to S3 with it, then calls back
here to confirm -- this server never receives the photo bytes themselves.

Every route here is authenticated + self-scoped via ``require_match``
(Security Posture Q2/Q5): a user may only ever set, replace, or remove
their *own* profile photo -- a purpose-built check, not a general
permission framework, per this task's Preference Profile.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from backend.auth.dependencies import require_match
from backend.interactions.attachments import AttachmentConfigError, delete_object, generate_download_url
from backend.interactions.profile_photo import generate_profile_photo_upload_policy, is_own_profile_photo_key
from backend.errors import SaveFailedError
from backend.rate_limiting import limiter
from db import DBManager

profile_photo_router = APIRouter(prefix="/user")
logger = logging.getLogger(__name__)


class ProfilePhotoUploadUrlRequest(BaseModel):
    """POST /user/{user_id}/photo/upload-url request body.

    No ``attachment_kind`` field (unlike messaging's ``UploadUrlRequest``)
    -- a profile photo is always the "image" kind. ``size_bytes`` is
    advisory only, matching that endpoint's precedent: real enforcement is
    the presigned POST policy's content-length-range condition, S3-enforced.
    """
    content_type: str
    size_bytes: int | None = None


class ProfilePhotoConfirmRequest(BaseModel):
    """POST /user/{user_id}/photo/confirm request body."""
    object_key: str


def _current_photo_key(db: DBManager, user_id: str) -> tuple[bool, str | None]:
    """Look up whether ``user_id`` exists and, if so, their current
    ``profile_photo_key`` (``None`` if they have none set)."""
    existing = db.lookup("users", {"_id": user_id})
    if not existing:
        return False, None
    _, data = list(existing.items())[0]
    return True, data.get("profile_photo_key")


@profile_photo_router.post("/{user_id}/photo/upload-url")
@limiter.limit("30/minute")
async def request_profile_photo_upload_url(
    request: Request,
    user_id: str,
    info: ProfilePhotoUploadUrlRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Issue a presigned S3 POST policy for the caller's own profile-photo upload.

    Authenticated + self-scoped (``require_match``) -- deny-by-default,
    mirroring ``routes/messaging.py::request_upload_url``. Fails closed: an
    unsupported ``content_type`` is rejected (400) rather than falling back
    to a generic allowlist.

    Raises:
        HTTPException 400: If ``content_type`` isn't a recognized, allowed
            image MIME type.
        HTTPException 503: If uploads aren't configured yet (missing
            S3_BUCKET_NAME/S3_REGION).
    """
    try:
        return generate_profile_photo_upload_policy(user_id, info.content_type)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except AttachmentConfigError as e:
        logger.error("Profile-photo upload requested but not configured: %s", e)
        raise HTTPException(status_code=503, detail="Profile photo uploads are not available right now.")


@profile_photo_router.post("/{user_id}/photo/confirm")
@limiter.limit("30/minute")
async def confirm_profile_photo(
    request: Request,
    user_id: str,
    info: ProfilePhotoConfirmRequest,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Persist a just-completed profile-photo upload's object key on the caller's own row.

    Re-validates (fail-closed) that ``object_key`` unambiguously falls
    under the caller's own upload prefix before ever persisting it --
    defense in depth against a stale or someone-else's key being replayed
    here, rather than trusting the earlier upload-url step alone (Security
    Posture Q7/Q14). The previous photo object, if any, is deleted
    best-effort so a replace never orphans the old object (this task's
    replace/remove-cleanup requirement).

    Raises:
        HTTPException 403: If ``object_key`` doesn't fall under this
            caller's own ``profile-photos/{user_id}/`` prefix.
        HTTPException 404: If the user no longer exists.
    """
    if not is_own_profile_photo_key(user_id, info.object_key):
        raise HTTPException(status_code=403, detail="Invalid photo reference")
    db = DBManager()
    try:
        exists, old_key = _current_photo_key(db, user_id)
        if not exists:
            raise HTTPException(status_code=404, detail="User not found")
        if not db.update("users", {"profile_photo_key": info.object_key}, {"_id": user_id}):
            raise SaveFailedError()
    finally:
        db.close()
    # Best-effort cleanup of the object this one is replacing -- never
    # blocks the response on a cleanup failure (see attachments.delete_object).
    if old_key and old_key != info.object_key:
        delete_object(old_key)
    return {"profile_photo_url": generate_download_url(info.object_key)}


@profile_photo_router.delete("/{user_id}/photo", status_code=204)
@limiter.limit("30/minute")
async def remove_profile_photo(
    request: Request,
    user_id: str,
    _: str = Depends(require_match("user_id")),
) -> None:
    """Remove the caller's own profile photo, clearing the column and
    deleting the underlying S3 object.

    Idempotent: calling this with no photo currently set is a no-op, not an
    error.

    Raises:
        HTTPException 404: If the user no longer exists.
    """
    db = DBManager()
    try:
        exists, old_key = _current_photo_key(db, user_id)
        if not exists:
            raise HTTPException(status_code=404, detail="User not found")
        if old_key and not db.update("users", {"profile_photo_key": None}, {"_id": user_id}):
            raise SaveFailedError()
    finally:
        db.close()
    if old_key:
        delete_object(old_key)
