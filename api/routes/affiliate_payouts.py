"""Affiliate payout details API (task 20261008-affiliate-payout-details).

  GET    /affiliates/payouts                 masked status (last-4 only)
  POST   /affiliates/payouts/reauth          email a single-purpose code
  POST   /affiliates/payouts/reauth/verify   {code, password?} -> {proof, expires_in}
  PUT    /affiliates/payouts                 {proof, routing_number, account_number, account_type, holder_name}
  POST   /affiliates/payouts/delete          {proof}
  GET    /admin/affiliate-payouts            admin: last-4 list only
  POST   /admin/affiliate-payouts/reauth[/verify]   admin re-auth (purpose payout_admin_reveal)
  POST   /admin/affiliate-payouts/reveal     {owner_email, proof, reason} -> decrypted, audited first

Deny-by-default: uniform 404 (before auth) unless BOTH the ``affiliates`` and
``affiliate_payouts`` flags are on; the affiliate is the session's creator-code
owner (same ``_require_creator`` gate as the rest of the page), never a client id.

Value hygiene: bodies are read and validated by hand (no pydantic body model), so
the FastAPI 422 "input" echo can never carry a submitted number; every response,
including errors, goes out through ``_PayoutRoute`` with ``Cache-Control: no-store``;
errors are fixed codes, not input; nothing here logs a request field.
"""
import json
import logging
from typing import Callable

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from slowapi.errors import RateLimitExceeded

from backend.auth.dependencies import get_current_user, require_admin
from backend.auth.email_verification import verification_satisfied
from backend.email.ses_client import EmailSendError, send_email
from backend.email.templates import payout_code_email, payout_notice_email
from backend.interactions import flags
from backend.rate_limiting import get_client_ip, limiter
from backend.subscription.affiliate_payouts import PURPOSE_REVEAL, PURPOSE_WRITE, PayoutError, PayoutManager
from backend.subscription.affiliates import AffiliateManager
from backend.subscription.affiliates_config import get_affiliates_config

logger = logging.getLogger(__name__)

_NO_STORE = {"Cache-Control": "no-store", "Pragma": "no-cache", "X-Content-Type-Options": "nosniff"}


class _PayoutRoute(APIRoute):
    """Adds the no-store headers to every response, errors included, and turns any
    escaping exception into a fixed, value-free body."""

    def get_route_handler(self) -> Callable:
        inner = super().get_route_handler()

        async def handler(request: Request):
            try:
                resp = await inner(request)
            except HTTPException as e:
                return JSONResponse({"detail": e.detail}, status_code=e.status_code, headers=_NO_STORE)
            except RateLimitExceeded:
                return JSONResponse({"detail": "rate_limited"}, status_code=429, headers=_NO_STORE)
            except PayoutError as e:
                return JSONResponse({"detail": e.code}, status_code=e.status, headers=_NO_STORE)
            except Exception as e:  # never format e: it may hold a value
                logger.error("payouts: unhandled %s", type(e).__name__)
                return JSONResponse({"detail": "server_error"}, status_code=500, headers=_NO_STORE)
            for k, v in _NO_STORE.items():
                resp.headers[k] = v
            return resp

        return handler


def _require_enabled() -> None:
    if not (flags.is_enabled("affiliates") and flags.is_enabled("affiliate_payouts")):
        raise HTTPException(status_code=404, detail="Not found")


payouts_router = APIRouter(prefix="/affiliates/payouts", route_class=_PayoutRoute,
                           dependencies=[Depends(_require_enabled)])
admin_payouts_router = APIRouter(prefix="/admin/affiliate-payouts", route_class=_PayoutRoute,
                                 dependencies=[Depends(_require_enabled)])


def _cfg():
    return get_affiliates_config().payouts


def _rate(name: str):
    return lambda: getattr(_cfg(), name)


async def _body(request: Request) -> dict:
    """Bounded, hand-parsed JSON object. Fixed error codes only."""
    limit = _cfg().max_body_bytes
    raw = await request.body()
    if len(raw) > limit:
        raise HTTPException(status_code=413, detail="too_large")
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        raise HTTPException(status_code=400, detail="invalid_request") from None
    if not isinstance(data, dict):
        raise HTTPException(status_code=400, detail="invalid_request")
    return data


def _require_creator(request: Request) -> dict:
    user_id = get_current_user(request)
    try:
        verified = verification_satisfied(user_id)
    except Exception:
        verified = False
    if not verified:
        raise HTTPException(status_code=403, detail="Forbidden")
    db = AffiliateManager()
    try:
        affiliate = db.resolve_affiliate(user_id)
    finally:
        db.close()
    if affiliate is None:
        raise HTTPException(status_code=403, detail="Forbidden")
    return {"user_id": user_id, "email": affiliate["email"]}


def _ctx(request: Request) -> tuple[str, str]:
    return get_client_ip(request), request.headers.get("user-agent", "")


def _notify(user_id: str, kind: str) -> None:
    """Best-effort tripwire email; a failure never blocks the action."""
    db = PayoutManager(_cfg())
    try:
        email, _ = db.user_account(user_id)
    except Exception:
        return
    finally:
        db.close()
    try:
        subject, html_body, text_body = payout_notice_email(kind)
        send_email(email, subject, html_body, text_body)
    except Exception as e:
        logger.warning("payouts: notice email failed (%s)", type(e).__name__)


