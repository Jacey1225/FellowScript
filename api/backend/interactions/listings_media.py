"""Explorer listing media: keys, upload policy, image re-encode, delivery URLs,
description media blocks and lifecycle key collectors (task
20261002-explorer-listing-media, backend step 1).

Layering. This module holds everything that does not need the owner manager:
key building and ownership proofs, the presigned POST, the pure
``process_image`` re-encode pipeline, S3 read/write wrappers, presigned GET
delivery, the ``image`` / ``video`` description block validators and the
cursor-in database helpers. The owner-facing operations (upload-url, confirm,
use-current-group-photo, delete) live in ``listings_media_service`` because they
subclass ``ListingsManager`` and ``listings`` imports ``listing_content``, which
imports this module at its end to register the block validators; a module-level
import of ``listings`` here would be circular.

Threat model, in code:

* Keys are entirely server-built: ``listings/{public_id}/{uuid}{ext}`` with the
  extension derived from the validated MIME type, never from a client filename.
* A client-supplied key is only ever accepted when it fullmatches that shape
  for THIS listing's public id (no ``..``, no other listing, no other prefix).
  Anything else is the same uniform 404 as an unknown key.
* The uploaded original is never referenced or served. ``confirm`` reads it
  with a bounded read, checks magic bytes against the declared type, checks
  the header size BEFORE decoding, decodes with Pillow under explicit pixel
  limits, then re-encodes pixels only (EXIF, GPS, ICC profile, text chunks and
  any trailing polyglot payload are dropped) to a NEW key. Every key that must
  go (the original on every path, replaced or removed derivatives) is queued in
  the S3 outbox; this module never calls ``delete_object``.
* Only JPEG, PNG and WebP are accepted. HEIC, GIF, SVG, AVIF and animated
  images are rejected (there is no pillow-heif).
* Logging: ids and counts only; never a key, filename or image content.
"""
from __future__ import annotations

import io
import logging
import re
import threading
import time
import uuid
import warnings
from dataclasses import dataclass
from typing import Any, Mapping

from botocore.exceptions import BotoCoreError, ClientError
from PIL import Image, ImageOps

from backend.interactions import attachments
from backend.interactions.listing_content import (
    BLOCK_VALIDATORS,
    ListingError,
    _collapse,
    _check_plain,
    reject_unsafe_text,
)
from backend.interactions.listings_media_config import (
    SUPPORTED_MIME,
    MediaConfig,
    get_media_config,
)

logger = logging.getLogger(__name__)

KEY_PREFIX = "listings"
KINDS = ("photo", "banner", "image")
_PUBLIC_ID_RE = re.compile(r"^[0-9A-Za-z]{10}$")
_UUID_PART = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
_EXT_TO_MIME = {ext: mime for mime, (ext, _fmt) in SUPPORTED_MIME.items()}
_DERIVED_NAMESPACE = uuid.UUID("5f0b8c1e-6a52-4d0e-9a3e-3a9b6f2f0c11")
_VIDEO_ID_RES = {
    "youtube": re.compile(r"^[A-Za-z0-9_-]{11}$"),
    "vimeo": re.compile(r"^[0-9]{6,12}$"),
}
_VIDEO_TITLE_MAX = 120
_UUID_RE = re.compile(rf"^{_UUID_PART}$")


def _not_found() -> ListingError:
    return ListingError(404, "not_found", "Not found")


def _reject(code: str, message: str, status: int = 422) -> ListingError:
    return ListingError(status, code, message)


# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

def _valid_public_id(public_id) -> bool:
    return isinstance(public_id, str) and bool(_PUBLIC_ID_RE.fullmatch(public_id))


def build_key(public_id: str, mime: str, *, name: uuid.UUID | None = None) -> str:
    """``listings/{public_id}/{uuid}{ext}``. The extension comes from the
    validated MIME type, never from anything the client sent. ``name`` pins the
    uuid (used for deterministic derivative keys); default is a random uuid4."""
    if not _valid_public_id(public_id):
        raise ValueError("invalid public id")
    if mime not in SUPPORTED_MIME:
        raise ValueError("unsupported media type")
    return f"{KEY_PREFIX}/{public_id}/{name or uuid.uuid4()}{SUPPORTED_MIME[mime][0]}"


