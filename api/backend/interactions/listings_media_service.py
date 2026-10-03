"""Owner-facing listing media operations (task 20261002-explorer-listing-media).

``ListingMediaManager`` extends ``ListingsManager`` so it reuses its config
loading, terms gate, transaction wrapper and the "creator, still a member, not
suspended or uniform 404" proof. Routes are plain ``def`` (R-ROUTE) and call
this class; flag, auth and rate limits live in ``routes/explorer.py``.

Flow (presigned POST, never a proxy):

1. ``upload_url``: owner asks for a presigned POST for one image (photo,
   banner or description image). Caps come from the ready rows of
   ``group_listing_media``.
2. The client POSTs the file straight to S3.
3. ``confirm``: only now does anything become referenced. The key must be this
   listing's own (uniform 404 otherwise), the bytes are re-encoded into a NEW
   key (``listings_media.process_image``), the row is inserted under the group
   lock, and the ORIGINAL key is queued in the S3 outbox on every path.
4. ``use_group_photo``: same pipeline with the group's current photo as the
   source. The source belongs to the group, so it is never queued for deletion,
   and it is re-encoded rather than copied (a raw server-side copy would carry
   the original EXIF/GPS into a publicly readable key).

The database lock is never held across S3 or Pillow work: ownership and caps
are checked first, the S3/decode work runs with no transaction open, and a
second transaction re-checks and writes.
"""
from __future__ import annotations

import logging

from backend.interactions import attachments, lifecycle, listings_media
from backend.interactions.listing_content import ListingError
from backend.interactions.listings import (
    ListingsManager,
    _canon,
    _not_found,
    requeue_for_review,
)
from backend.interactions.listings_media_config import MediaConfig, get_media_config

logger = logging.getLogger(__name__)

_NO_LISTING = ("listing_required", "Save your listing before adding images.")


