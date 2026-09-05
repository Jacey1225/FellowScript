"""Presigned-S3 attachment upload/download for human-to-human messaging.

The server never receives or stores raw attachment bytes for general
uploads (image/video/file): the client requests a presigned S3 POST policy
here, uploads directly to S3 with it, and only the resulting object key is
ever persisted in the message record. GIF attachments never reach this
module at all -- only the GIF provider's own id/url is stored (see
``backend/interactions/gif_search.py``), per the existing no-hosting design
decision.

Configuration split (Configuration Philosophy Q2/Q9):
    - Deployment-specific values (where the bucket lives) come from the
      environment, validated eagerly at startup by ``validate_attachment_config``
      (called from main.py's lifespan, mirroring ``push.py``'s
      ``validate_apns_config`` precedent -- a misconfigured deployment
      should refuse to start rather than fail every upload silently):
          S3_BUCKET_NAME
          S3_REGION
    - Application-behavior tunables (per-kind size/MIME limits, presigned
      URL TTLs) are foreseeable, proactively-configurable constants, not
      secrets or per-deploy values -- this project has no separate
      config-file module yet, so (matching the existing precedent of
      ``FriendsManager.CHECK_IN_POOL_SIZE`` / ``schemas/subscription.py``'s
      ``FREE_LIMITS``) they live as plain module-level constants below,
      not environment variables.

Threat-model decisions this module implements (security gate step 1,
task 20260904-messaging-attachments):
    - A presigned **POST** (policy document), not a bare presigned PUT --
      only a POST policy's conditions can cryptographically bind
      content-length-range and an exact content-type; a PUT's signature
      only covers the URL, so a client could swap the body's size/type
      after the URL was issued.
    - Object keys are entirely server-derived
      (``attachments/{user_id}/{uuid4()}{ext}``) -- the authenticated
      session's user_id, a fresh random UUID, and an extension mapped from
      the *validated* content-type. No client-supplied filename or
      extension ever reaches the key, closing path traversal and
      extension-spoofing entirely rather than sanitizing client input.
    - Fail closed: an attachment_kind/content_type pairing that isn't on
      the allowlist below is rejected outright (raises ``ValueError``,
      mapped to a 400 by the route) -- never falls back to a generic/"file"
      bucket for an unrecognized type.
    - Rendering uses a fresh, short-lived presigned GET issued at read time
      (``generate_download_url``) rather than a permanently public object
      URL or a stored presigned URL -- only the object key is ever
      persisted, so a leaked/stored key alone can't grant durable access.
"""

import logging
import os
import uuid

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

# ── Deployment-specific config (env vars) ───────────────────────────────────
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME", "")
S3_REGION = os.getenv("S3_REGION", "")

# ── Application-behavior tunables (see module docstring for why these are
# plain constants rather than env vars) ─────────────────────────────────────

# How long an issued presigned upload POST policy remains usable.
UPLOAD_URL_TTL_SECONDS = 300

# How long a freshly-issued presigned GET (used to render an attachment)
# remains usable. Short enough to bound the blast radius of a URL that leaks
# out of the client (e.g. via a copy/paste or a proxy log) without being so
# short that a slow network makes an image/video/file fail to load.
DOWNLOAD_URL_TTL_SECONDS = 3600

ATTACHMENT_KEY_PREFIX = "attachments"

# Per-kind allowlists + size caps. GIF is deliberately absent: GIF bytes
# never touch our storage or these limits at all -- only the provider's
# URL/ID is stored (backend/interactions/gif_search.py).
#
# `application/zip` is deliberately excluded from the "file" allowlist --
# generic archive containers are a common malware-delivery vector and add
# no rendering value (a file still just shows a name + download link either
# way). Documented here, not silently hardcoded, so it can be revisited.
PER_KIND_LIMITS: dict[str, dict] = {
    "image": {
        "max_size_mb": 15,
        "allowed_mime": {"image/jpeg", "image/png", "image/webp", "image/heic"},
    },
    "video": {
        "max_size_mb": 250,
        "allowed_mime": {"video/mp4", "video/quicktime"},
    },
    "file": {
        "max_size_mb": 50,
        "allowed_mime": {
            "application/pdf",
            "text/plain",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        },
    },
}

# Server-derived extension for each allowed MIME type -- never the client's
# supplied filename/extension (see module docstring: path-traversal /
# extension-spoofing defense).
_MIME_EXTENSIONS: dict[str, str] = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/heic": ".heic",
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "application/pdf": ".pdf",
    "text/plain": ".txt",
    "application/msword": ".doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
}

_s3_client = None