def parse_key(public_id: str, key) -> tuple[str, str] | None:
    """``(mime, ext)`` iff ``key`` is exactly a listing key of THIS listing, else
    None (fail closed: foreign listing, other prefix, ``..``, odd or upper case
    extension, trailing characters, wrong type)."""
    if not _valid_public_id(public_id) or not isinstance(key, str) or len(key) > 200:
        return None
    if ".." in key or "\\" in key or "%" in key:
        return None
    m = re.fullmatch(rf"{KEY_PREFIX}/{re.escape(public_id)}/({_UUID_PART})(\.jpg|\.png|\.webp)", key)
    if m is None:
        return None
    return _EXT_TO_MIME[m.group(2)], m.group(2)


def derived_key(public_id: str, original_key: str, mime: str) -> str:
    """Deterministic key for the re-encoded derivative of an uploaded original,
    so a repeated confirm of the same original finds its row instead of
    storing a second copy."""
    return build_key(public_id, mime, name=uuid.uuid5(_DERIVED_NAMESPACE, original_key))


def mime_for_key(key: str) -> str | None:
    for ext, mime in _EXT_TO_MIME.items():
        if isinstance(key, str) and key.endswith(ext):
            return mime
    return None


# ---------------------------------------------------------------------------
# Presigned POST / GET
# ---------------------------------------------------------------------------

def _bucket() -> str:
    return attachments.S3_BUCKET_NAME


def presign_upload(public_id: str, mime: str, cfg: MediaConfig | None = None) -> dict:
    """Presigned POST for one image upload. Pins the exact Content-Type and the
    content-length-range from config. Raises ``ListingError`` 422 for a type that
    is not on the allowlist and ``attachments.AttachmentConfigError`` when S3 is
    not configured (the route turns that into a 503)."""
    cfg = cfg or get_media_config()
    if mime not in cfg.allowed_mime:
        raise _reject("unsupported_media_type", "Use a JPEG, PNG or WebP image.")
    attachments.validate_attachment_config()
    key = build_key(public_id, mime)
    response = attachments._client().generate_presigned_post(
        Bucket=_bucket(),
        Key=key,
        Fields={"Content-Type": mime},
        Conditions=[
            {"Content-Type": mime},
            ["content-length-range", cfg.image_min_upload_bytes, cfg.max_upload_bytes],
        ],
        ExpiresIn=cfg.upload_url_ttl_seconds,
    )
    return {
        "url": response["url"],
        "fields": response["fields"],
        "object_key": key,
        "expires_in": cfg.upload_url_ttl_seconds,
        "max_bytes": cfg.max_upload_bytes,
    }


_URL_CACHE_MAX = 4096
_url_lock = threading.Lock()
_url_cache: dict[str, tuple[str, float]] = {}


def media_url(key: str | None, cfg: MediaConfig | None = None) -> str | None:
    """Presigned GET for one stored derivative, or None.

    The cache is in-process and bounded: the same key returns the same URL for
    ``download_url_cache_seconds`` (shorter than the URL's own TTL, so a cached
    URL always has time left), which lets browsers cache the image and keeps
    repeated public browsing from re-signing. ``ResponseContentType`` comes
    from the key's validated extension. A restart empties the cache."""
    if not key or not isinstance(key, str) or not key.startswith(KEY_PREFIX + "/") or ".." in key:
        return None
    mime = mime_for_key(key)
    if mime is None:
        return None
    cfg = cfg or get_media_config()
    now = time.monotonic()
    with _url_lock:
        hit = _url_cache.get(key)
        if hit is not None and hit[1] > now:
            return hit[0]
    try:
        attachments.validate_attachment_config()
        url = attachments._client().generate_presigned_url(
            "get_object",
            Params={"Bucket": _bucket(), "Key": key, "ResponseContentType": mime},
            ExpiresIn=cfg.download_url_ttl_seconds,
        )
    except (attachments.AttachmentConfigError, ClientError, BotoCoreError):
        return None
    with _url_lock:
        if len(_url_cache) >= _URL_CACHE_MAX:
            for stale in [k for k, (_u, exp) in _url_cache.items() if exp <= now] or list(_url_cache)[:256]:
                _url_cache.pop(stale, None)
        _url_cache[key] = (url, now + cfg.download_url_cache_seconds)
    return url


def reset_url_cache_for_tests() -> None:
    with _url_lock:
        _url_cache.clear()


# ---------------------------------------------------------------------------
# Image pipeline (pure: bytes in, bytes out)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Processed:
    data: bytes
    mime: str
    ext: str
    width: int
    height: int