class ListingMediaManager(ListingsManager):
    """Media operations for one owner (one DB connection)."""

    def __init__(self, user_id: str) -> None:
        super().__init__(user_id)
        self.media_cfg: MediaConfig = get_media_config()

    # -- shared pieces ---------------------------------------------------------

    def _listing(self, gid: str, *, for_update: bool = False) -> tuple[str, str]:
        self.cur.execute(
            "SELECT _id::text, public_id FROM group_listings WHERE group_id = %s"
            + (" FOR UPDATE" if for_update else ""),
            (gid,),
        )
        row = self.cur.fetchone()
        if row is None:
            raise ListingError(409, *_NO_LISTING)
        return row[0], row[1]

    @staticmethod
    def _check_kind(kind) -> str:
        if kind not in listings_media.KINDS:
            raise ListingError(422, "invalid_field", "kind must be photo, banner or image.", "kind")
        return kind

    def _check_caps(self, listing_id: str, kind: str, new_bytes: int) -> None:
        """Count and byte caps from the ready rows. A new photo or banner replaces
        the old one, so that kind's existing rows do not count against the cap."""
        self.cur.execute(
            "SELECT kind, count(*), COALESCE(sum(size_bytes), 0) FROM group_listing_media "
            "WHERE listing_id = %s AND status = 'ready' GROUP BY kind",
            (listing_id,),
        )
        counts: dict[str, int] = {}
        sizes: dict[str, int] = {}
        for k, n, total in self.cur.fetchall():
            counts[k], sizes[k] = int(n), int(total)
        if kind in ("photo", "banner"):
            counts.pop(kind, None)
            sizes.pop(kind, None)
        cfg = self.media_cfg
        if sum(counts.values()) + 1 > cfg.max_images_per_listing:
            raise ListingError(409, "media_limit", f"A listing can have up to {cfg.max_images_per_listing} images.")
        if kind == "image" and counts.get("image", 0) + 1 > cfg.max_description_images:
            raise ListingError(409, "media_limit", f"A description can have up to {cfg.max_description_images} images.")
        if sum(sizes.values()) + new_bytes > cfg.max_bytes_per_listing:
            raise ListingError(409, "media_limit", "This listing has reached its image storage limit.")

    def _enqueue(self, keys) -> None:
        """Queue keys in the S3 outbox in their own short transaction."""
        keys = [k for k in dict.fromkeys(keys) if k]
        if not keys:
            return
        try:
            self.conn.rollback()
            lifecycle.enqueue_s3_deletes(self.cur, keys)
            self.conn.commit()
        except Exception:  # noqa: BLE001 - the sweeper catches anything we could not queue
            self.conn.rollback()
            logger.warning("LISTING_MEDIA enqueue failed count=%d", len(keys))

    # -- upload-url ------------------------------------------------------------

    def upload_url(self, group_id: str, kind: str, content_type: str) -> dict:
        self._check_kind(kind)
        with self._tx("media_upload_url"):
            self.require_terms()
            group = self._lock_owned_group(group_id, lock=False)
            listing_id, public_id = self._listing(group["group_id"])
            if content_type not in self.media_cfg.allowed_mime:
                raise ListingError(422, "unsupported_media_type", "Use a JPEG, PNG or WebP image.", "content_type")
            self._check_caps(listing_id, kind, 0)
        try:
            return listings_media.presign_upload(public_id, content_type, self.media_cfg)
        except attachments.AttachmentConfigError:
            raise ListingError(503, "media_unavailable", "Image storage is unavailable. Try again shortly.") from None

    # -- confirm -----------------------------------------------------------------

    def confirm(self, group_id: str, kind: str, object_key: str, alt_text) -> dict:
        self._check_kind(kind)
        cfg = self.media_cfg
        alt = listings_media.clean_alt(
            alt_text, "alt_text", required=kind in ("banner", "image"), list_cfg=self.cfg, mcfg=cfg
        )
        with self._tx("media_confirm_check"):
            self.require_terms()
            group = self._lock_owned_group(group_id, lock=False)
            gid = group["group_id"]
            listing_id, public_id = self._listing(gid)
            parsed = listings_media.parse_key(public_id, object_key)
            if parsed is None:
                raise _not_found()
            mime, _ext = parsed
            self.cur.execute("SELECT 1 FROM group_listing_media WHERE object_key = %s", (object_key,))
            if self.cur.fetchone() is not None:  # the key of a stored derivative is never a source
                raise _not_found()
            target = listings_media.derived_key(public_id, object_key, mime)
            existing = self._existing_item(target)
            if existing is not None:
                return existing
            self._check_caps(listing_id, kind, 0)
        return self._ingest(gid, public_id, kind, object_key, mime, target, alt, delete_source=True)

    def use_group_photo(self, group_id: str) -> dict:
        from backend.interactions.group_photo import is_group_photo_key

        cfg = self.media_cfg
        with self._tx("media_group_photo_check"):
            self.require_terms()
            group = self._lock_owned_group(group_id, lock=False)
            gid = group["group_id"]
            listing_id, public_id = self._listing(gid)
            self.cur.execute("SELECT photo_key FROM groups WHERE _id = %s", (gid,))
            row = self.cur.fetchone()
            source = row[0] if row else None
            if not is_group_photo_key(gid, source):
                raise ListingError(422, "no_group_photo", "This group doesn't have a photo yet.")
            mime = listings_media.mime_for_key(source)
            if mime not in cfg.allowed_mime:
                raise ListingError(422, "unsupported_media_type", "That group photo's format can't be used here. Upload a JPEG, PNG or WebP image.")
            self._check_caps(listing_id, "photo", 0)
        target = listings_media.build_key(public_id, mime)
        return self._ingest(gid, public_id, "photo", source, mime, target, None, delete_source=False)

    # -- the shared ingest ---------------------------------------------------------

    def _ingest(self, gid, public_id, kind, source_key, mime, target_key, alt, *, delete_source: bool) -> dict:
        cfg = self.media_cfg
        committed = False
        stored = False
        try:
            with listings_media.confirm_slot(cfg):
                raw = listings_media.fetch_for_processing(source_key, mime, cfg)
                processed = listings_media.process_image(raw, mime, cfg)
                del raw
            listings_media.store_derivative(target_key, processed)
            stored = True
            item = self._record(gid, kind, target_key, processed, alt)
            committed = True
            return item
        finally:
            leftovers = []
            if delete_source:
                leftovers.append(source_key)
            if stored and not committed:
                leftovers.append(target_key)
            self._enqueue(leftovers)

    def _record(self, gid: str, kind: str, key: str, processed, alt) -> dict:
        cfg = self.media_cfg
        with self._tx("media_confirm_write"):
            self._lock_owned_group(gid)
            listing_id, _public_id = self._listing(gid, for_update=True)
            existing = self._existing_item(key)
            if existing is not None:
                return existing
            self._check_caps(listing_id, kind, len(processed.data))
            released: list[str] = []
            if kind in ("photo", "banner"):
                self.cur.execute(
                    "DELETE FROM group_listing_media WHERE listing_id = %s AND kind = %s RETURNING object_key",
                    (listing_id, kind),
                )
                released = [r[0] for r in self.cur.fetchall()]
            self.cur.execute(
                "INSERT INTO group_listing_media (listing_id, object_key, kind, size_bytes, width, height, alt_text, status) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, 'ready') ON CONFLICT (object_key) DO NOTHING RETURNING _id::text",
                (listing_id, key, kind, len(processed.data), processed.width, processed.height, alt),
            )
            row = self.cur.fetchone()
            if row is None:
                existing = self._existing_item(key)
                if existing is not None:
                    return existing
                raise ListingError(409, "media_conflict", "That image was already added.")
            media_id = row[0]
            if kind == "photo":
                self.cur.execute("UPDATE group_listings SET photo_key = %s, updated_at = NOW() WHERE _id = %s", (key, listing_id))
            elif kind == "banner":
                self.cur.execute(
                    "UPDATE group_listings SET banner_key = %s, banner_alt = %s, updated_at = NOW() WHERE _id = %s",
                    (key, alt, listing_id),
                )
            # A key that was queued for deletion earlier must not be deleted out from under a live row.
            self.cur.execute("DELETE FROM pending_s3_deletes WHERE key = %s", (key,))
            lifecycle.enqueue_s3_deletes(self.cur, released)
            self._requeue(gid)
            logger.info("LISTING_MEDIA stored kind=%s", kind)
            return {
                "media_id": media_id, "kind": kind, "url": listings_media.media_url(key, cfg),
                "width": processed.width, "height": processed.height, "alt_text": alt,
            }

    def _existing_item(self, key: str) -> dict | None:
        self.cur.execute(
            "SELECT _id::text, kind, object_key, width, height, alt_text FROM group_listing_media "
            "WHERE object_key = %s AND status = 'ready'",
            (key,),
        )
        row = self.cur.fetchone()
        return None if row is None else listings_media._item(row, self.media_cfg)

    def _requeue(self, gid: str) -> None:
        if self.cfg.require_approval:
            requeue_for_review(self.cur, gid, "media")

    # -- delete ---------------------------------------------------------------------

    def delete_media(self, group_id: str, media_id: str) -> None:
        mid = _canon(media_id)
        if mid is None:
            raise _not_found()
        with self._tx("media_delete"):
            self.require_terms()
            group = self._lock_owned_group(group_id)
            gid = group["group_id"]
            listing_id, _public_id = self._listing(gid, for_update=True)
            self.cur.execute(
                "SELECT kind, object_key FROM group_listing_media WHERE _id = %s AND listing_id = %s FOR UPDATE",
                (mid, listing_id),
            )
            row = self.cur.fetchone()
            if row is None:
                raise _not_found()
            kind, key = row
            if kind == "image":
                self.cur.execute(
                    "SELECT 1 FROM group_listings, jsonb_array_elements(COALESCE(description_blocks, '[]'::jsonb)) b "
                    "WHERE _id = %s AND b->>'type' = 'image' AND b->>'media_id' = %s LIMIT 1",
                    (listing_id, mid),
                )
                if self.cur.fetchone() is not None:
                    raise ListingError(409, "media_in_use", "Remove the image from the description first.")
            self.cur.execute("DELETE FROM group_listing_media WHERE _id = %s", (mid,))
            if kind == "photo":
                self.cur.execute("UPDATE group_listings SET photo_key = NULL, updated_at = NOW() WHERE _id = %s", (listing_id,))
            elif kind == "banner":
                self.cur.execute(
                    "UPDATE group_listings SET banner_key = NULL, banner_alt = NULL, updated_at = NOW() WHERE _id = %s",
                    (listing_id,),
                )
            lifecycle.enqueue_s3_deletes(self.cur, [key])
            self._requeue(gid)
