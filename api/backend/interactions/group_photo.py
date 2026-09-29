"""Presigned-S3 group-photo upload (task 20260929-group-info-panel).

Sibling to ``backend/interactions/profile_photo.py`` -- same "image"-only
wrapper over ``attachments.generate_upload_policy`` (same MIME/size
allowlist, presigned POST so the server never receives bytes), but scoped to
a *group* rather than a user.

Object keys live at ``group-photos/{group_id}/{uploader_id}/{uuid4()}{ext}``
-- a namespace distinct from ``attachments/`` and ``profile-photos/``.
Because the group id is part of the key prefix, ``is_group_photo_key``
can prove a key belongs to *this* group (not another group's, not a user's
profile photo, not a message attachment) before it is ever persisted.
"""

import uuid

from backend.interactions.attachments import generate_upload_policy

GROUP_PHOTO_KEY_PREFIX = "group-photos"


def _valid_group_id(group_id: str) -> bool:
    try:
        uuid.UUID(str(group_id))
    except (ValueError, AttributeError, TypeError):
        return False
    return True


def generate_group_photo_upload_policy(user_id: str, group_id: str, content_type: str) -> dict:
    """Issue a presigned S3 POST policy for a group-photo upload.

    Callers must have already verified ``user_id`` is a member of
    ``group_id``. Raises ``ValueError`` for a malformed group id or an
    unsupported ``content_type`` (fail closed), ``AttachmentConfigError`` if
    S3 isn't configured.
    """
    if not _valid_group_id(group_id):
        raise ValueError("Invalid group id")
    return generate_upload_policy(
        user_id, "image", content_type,
        key_prefix=f"{GROUP_PHOTO_KEY_PREFIX}/{group_id}",
    )


def is_group_photo_key(group_id: str, object_key: str | None) -> bool:
    """True iff ``object_key`` unambiguously falls under this group's own
    photo prefix. Fails closed for a blank key, another group's/user's key,
    a malformed group id, or any ``..`` traversal-looking segment."""
    if not object_key or ".." in object_key or not _valid_group_id(group_id):
        return False
    return object_key.startswith(f"{GROUP_PHOTO_KEY_PREFIX}/{group_id}/")