def sniff_mime(head: bytes) -> str | None:
    """Type from magic bytes (JPEG ``FFD8FF``, PNG signature, ``RIFF....WEBP``)."""
    if head[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    return None


def process_image(raw: bytes, expected_mime: str, cfg: MediaConfig | None = None) -> Processed:
    """Validate and re-encode one uploaded image. Raises ``ListingError`` 422
    (``invalid_image`` / ``image_too_large`` / ``unsupported_media_type``).

    Order matters: byte cap, magic bytes agree with the declared type, header
    size checked before any pixel decode, single frame only, full decode with
    decompression-bomb warnings promoted to errors, EXIF orientation applied,
    downscale, then pixels re-encoded into a fresh image with no metadata."""
    cfg = cfg or get_media_config()
    if expected_mime not in cfg.allowed_mime or expected_mime not in SUPPORTED_MIME:
        raise _reject("unsupported_media_type", "Use a JPEG, PNG or WebP image.")
    if not raw or len(raw) > cfg.max_upload_bytes:
        raise _reject("image_too_large", "That image file is too large.")
    if sniff_mime(raw[:16]) != expected_mime:
        raise _reject("invalid_image", "That file isn't a valid image of the type it claims to be.")
    ext, fmt = SUPPORTED_MIME[expected_mime]

    Image.MAX_IMAGE_PIXELS = cfg.max_pixels
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            im = Image.open(io.BytesIO(raw), formats=[fmt])
            width, height = im.size
            if width < 1 or height < 1 or width * height > cfg.max_pixels or max(width, height) > cfg.max_side_px:
                raise _reject("image_too_large", "That image has too many pixels. Use a smaller image.")
            if getattr(im, "is_animated", False) or getattr(im, "n_frames", 1) > 1:
                raise _reject("invalid_image", "Animated images aren't supported.")
            if fmt == "JPEG" and im.mode in ("RGB", "L"):
                im.draft(im.mode, (cfg.output_max_side_px, cfg.output_max_side_px))
            im.load()
            im.thumbnail((cfg.output_max_side_px, cfg.output_max_side_px), Image.Resampling.LANCZOS)
            im = ImageOps.exif_transpose(im)
            im = _normalise_mode(im, fmt)
            clean = im.copy()
            clean.info = {}
            out = io.BytesIO()
            clean.save(out, format=fmt, **_save_options(fmt, cfg))
    except ListingError:
        raise
    except (Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise _reject("image_too_large", "That image has too many pixels. Use a smaller image.") from None
    except Exception:  # noqa: BLE001 - any decode failure is a rejected upload, never a 500
        raise _reject("invalid_image", "We couldn't read that image. Try a different JPEG, PNG or WebP file.") from None
    data = out.getvalue()
    return Processed(data=data, mime=expected_mime, ext=ext, width=clean.size[0], height=clean.size[1])


def _normalise_mode(im: Image.Image, fmt: str) -> Image.Image:
    has_alpha = im.mode in ("RGBA", "LA", "PA") or "transparency" in im.info
    if fmt == "JPEG":
        return im if im.mode in ("RGB", "L") else im.convert("RGB")
    if fmt == "PNG":
        if im.mode in ("RGB", "RGBA", "L", "LA"):
            return im
        return im.convert("RGBA" if has_alpha else "RGB")
    # WEBP stores RGB or RGBA only.
    if im.mode in ("RGB", "RGBA"):
        return im
    return im.convert("RGBA" if has_alpha else "RGB")


def _save_options(fmt: str, cfg: MediaConfig) -> dict:
    if fmt == "JPEG":
        return {"quality": cfg.jpeg_quality, "optimize": True}
    if fmt == "WEBP":
        return {"quality": cfg.webp_quality, "method": 4}
    return {"optimize": True}


# ---------------------------------------------------------------------------
# S3 access for the confirm path (blocking: only ever called from a threadpool route)
# ---------------------------------------------------------------------------

_S3_MISSING = frozenset({"404", "NoSuchKey", "NotFound"})


def _code(e: ClientError) -> str:
    return str((e.response or {}).get("Error", {}).get("Code", ""))


def fetch_for_processing(source_key: str, expected_mime: str, cfg: MediaConfig | None = None) -> bytes:
    """Bounded read of one object: ``head_object`` size and content-type check,
    then at most ``max + 1`` bytes. 404 when the object is not there (same
    answer as an unknown key); 503 for any other S3 failure."""
    cfg = cfg or get_media_config()
    try:
        attachments.validate_attachment_config()
        client = attachments._client()
        head = client.head_object(Bucket=_bucket(), Key=source_key)
        length = int(head.get("ContentLength", 0))
        if length < 1 or length > cfg.max_upload_bytes:
            raise _reject("image_too_large", "That image file is too large.")
        if str(head.get("ContentType", "")).split(";")[0].strip().lower() != expected_mime:
            raise _reject("invalid_image", "That file isn't the type it claims to be.")
        body = client.get_object(Bucket=_bucket(), Key=source_key)["Body"]
        raw = body.read(cfg.max_upload_bytes + 1)
        if len(raw) > cfg.max_upload_bytes:
            raise _reject("image_too_large", "That image file is too large.")
        return raw
    except ListingError:
        raise
    except ClientError as e:
        if _code(e) in _S3_MISSING:
            raise _not_found() from None
        raise ListingError(503, "media_unavailable", "Image storage is unavailable. Try again shortly.") from None
    except (attachments.AttachmentConfigError, BotoCoreError):
        raise ListingError(503, "media_unavailable", "Image storage is unavailable. Try again shortly.") from None


def store_derivative(key: str, processed: Processed) -> None:
    try:
        attachments.validate_attachment_config()
        attachments._client().put_object(
            Bucket=_bucket(),
            Key=key,
            Body=processed.data,
            ContentType=processed.mime,
            CacheControl="private, max-age=3600",
        )
    except (attachments.AttachmentConfigError, ClientError, BotoCoreError):
        raise ListingError(503, "media_unavailable", "Image storage is unavailable. Try again shortly.") from None


_slot_lock = threading.Lock()
_slots: threading.BoundedSemaphore | None = None
_slots_size = 0


class confirm_slot:
    """Context manager: at most ``confirm_concurrency`` image decodes run at once
    in this process (a decoded 36 MP RGB image is about 108 MB against a 1500 MB
    container). Waiting longer than ``confirm_wait_seconds`` is a 429 ``busy``."""

    def __init__(self, cfg: MediaConfig | None = None):
        self.cfg = cfg or get_media_config()
        self._held = False

    def __enter__(self):
        global _slots, _slots_size
        with _slot_lock:
            if _slots is None or _slots_size != self.cfg.confirm_concurrency:
                _slots = threading.BoundedSemaphore(self.cfg.confirm_concurrency)
                _slots_size = self.cfg.confirm_concurrency
            slots = _slots
        if not slots.acquire(timeout=self.cfg.confirm_wait_seconds):
            raise ListingError(429, "busy", "Image processing is busy. Try again in a moment.")
        self._slots = slots
        self._held = True
        return self

    def __exit__(self, *exc):
        if self._held:
            self._slots.release()
            self._held = False
        return False


# ---------------------------------------------------------------------------
# Alt text and description blocks
# ---------------------------------------------------------------------------

def clean_alt(value: Any, field: str, *, required: bool, list_cfg=None, mcfg: MediaConfig | None = None) -> str | None:
    """Plain alt text: required where the image carries meaning, bounded, no
    markup or links, same text policy as every other public text field."""
    mcfg = mcfg or get_media_config()
    if value is None or (isinstance(value, str) and not value.strip()):
        if required:
            raise ListingError(422, "alt_required", "Describe the image for people who can't see it.", field)
        return None
    if not isinstance(value, str):
        raise ListingError(422, "invalid_field", "Alt text must be text.", field)
    cleaned = _collapse(value)
    if len(cleaned) > mcfg.alt_max_length:
        raise ListingError(422, "too_long", f"Alt text must be {mcfg.alt_max_length} characters or fewer.", field)
    _check_plain(field, cleaned)
    if list_cfg is None:
        from backend.interactions.listings_config import get_listings_config

        list_cfg = get_listings_config()
    reject_unsafe_text(list_cfg, {"description_text": cleaned})
    return cleaned


def _validate_image_block(cfg, block: Mapping, field: str) -> dict:
    if set(block) != {"type", "media_id", "alt"}:
        raise ListingError(422, "invalid_block", "An image block holds only its image and description.", field)
    media_id = block["media_id"]
    if not isinstance(media_id, str) or not _UUID_RE.fullmatch(media_id):
        raise ListingError(422, "invalid_block", "That image isn't valid.", field)
    alt = clean_alt(block["alt"], field, required=True, list_cfg=cfg)
    return {"type": "image", "media_id": media_id, "alt": alt}


def _validate_video_block(cfg, block: Mapping, field: str) -> dict:
    mcfg = get_media_config()
    if not mcfg.video_enabled:
        raise ListingError(422, "video_not_enabled", "Videos aren't available yet.", field)
    if set(block) != {"type", "provider", "video_id", "title"}:
        raise ListingError(422, "invalid_block", "A video block holds only its provider, id and title.", field)
    provider, video_id = block["provider"], block["video_id"]
    if not isinstance(provider, str) or provider not in mcfg.video_providers:
        raise ListingError(422, "invalid_block", "That video provider isn't supported.", field)
    if not isinstance(video_id, str) or not _VIDEO_ID_RES[provider].fullmatch(video_id):
        raise ListingError(422, "invalid_block", "That video isn't valid.", field)
    title = block["title"]
    if not isinstance(title, str) or not title.strip():
        raise ListingError(422, "alt_required", "Give the video a title.", field)
    title = _collapse(title)
    if len(title) > _VIDEO_TITLE_MAX:
        raise ListingError(422, "too_long", f"A video title must be {_VIDEO_TITLE_MAX} characters or fewer.", field)
    _check_plain(field, title)
    reject_unsafe_text(cfg, {"description_text": title})
    return {"type": "video", "provider": provider, "video_id": video_id, "title": title}


BLOCK_VALIDATORS["image"] = _validate_image_block
BLOCK_VALIDATORS["video"] = _validate_video_block


def verify_description_media(cur, group_id: str, blocks, mcfg: MediaConfig | None = None) -> None:
    """Every ``image`` block must point at a ready ``image`` row of THIS group's
    listing (called from the save path, inside the group-locked transaction).
    422 ``media_not_found`` otherwise; 422 ``too_many_images`` over the cap."""
    mcfg = mcfg or get_media_config()
    ids = [b["media_id"] for b in blocks or [] if isinstance(b, Mapping) and b.get("type") == "image"]
    if not ids:
        return
    if len(ids) > mcfg.max_description_images:
        raise ListingError(
            422, "too_many_images",
            f"A description can have at most {mcfg.max_description_images} images.", "description_blocks",
        )
    cur.execute(
        "SELECT m._id::text FROM group_listing_media m JOIN group_listings gl ON gl._id = m.listing_id "
        "WHERE gl.group_id = %s AND m.kind = 'image' AND m.status = 'ready' AND m._id = ANY(%s::uuid[])",
        (group_id, list(dict.fromkeys(ids))),
    )
    found = {r[0] for r in cur.fetchall()}
    if any(i not in found for i in ids):
        raise ListingError(422, "media_not_found", "One of the images in the description isn't available.", "description_blocks")


# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------

def _item(row, cfg: MediaConfig) -> dict:
    media_id, kind, key, width, height, alt = row
    return {
        "media_id": media_id, "kind": kind, "url": media_url(key, cfg),
        "width": width, "height": height, "alt_text": alt,
    }


def decorate_owner_view(cur, view: dict) -> dict:
    """Add ``photo_url``, ``banner_url``, ``banner_alt`` and ``media`` (the ready
    rows) to an owner listing view. Presigned GETs are local signing: no S3 call."""
    cfg = get_media_config()
    cur.execute(
        "SELECT _id::text, photo_key, banner_key, banner_alt FROM group_listings WHERE public_id = %s",
        (view.get("public_id"),),
    )
    row = cur.fetchone()
    view.update({"photo_url": None, "banner_url": None, "banner_alt": None, "media": []})
    if row is None:
        return view
    listing_id, photo_key, banner_key, banner_alt = row
    view["photo_url"] = media_url(photo_key, cfg)
    view["banner_url"] = media_url(banner_key, cfg)
    view["banner_alt"] = banner_alt
    cur.execute(
        "SELECT _id::text, kind, object_key, width, height, alt_text FROM group_listing_media "
        "WHERE listing_id = %s AND status = 'ready' ORDER BY created_at, _id",
        (listing_id,),
    )
    view["media"] = [_item(r, cfg) for r in cur.fetchall()]
    return view


def public_images(cur, listing_id: str) -> dict[str, dict]:
    """media_id -> {url, width, height} for a published listing's ready image rows."""
    cfg = get_media_config()
    cur.execute(
        "SELECT _id::text, object_key, width, height FROM group_listing_media "
        "WHERE listing_id = %s AND kind = 'image' AND status = 'ready'",
        (listing_id,),
    )
    out = {}
    for media_id, key, width, height in cur.fetchall():
        url = media_url(key, cfg)
        if url:
            out[media_id] = {"url": url, "width": width, "height": height}
    return out


def public_blocks(blocks, images: Mapping[str, dict]) -> list[dict]:
    """Description blocks for signed-out readers, rebuilt field by field. An
    image whose row is gone or has no URL is dropped; a video block is emitted
    only while ``video_enabled``; unknown types are dropped."""
    mcfg = get_media_config()
    out: list[dict] = []
    for block in blocks or []:
        if not isinstance(block, Mapping):
            continue
        kind = block.get("type")
        if kind == "text" and isinstance(block.get("text"), str):
            out.append({"type": "text", "text": block["text"]})
        elif kind == "image" and isinstance(block.get("alt"), str):
            img = images.get(block.get("media_id"))
            if img:
                out.append({"type": "image", "url": img["url"], "alt": block["alt"],
                            "width": img["width"], "height": img["height"]})
        elif (
            kind == "video" and mcfg.video_enabled
            and block.get("provider") in mcfg.video_providers
            and isinstance(block.get("video_id"), str)
            and _VIDEO_ID_RES[block["provider"]].fullmatch(block["video_id"])
            and isinstance(block.get("title"), str)
        ):
            out.append({"type": "video", "provider": block["provider"], "video_id": block["video_id"],
                        "title": block["title"]})
    return out


def options_payload(cfg: MediaConfig | None = None) -> dict:
    """What the owner upload UI needs (no secrets)."""
    cfg = cfg or get_media_config()
    return {
        "video_enabled": cfg.video_enabled,
        "allowed_mime": list(cfg.allowed_mime),
        "image_max_upload_bytes": cfg.max_upload_bytes,
        "max_images_per_listing": cfg.max_images_per_listing,
        "max_description_images": cfg.max_description_images,
        "max_bytes_per_listing": cfg.max_bytes_per_listing,
        "alt_max_length": cfg.alt_max_length,
        "max_side_px": cfg.max_side_px,
        "max_pixels": cfg.max_pixels,
    }


def public_listing_key(public_id: str, key: str | None) -> str | None:
    """A stored photo/banner key, only if it still has this listing's shape."""
    return key if key and parse_key(public_id, key) else None


# ---------------------------------------------------------------------------
# Lifecycle collectors (cursor in, keys out; the caller enqueues in its transaction)
# ---------------------------------------------------------------------------

def _own_keys(rows) -> list[str]:
    """Only keys that still look like listing media keys are ever returned for
    deletion, so a tampered column can never make the outbox delete anything else."""
    out = []
    for (key,) in rows:
        if isinstance(key, str) and key.startswith(KEY_PREFIX + "/") and ".." not in key and key not in out:
            out.append(key)
    return out


def collect_group_keys(cur, group_id: str) -> list[str]:
    cur.execute(
        "SELECT m.object_key FROM group_listing_media m JOIN group_listings gl ON gl._id = m.listing_id "
        "WHERE gl.group_id = %s "
        "UNION SELECT gl.photo_key FROM group_listings gl WHERE gl.group_id = %s AND gl.photo_key IS NOT NULL "
        "UNION SELECT gl.banner_key FROM group_listings gl WHERE gl.group_id = %s AND gl.banner_key IS NOT NULL",
        (group_id, group_id, group_id),
    )
    return _own_keys(cur.fetchall())


def collect_owner_keys(cur, user_id: str) -> list[str]:
    """Keys of the listings of every group created by ``user_id`` (before they are deleted)."""
    cur.execute(
        "SELECT m.object_key FROM group_listing_media m JOIN group_listings gl ON gl._id = m.listing_id "
        "JOIN groups g ON g._id = gl.group_id WHERE g.creator_id = %s "
        "UNION SELECT gl.photo_key FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
        "WHERE g.creator_id = %s AND gl.photo_key IS NOT NULL "
        "UNION SELECT gl.banner_key FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
        "WHERE g.creator_id = %s AND gl.banner_key IS NOT NULL",
        (str(user_id), str(user_id), str(user_id)),
    )
    return _own_keys(cur.fetchall())
