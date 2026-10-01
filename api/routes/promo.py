"""Promo (creator + friend invite) code endpoints (task 20260930-creator-friend-codes).

  POST /promo/{user_id}/validate          authenticated, rate-limited, uniform result
  POST /promo/{user_id}/friend-code       authenticated; get-or-create the caller's invite code
  POST/GET/PATCH /admin/promo/creators..  admin only
  POST/GET/PATCH /admin/promo/codes..     admin only
  GET /admin/promo/report                 redemption counts per creator
  GET /admin/promo/redemptions            redemption list

Behavior lives in ``backend/subscription/promo.py``; this module is auth, the
feature flag, rate limits and HTTP mapping. With PROMO_CODES_ENABLED off every
route answers a uniform 404 (checked before auth so the surface looks absent).
Billing itself (coupon at checkout, redemption logging) is in
``routes/subscription.py``.
"""
import logging
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from backend.auth.dependencies import require_admin, require_match
from backend.rate_limiting import get_client_ip, limiter
from backend.subscription import stripe_service
from backend.subscription.promo import PromoError, PromoManager, promo_config, promo_enabled

logger = logging.getLogger(__name__)
audit_logger = logging.getLogger("admin_audit")


def _require_enabled() -> None:
    if not promo_enabled():
        raise HTTPException(status_code=404, detail="Not found")


def _rate() -> str:
    return promo_config().validate_rate_limit


def _not_limited() -> bool:
    return not promo_enabled()


def _user_key(request: Request) -> str:
    return f"promo-user:{request.path_params.get('user_id')}"


def _audit(action: str, admin_id: str, target: str | None = None) -> None:
    # Ids only -- never code text or PII.
    audit_logger.info("admin_action action=%s admin_id=%s target=%s", action, admin_id, target)


def _uuid(value: str) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, AttributeError):
        raise HTTPException(status_code=404, detail="Not found")


def _utc(dt: datetime | None) -> datetime | None:
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _http(e: PromoError) -> HTTPException:
    return HTTPException(status_code=e.status, detail=e.message)


# ── User surface ──────────────────────────────────────────────────────────────

promo_router = APIRouter(prefix="/promo", dependencies=[Depends(_require_enabled)])


class ValidateBody(BaseModel):
    code: str = Field(max_length=64)
    member_count: int = 1