def _send_code(user_id: str, purpose: str) -> dict:
    db = PayoutManager(_cfg())
    try:
        email, has_pw = db.user_account(user_id)
        code = db.issue_code(user_id, purpose)
    finally:
        db.close()
    subject, html_body, text_body = payout_code_email(code)
    try:
        send_email(email, subject, html_body, text_body)
    except EmailSendError:
        logger.error("payouts: failed to send re-auth code")
        raise HTTPException(status_code=503, detail="email_failed") from None
    return {"sent": True, "password_required": has_pw}


def _verify(request: Request, user_id: str, purpose: str, body: dict) -> dict:
    ip, ua = _ctx(request)
    if not set(body) <= {"code", "password"}:
        raise HTTPException(status_code=400, detail="invalid_request")
    db = PayoutManager(_cfg())
    try:
        token = db.verify_reauth(user_id, purpose, body.get("code"), body.get("password"), ip, ua)
    finally:
        db.close()
    return {"proof": token, "expires_in": _cfg().proof_ttl_seconds}


# -- affiliate routes ---------------------------------------------------------

@payouts_router.get("")
@limiter.limit(_rate("read_rate"))
def get_status(request: Request, response: Response, who: dict = Depends(_require_creator)) -> dict:
    db = PayoutManager(_cfg())
    try:
        return db.get_view(who["email"])
    finally:
        db.close()


@payouts_router.post("/reauth")
@limiter.limit(_rate("reauth_rate"))
def reauth(request: Request, response: Response, who: dict = Depends(_require_creator)) -> dict:
    return _send_code(who["user_id"], PURPOSE_WRITE)


@payouts_router.post("/reauth/verify")
@limiter.limit(_rate("reauth_rate"))
def reauth_verify(request: Request, response: Response, who: dict = Depends(_require_creator),
                  body: dict = Depends(_body)) -> dict:
    return _verify(request, who["user_id"], PURPOSE_WRITE, body)


@payouts_router.put("")
@limiter.limit(_rate("write_rate"))
def save_details(request: Request, response: Response, who: dict = Depends(_require_creator),
                 body: dict = Depends(_body)) -> dict:
    ip, ua = _ctx(request)
    proof = body.pop("proof", None)
    db = PayoutManager(_cfg())
    try:
        db.save(who["user_id"], who["email"], proof, body, ip, ua)
        view = db.get_view(who["email"])
    finally:
        db.close()
    _notify(who["user_id"], "saved")
    return view


@payouts_router.post("/delete")
@limiter.limit(_rate("write_rate"))
def delete_details(request: Request, response: Response, who: dict = Depends(_require_creator),
                   body: dict = Depends(_body)) -> dict:
    ip, ua = _ctx(request)
    if set(body) != {"proof"}:
        raise HTTPException(status_code=400, detail="invalid_request")
    db = PayoutManager(_cfg())
    try:
        deleted = db.delete(who["user_id"], who["email"], body["proof"], ip, ua)
    finally:
        db.close()
    if deleted:
        _notify(who["user_id"], "deleted")
    return {"status": "not_set"}


# -- admin routes -------------------------------------------------------------

@admin_payouts_router.get("")
@limiter.limit(_rate("read_rate"))
def admin_list(request: Request, response: Response, admin_id: str = Depends(require_admin)) -> dict:
    db = PayoutManager(_cfg())
    try:
        return {"items": db.admin_list()}
    finally:
        db.close()


@admin_payouts_router.post("/reauth")
@limiter.limit(_rate("reauth_rate"))
def admin_reauth(request: Request, response: Response, admin_id: str = Depends(require_admin)) -> dict:
    return _send_code(admin_id, PURPOSE_REVEAL)


@admin_payouts_router.post("/reauth/verify")
@limiter.limit(_rate("reauth_rate"))
def admin_reauth_verify(request: Request, response: Response, admin_id: str = Depends(require_admin),
                        body: dict = Depends(_body)) -> dict:
    return _verify(request, admin_id, PURPOSE_REVEAL, body)


@admin_payouts_router.post("/reveal")
@limiter.limit(_rate("reveal_rate"))
def admin_reveal(request: Request, response: Response, admin_id: str = Depends(require_admin),
                 body: dict = Depends(_body)) -> dict:
    ip, ua = _ctx(request)
    owner, reason = body.get("owner_email"), body.get("reason")
    if set(body) != {"owner_email", "proof", "reason"} or not isinstance(owner, str) \
            or not isinstance(reason, str) or not 5 <= len(reason.strip()) <= 200 or len(owner) > 320:
        raise HTTPException(status_code=400, detail="invalid_request")
    subject = owner.strip().lower()
    db = PayoutManager(_cfg())
    try:
        out = db.reveal(admin_id, subject, body["proof"], reason.strip(), ip, ua)
    finally:
        db.close()
    if out is None:
        raise HTTPException(status_code=404, detail="not_found")
    _notify_affiliate_by_email(subject)
    return out


def _notify_affiliate_by_email(owner_email: str) -> None:
    try:
        subject, html_body, text_body = payout_notice_email("accessed")
        send_email(owner_email, subject, html_body, text_body)
    except Exception as e:
        logger.warning("payouts: access notice failed (%s)", type(e).__name__)
