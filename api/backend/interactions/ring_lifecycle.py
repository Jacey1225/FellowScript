"""Shared ring lifecycle helpers (task 20261028-dm-direct-call).

Used identically by DM calls and group session rings; there is no second
calling path. The ring record lives in ``ring_states`` (see
``DevotionManager.record_ring`` and friends); this module only adds the
VoIP ``ring_cancel`` push and the server-side expiry sweep.

A cancel push is only sent when the ring was delivered as a VoIP push (the
stored ``voip_token`` is set). With ``RING_VOIP_ENABLED=false`` rings are
plain alert pushes, there is no CallKit UI to dismiss, and the lifecycle
degrades to state tracking only (the caller still sees declined/no-answer
via the status route).
"""
import logging

from backend.interactions.devotion import DevotionManager

logger = logging.getLogger(__name__)

# Seconds between server-side expiry sweeps. Small relative to the ring
# window (RING_TIMEOUT_SECONDS) so a dead client Timer is backstopped fast.
RING_EXPIRY_POLL_INTERVAL_SECONDS = 10


async def send_ring_cancel(voip_token: str | None, devotion_id: str, caller_id: str, reason: str) -> bool:
    """Send a VoIP ``ring_cancel`` push so the target's CallKit UI ends.
    Best-effort: never raises (the state change is already recorded).
    Returns True only if a push was accepted."""
    if not voip_token:
        return False
    try:
        from backend.interactions.push import send_voip_push
        return bool(await send_voip_push(
            voip_token,
            data={
                "action": "ring_cancel",
                "devotion_id": devotion_id,
                "caller_id": caller_id,
                "reason": reason,
            },
        ))
    except Exception as e:
        logger.error("Ring cancel push failed (session %s, reason %s): %s", devotion_id, reason, type(e).__name__)
        return False


async def expire_due_rings() -> int:
    """Time out every ring past its server-side expiry and cancel the
    target's CallKit UI. Returns how many rings were expired. Safe to call
    from both the scheduler and the status route; the DB transition is an
    atomic compare-and-set, so each ring is expired and cancelled once."""
    db = DevotionManager()
    try:
        expired = db.expire_due_rings()
    finally:
        db.close()
    for ring in expired:
        await send_ring_cancel(ring["voip_token"], ring["devotion_id"], ring["caller_id"], "timed_out")
    return len(expired)


async def run_ring_expiry_job() -> None:
    """Scheduler entry point. A failure is logged, never raised (a bad cycle
    must not stop the interval job)."""
    try:
        n = await expire_due_rings()
        if n:
            logger.info("Ring expiry sweep timed out %d ring(s)", n)
    except Exception as e:
        logger.warning("Ring expiry sweep failed: %s", type(e).__name__)
