"""Owner-suspension sweeper for Explorer listings (scheduler job).

``listings.public_where`` is the visibility authority: a listing whose owner is
suspended, gone or no longer a member disappears from public queries at once.
This job only makes the STATE agree (status ``hidden``, reason
``owner_suspended`` or ``owner_gone``) and fires the ``listing_hidden`` hooks so
other features (join requests) expire what depended on the listing.

R-SCHED: ``run_listing_sweeper_job`` is a thin ``async def``; every database
call runs in ``sweep_once`` through ``loop.run_in_executor``. A run that hid
listings logs one INFO line with the count; a run with per-listing failures
logs ONE aggregated WARNING with counts (never ids or text). The bare word
ERROR never appears here (the watchdog treats it as a detection).
"""
import asyncio
import logging

from backend.interactions import listings
from backend.interactions.listings_config import get_listings_config
from db import DBManager

logger = logging.getLogger(__name__)

JOB_ID = "listing_owner_sweep"

_CANDIDATES_SQL = (
    "SELECT gl.group_id::text FROM group_listings gl "
    "WHERE gl.status IN ('pending_review', 'published') "
    f"AND NOT {listings.owner_present_sql('gl')} "
    "ORDER BY gl.updated_at LIMIT %s"
)


def sweep_once(batch_size: int | None = None) -> dict:
    """Hide listings whose owner is no longer present. Returns
    ``{"found", "hidden", "failed"}``. Each listing is handled in its own
    transaction under the group row lock, re-checking the condition."""
    if batch_size is None:
        batch_size = get_listings_config().sweeper_batch_size
    counts = {"found": 0, "hidden": 0, "failed": 0}
    db = DBManager()
    try:
        db.cur.execute(_CANDIDATES_SQL, (batch_size,))
        group_ids = [r[0] for r in db.cur.fetchall()]
        db.conn.rollback()
        counts["found"] = len(group_ids)
        for group_id in group_ids:
            try:
                db.cur.execute("SELECT 1 FROM groups WHERE _id = %s FOR UPDATE", (group_id,))
                reason = listings.owner_available(db.cur, group_id)
                if reason is not None and listings.hide_in_tx(db.cur, group_id, reason):
                    counts["hidden"] += 1
                db.conn.commit()
            except Exception:  # noqa: BLE001 - one bad row must not stop the sweep
                db.conn.rollback()
                counts["failed"] += 1
    finally:
        db.close()
    if counts["failed"]:
        logger.warning(
            "LISTING_SWEEP partial: found=%d hidden=%d failed=%d",
            counts["found"], counts["hidden"], counts["failed"],
        )
    elif counts["hidden"]:
        logger.info("LISTING_SWEEP hidden=%d", counts["hidden"])
    return counts


async def run_listing_sweeper_job() -> None:
    """Scheduler entry: thin async wrapper, all DB work off the event loop."""
    loop = asyncio.get_running_loop()
    try:
        await loop.run_in_executor(None, sweep_once)
    except Exception as e:  # noqa: BLE001 - a failed run is retried next tick
        logger.warning("LISTING_SWEEP run failed: %s", type(e).__name__)
