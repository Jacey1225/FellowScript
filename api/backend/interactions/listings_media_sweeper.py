"""Orphan sweeper for listing media under ``listings/`` (scheduler job).

An orphan is an object under ``listings/`` that is older than
``orphan_grace_hours`` and is not referenced by ``group_listing_media``, by a
listing's ``photo_key`` / ``banner_key`` or by any listing's ``description_blocks``
(typically the original of an upload whose confirm never came). Orphans are
ENQUEUED in the S3 outbox (``pending_s3_deletes``) and never deleted inline: the
outbox is the only deleter, so denial reporting and retries live in one place.

R-SCHED: ``run_listing_media_sweeper_job`` is a thin ``async def``; every
boto3 and psycopg2 call runs in ``sweep_once`` through
``loop.run_in_executor(None, ...)``. One run examines at most
``sweep_max_keys_per_run`` objects; the continuation token is kept in process
so successive runs walk the whole prefix (a restart starts again from the
beginning, which only costs a re-scan). Logging: one aggregated WARNING per run
with counts when anything went wrong (never a key), one INFO when keys were
queued. A ListBucket AccessDenied is aggregated into the same run line and
raises at most one ``S3_DELETE_DENIED`` ERROR per prefix per 24 h through the
outbox's shared per-prefix limiter, so a policy gap is noticed without a flood
(the limiter's memory is in-process: a restart can repeat the line once). The bare
word ERROR never appears in non-error lines (the watchdog treats it as a detection).
"""
from __future__ import annotations

import asyncio
import logging
import threading
from datetime import datetime, timedelta, timezone

from botocore.exceptions import BotoCoreError, ClientError

from backend.interactions import attachments, lifecycle, s3_outbox
from backend.interactions.listings_media import KEY_PREFIX, parse_key
from backend.interactions.listings_media_config import get_media_config
from db import DBManager

logger = logging.getLogger(__name__)

JOB_ID = "listing_media_sweep"
_PAGE_SIZE = 500
_DENIED_CODES = frozenset({"AccessDenied", "403", "Forbidden", "AllAccessDisabled"})
_PROBE_PREFIX = f"{KEY_PREFIX}/_probe/"

_state_lock = threading.Lock()
_continuation: str | None = None


def reset_for_tests() -> None:
    global _continuation
    with _state_lock:
        _continuation = None


def _is_listing_media_key(key: str) -> bool:
    """Only keys shaped ``listings/{public_id}/{uuid}{ext}`` are ever candidates, so a
    stray or probe object under the prefix is left alone."""
    if not key.startswith(KEY_PREFIX + "/") or key.startswith(_PROBE_PREFIX) or ".." in key:
        return False
    parts = key.split("/")
    return len(parts) == 3 and parse_key(parts[1], key) is not None


def _referenced(cur, keys: list[str]) -> set[str]:
    cur.execute("SELECT object_key FROM group_listing_media WHERE object_key = ANY(%s)", (keys,))
    found = {r[0] for r in cur.fetchall()}
    cur.execute(
        "SELECT photo_key FROM group_listings WHERE photo_key = ANY(%s) "
        "UNION SELECT banner_key FROM group_listings WHERE banner_key = ANY(%s)",
        (keys, keys),
    )
    found |= {r[0] for r in cur.fetchall()}
    for key in keys:
        if key in found:
            continue
        cur.execute(
            "SELECT 1 FROM group_listings WHERE position(%s in COALESCE(description_blocks::text, '')) > 0 LIMIT 1",
            (key,),
        )
        if cur.fetchone() is not None:
            found.add(key)
    return found


def sweep_once(list_fn=None) -> dict:
    """One bounded pass. ``list_fn(prefix, token, max_keys) -> (objects, next_token)`` is
    injectable so tests need no S3; each object is ``{"Key", "LastModified"}``.
    Returns ``{"examined", "orphans", "enqueued", "list_denied", "failed"}``."""
    global _continuation
    cfg = get_media_config()
    counts = {"examined": 0, "orphans": 0, "enqueued": 0, "list_denied": 0, "failed": 0}
    if list_fn is None:
        if not attachments.S3_BUCKET_NAME:
            return counts
        list_fn = _list_page
    cutoff = datetime.now(timezone.utc) - timedelta(hours=cfg.orphan_grace_hours)
    with _state_lock:
        token = _continuation
    budget = cfg.sweep_max_keys_per_run
    db = None
    try:
        while budget > 0:
            try:
                objects, token = list_fn(KEY_PREFIX + "/", token, min(_PAGE_SIZE, budget))
            except ClientError as e:
                code = str((e.response or {}).get("Error", {}).get("Code", ""))
                if code in _DENIED_CODES:
                    counts["list_denied"] += 1
                    token = None
                else:
                    counts["failed"] += 1
                break
            except (attachments.AttachmentConfigError, BotoCoreError):
                counts["failed"] += 1
                break
            budget -= max(len(objects), 1)
            counts["examined"] += len(objects)
            old = [
                o["Key"] for o in objects
                if o["LastModified"] < cutoff and _is_listing_media_key(o["Key"])
            ]
            if old:
                if db is None:
                    db = DBManager()
                try:
                    kept = _referenced(db.cur, old)
                    orphans = [k for k in old if k not in kept]
                    counts["orphans"] += len(orphans)
                    counts["enqueued"] += lifecycle.enqueue_s3_deletes(db.cur, orphans)
                    db.conn.commit()
                except Exception:  # noqa: BLE001 - one bad page must not stop the job
                    db.conn.rollback()
                    counts["failed"] += 1
            if token is None:
                break
    finally:
        if db is not None:
            db.close()
    with _state_lock:
        _continuation = token
    if counts["list_denied"]:
        s3_outbox._log_denied_once_per_day({KEY_PREFIX})
    if counts["list_denied"] or counts["failed"]:
        logger.warning(
            "LISTING_MEDIA_SWEEP partial: examined=%d orphans=%d enqueued=%d list_denied=%d failed=%d",
            counts["examined"], counts["orphans"], counts["enqueued"], counts["list_denied"], counts["failed"],
        )
    elif counts["enqueued"]:
        logger.info("LISTING_MEDIA_SWEEP examined=%d enqueued=%d", counts["examined"], counts["enqueued"])
    return counts


def _list_page(prefix: str, token: str | None, max_keys: int):
    attachments.validate_attachment_config()
    kwargs = {"Bucket": attachments.S3_BUCKET_NAME, "Prefix": prefix, "MaxKeys": max_keys}
    if token:
        kwargs["ContinuationToken"] = token
    response = attachments._client().list_objects_v2(**kwargs)
    return response.get("Contents", []), response.get("NextContinuationToken")


async def run_listing_media_sweeper_job() -> None:
    """Scheduler entry: thin async wrapper, all S3 and DB work off the event loop."""
    loop = asyncio.get_running_loop()
    try:
        await loop.run_in_executor(None, sweep_once)
    except Exception as e:  # noqa: BLE001 - a failed run is retried next tick
        logger.warning("LISTING_MEDIA_SWEEP run failed: %s", type(e).__name__)
