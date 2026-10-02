"""Admin moderation surface for Explorer listings (``/admin/explorer/listings``).

Plain ``def`` handlers (threadpool; they take ``FOR UPDATE`` row locks and send
SES mail, so nothing here runs on the event loop). Admin only via
``require_admin`` (401 without a session, 403 for a non-admin). Behaviour lives
in ``backend/interactions/listings.py`` (``admin_*`` transitions) and
``listing_reports.py`` (owner emails); this module is auth, rate limit,
commit/rollback and HTTP mapping. Log lines carry ids and codes only.

  GET    /admin/explorer/listings/queue?status=pending_review&limit=50
  POST   /admin/explorer/listings/{public_id}/approve
  POST   /admin/explorer/listings/{public_id}/reject    {"reason_code": ...}
  POST   /admin/explorer/listings/{public_id}/hide      {"reason_code": ...}
  POST   /admin/explorer/listings/{public_id}/restore
  DELETE /admin/explorer/listings/{public_id}
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from backend.auth.dependencies import require_admin
from backend.interactions import listing_reports, listings
from backend.interactions.listing_content import ListingError
from backend.interactions.listings_config import get_listings_config
from backend.rate_limiting import limiter
from db import DBManager

explorer_admin_router = APIRouter(prefix="/admin/explorer/listings")
logger = logging.getLogger(__name__)


def _rate() -> str:
    return get_listings_config().rate_limits["admin"]


class ReasonBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reason_code: str = Field(max_length=40)


def _run(action: str, public_id: str, admin_id: str, fn, *args) -> dict:
    """One transition in one transaction; returns ``(result)`` after commit."""
    db = DBManager()
    try:
        try:
            result = fn(db.cur, public_id, admin_id, *args)
            gid = None
            if action in ("reject", "hide"):
                db.cur.execute("SELECT group_id::text FROM group_listings WHERE public_id = %s", (public_id,))
                row = db.cur.fetchone()
                gid = row[0] if row else None
            db.conn.commit()
        except ListingError as e:
            db.conn.rollback()
            raise HTTPException(status_code=e.status, detail=e.detail())
        except Exception:
            db.conn.rollback()
            raise
    finally:
        db.close()
    logger.info("LISTING_MODERATION action=%s public_id=%s admin=%s", action, public_id, admin_id)
    if gid is not None:
        listing_reports.notify_owner(gid, action, args[0] if args else None)
    return result


@explorer_admin_router.get("/queue")
@limiter.limit(_rate)
def listing_queue(
    request: Request, status: str = "pending_review", limit: int = 50, admin_id: str = Depends(require_admin),
) -> dict:
    db = DBManager()
    try:
        try:
            items = listings.admin_queue(db.cur, status, limit)
        except ListingError as e:
            raise HTTPException(status_code=e.status, detail=e.detail())
        finally:
            db.conn.rollback()
    finally:
        db.close()
    return {"items": items}


@explorer_admin_router.post("/{public_id}/approve")
@limiter.limit(_rate)
def approve_listing(request: Request, public_id: str, admin_id: str = Depends(require_admin)) -> dict:
    return _run("approve", public_id, admin_id, listings.admin_approve)


@explorer_admin_router.post("/{public_id}/reject")
@limiter.limit(_rate)
def reject_listing(
    request: Request, public_id: str, body: ReasonBody, admin_id: str = Depends(require_admin),
) -> dict:
    return _run("reject", public_id, admin_id, listings.admin_reject, body.reason_code)


@explorer_admin_router.post("/{public_id}/hide")
@limiter.limit(_rate)
def hide_listing(
    request: Request, public_id: str, body: ReasonBody, admin_id: str = Depends(require_admin),
) -> dict:
    return _run("hide", public_id, admin_id, listings.admin_hide, body.reason_code)


@explorer_admin_router.post("/{public_id}/restore")
@limiter.limit(_rate)
def restore_listing(request: Request, public_id: str, admin_id: str = Depends(require_admin)) -> dict:
    return _run("restore", public_id, admin_id, listings.admin_restore)


@explorer_admin_router.delete("/{public_id}")
@limiter.limit(_rate)
def remove_listing(request: Request, public_id: str, admin_id: str = Depends(require_admin)) -> dict:
    return _run("remove", public_id, admin_id, listings.admin_remove)