def _client():
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3", region_name=S3_REGION or None)
    return _s3_client


class AttachmentConfigError(RuntimeError):
    """Attachment uploads/downloads are unconfigured.

    Deliberately never swallowed -- mirrors ``push.py``'s
    ``APNsConfigError`` precedent: a missing S3_BUCKET_NAME/S3_REGION must
    surface loudly at startup (``validate_attachment_config`` is called
    from main.py's lifespan) rather than degrade every upload/render
    silently. Callers on a live request path (the upload-url and message
    read/send routes) catch this specifically and turn it into a clear
    503, never a generic 500.
    """


def _missing_config_vars() -> list[str]:
    return [
        name for name, value in (
            ("S3_BUCKET_NAME", S3_BUCKET_NAME),
            ("S3_REGION", S3_REGION),
        )
        if not value
    ]


def validate_attachment_config() -> None:
    """Eagerly validate the S3 attachment env vars are set.

    Raises ``AttachmentConfigError`` naming exactly which variable(s) are
    missing -- there is no implicit default for where attachments are
    stored. Does not itself verify bucket/IAM access (that would require a
    live call on every boot); it only guarantees the config needed to
    construct requests is present.
    """
    missing = _missing_config_vars()
    if missing:
        raise AttachmentConfigError(
            "Attachment uploads are not configured: missing required "
            f"environment variable(s) {', '.join(missing)}. Set them "
            "explicitly -- there is no implicit default for where "
            "attachments are stored."
        )


def generate_upload_policy(user_id: str, attachment_kind: str, content_type: str) -> dict:
    """Issue a presigned S3 POST policy for one attachment upload.

    Fails closed: an ``attachment_kind``/``content_type`` combination that
    isn't confidently on the allowlist raises ``ValueError`` (mapped to a
    400 by the route) rather than falling back to a generic bucket.

    Args:
        user_id: The *authenticated* caller's own user_id (never
            client-supplied path data) -- becomes part of the object key.
        attachment_kind: One of ``PER_KIND_LIMITS``' keys ("image", "video",
            "file"). "gif" is never valid here -- GIFs never upload to our S3.
        content_type: The MIME type the client intends to upload; validated
            against the per-kind allowlist and cryptographically pinned into
            the returned policy's conditions (a client can't swap the
            Content-Type between requesting this URL and using it).

    Returns:
        dict: ``{"url", "fields", "object_key", "expires_in"}`` -- ``url``
            and ``fields`` are passed straight through to the client's
            multipart POST to S3; ``object_key`` is what the client must
            reference in the ``attachment_key`` of the message it sends
            once the upload succeeds.

    Raises:
        ValueError: If ``attachment_kind``/``content_type`` isn't a
            recognized, allowed combination.
        AttachmentConfigError: If S3 isn't configured (see
            ``validate_attachment_config``).
    """
    validate_attachment_config()
    limits = PER_KIND_LIMITS.get(attachment_kind)
    if limits is None or content_type not in limits["allowed_mime"]:
        raise ValueError(
            f"Unsupported attachment_kind/content_type combination: "
            f"{attachment_kind!r}/{content_type!r}"
        )
    ext = _MIME_EXTENSIONS.get(content_type, "")
    object_key = f"{ATTACHMENT_KEY_PREFIX}/{user_id}/{uuid.uuid4()}{ext}"
    max_bytes = limits["max_size_mb"] * 1024 * 1024

    response = _client().generate_presigned_post(
        Bucket=S3_BUCKET_NAME,
        Key=object_key,
        Fields={"Content-Type": content_type},
        Conditions=[
            {"Content-Type": content_type},
            ["content-length-range", 1, max_bytes],
        ],
        ExpiresIn=UPLOAD_URL_TTL_SECONDS,
    )
    return {
        "url": response["url"],
        "fields": response["fields"],
        "object_key": object_key,
        "expires_in": UPLOAD_URL_TTL_SECONDS,
    }


def generate_download_url(object_key: str | None) -> str | None:
    """Issue a fresh, short-lived presigned GET for rendering one attachment.

    Returns ``None`` (rather than raising) for a blank key, or if S3 isn't
    configured, or if presigning itself fails -- a rendering hiccup should
    degrade to "attachment temporarily unavailable" on the client, not break
    the surrounding message thread/history load.
    """
    if not object_key:
        return None
    try:
        validate_attachment_config()
        return _client().generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET_NAME, "Key": object_key},
            ExpiresIn=DOWNLOAD_URL_TTL_SECONDS,
        )
    except (AttachmentConfigError, ClientError) as e:
        logger.error("Could not presign GET for attachment %s: %s", object_key, e)
        return None
