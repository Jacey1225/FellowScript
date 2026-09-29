"""Presigned-S3 announcement-banner upload (task 20260929-group-announcements).

Sibling to ``group_photo.py``: same image-only wrapper over
``attachments.generate_upload_policy`` (same MIME/size allowlist, presigned
POST so the server never receives bytes), scoped to a group's announcements.

Keys live at ``group-announcements/{group_id}/{uploader_id}/{uuid4()}{ext}``,
a namespace distinct from ``attachments/``, ``profile-photos/`` and
``group-photos/``. ``is_announcement_banner_key`` proves a key belongs to
*this* group before it is ever persisted.
"""

import uuid

from backend.interactions.attachments import generate_upload_policy

ANNOUNCEMENT_BANNER_KEY_PREFIX = "group-announcements"


def _valid_group_id(group_id: str) -> bool:
    try:
        uuid.UUID(str(group_id))
    except (ValueError, AttributeError, TypeError):
        return False
    return True


def generate_announcement_banner_upload_policy(user_id: str, group_id: str, content_type: str) -> dict:
    """Issue a presigned S3 POST policy for a banner upload. Caller must have
    verified group membership. Raises ``ValueError`` (bad group id / MIME) or
    ``AttachmentConfigError`` (S3 not configured)."""
    if not _valid_group_id(group_id):
        raise ValueError("Invalid group id")
    return generate_upload_policy(
        user_id, "image", content_type,
        key_prefix=f"{ANNOUNCEMENT_BANNER_KEY_PREFIX}/{group_id}",
    )


def is_announcement_banner_key(group_id: str, object_key: str | None) -> bool:
    """True iff ``object_key`` falls under this group's announcement-banner
    prefix. Fails closed on blank, foreign, malformed or ``..`` keys."""
    if not object_key or ".." in object_key or not _valid_group_id(group_id):
        return False
    return object_key.startswith(f"{ANNOUNCEMENT_BANNER_KEY_PREFIX}/{group_id}/")