@promo_router.post("/{user_id}/validate")
@limiter.limit(_rate, exempt_when=_not_limited)
@limiter.limit(_rate, key_func=_user_key, exempt_when=_not_limited)
async def validate_promo(
    request: Request, response: Response, user_id: str, body: ValidateBody,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Is this code usable by the caller right now? Every failure (unknown,
    malformed, inactive, expired, exhausted, own code, group plan, not a new
    subscriber, any error) returns the identical ``{"valid": false}``.

    Creates nothing and logs no redemption; the redemption is recorded only
    when the purchase completes (Stripe webhook).
    """
    response.headers["Cache-Control"] = "no-store"
    db = PromoManager()
    try:
        email = _email(db, user_id)
        row = db.evaluate(user_id, body.code, body.member_count, email)
    finally:
        db.close()
    if not row:
        logger.info("promo validate denied user=%s ip=%s", user_id, get_client_ip(request))
        return {"valid": False}
    return {"valid": True, "percent_off": promo_config().discount_percent}


@promo_router.post("/{user_id}/friend-code")
@limiter.limit(_rate, exempt_when=_not_limited)
async def get_friend_code(
    request: Request, response: Response, user_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Get (generating on first call, idempotent) the caller's personal invite
    code and its shareable link."""
    response.headers["Cache-Control"] = "no-store"
    db = PromoManager()
    try:
        code = db.get_or_create_friend_code(user_id)
    except Exception as e:
        logger.error("friend code generation failed for %s: %s", user_id, e)
        raise HTTPException(status_code=500, detail="Could not create invite code")
    finally:
        db.close()
    return {"code": code, "link": f"{stripe_service._SITE}/?code={code}",
            "percent_off": promo_config().discount_percent}


def _email(db: PromoManager, user_id: str) -> str:
    db.cur.execute("SELECT email FROM users WHERE _id = %s", (user_id,))
    row = db.cur.fetchone()
    return (row[0] or "") if row else ""


# ── Admin surface ─────────────────────────────────────────────────────────────

promo_admin_router = APIRouter(prefix="/admin/promo", dependencies=[Depends(_require_enabled)])


class CreatorCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    notes: str = Field(default="", max_length=2000)


class CreatorUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    notes: str | None = Field(default=None, max_length=2000)
    active: bool | None = None


class CodeCreate(BaseModel):
    code: str = Field(max_length=64)
    creator_id: str
    max_redemptions: int | None = Field(default=None, gt=0)
    expires_at: datetime | None = None


class CodeUpdate(BaseModel):
    active: bool | None = None
    max_redemptions: int | None = Field(default=None, gt=0)
    expires_at: datetime | None = None


@promo_admin_router.post("/creators", status_code=201)
async def create_creator(body: CreatorCreate, admin_id: str = Depends(require_admin)) -> dict:
    db = PromoManager()
    try:
        out = db.create_creator(body.name.strip(), body.notes)
    finally:
        db.close()
    _audit("promo_creator_create", admin_id, out["id"])
    return out


@promo_admin_router.get("/creators")
async def list_creators(admin_id: str = Depends(require_admin)) -> list[dict]:
    db = PromoManager()
    try:
        return db.list_creators()
    finally:
        db.close()


@promo_admin_router.patch("/creators/{creator_id}")
async def update_creator(creator_id: str, body: CreatorUpdate, admin_id: str = Depends(require_admin)) -> dict:
    cid = _uuid(creator_id)
    db = PromoManager()
    try:
        out = db.update_creator(cid, body.model_dump(exclude_unset=True))
    except PromoError as e:
        raise _http(e)
    finally:
        db.close()
    if out is None:
        raise HTTPException(status_code=404, detail="Not found")
    _audit("promo_creator_update", admin_id, cid)
    return out


@promo_admin_router.post("/codes", status_code=201)
async def create_code(body: CodeCreate, admin_id: str = Depends(require_admin)) -> dict:
    cid = _uuid(body.creator_id)
    db = PromoManager()
    try:
        out = db.create_creator_code(body.code, cid, body.max_redemptions, _utc(body.expires_at))
    except PromoError as e:
        raise _http(e)
    finally:
        db.close()
    _audit("promo_code_create", admin_id, out["id"])
    return out


@promo_admin_router.get("/codes")
async def list_codes(kind: str | None = None, creator_id: str | None = None,
                     limit: int = 100, offset: int = 0,
                     admin_id: str = Depends(require_admin)) -> list[dict]:
    if kind not in (None, "creator", "friend"):
        raise HTTPException(status_code=422, detail="kind must be creator or friend")
    db = PromoManager()
    try:
        return db.list_codes(kind, _uuid(creator_id) if creator_id else None,
                             max(1, min(limit, 500)), max(0, offset))
    finally:
        db.close()


@promo_admin_router.patch("/codes/{code_id}")
async def update_code(code_id: str, body: CodeUpdate, admin_id: str = Depends(require_admin)) -> dict:
    cid = _uuid(code_id)
    fields = body.model_dump(exclude_unset=True)
    if "expires_at" in fields:
        fields["expires_at"] = _utc(fields["expires_at"])
    db = PromoManager()
    try:
        out = db.update_code(cid, fields)
    except PromoError as e:
        raise _http(e)
    finally:
        db.close()
    if out is None:
        raise HTTPException(status_code=404, detail="Not found")
    _audit("promo_code_update", admin_id, cid)
    return out


@promo_admin_router.get("/report")
async def redemption_report(admin_id: str = Depends(require_admin)) -> list[dict]:
    """Completed redemptions per creator (``over_cap_redemptions`` are rows
    logged past a code's max_redemptions, for review, not counted)."""
    db = PromoManager()
    try:
        return db.report_by_creator()
    finally:
        db.close()


@promo_admin_router.get("/redemptions")
async def list_redemptions(creator_id: str | None = None, kind: str | None = None,
                           limit: int = 100, offset: int = 0,
                           admin_id: str = Depends(require_admin)) -> list[dict]:
    if kind not in (None, "creator", "friend"):
        raise HTTPException(status_code=422, detail="kind must be creator or friend")
    db = PromoManager()
    try:
        return db.list_redemptions(_uuid(creator_id) if creator_id else None, kind,
                                   max(1, min(limit, 500)), max(0, offset))
    finally:
        db.close()
