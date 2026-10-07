"""Email verification API (task 20261007-email-verification).

  GET  /auth/email/status   caller's own state: {enabled, verified}            (session)
  POST /auth/email/resend   mail a fresh link to the caller's own address      (session)
  POST /auth/email/verify   consume an emailed token                           (token only)

While ``email_verification.enabled`` is false, resend and verify answer a
uniform 404 and status reports ``enabled: false``. Resend acts only on the
session user's own address (no email is ever taken from the client), always
returns the same 202 body whether a mail was sent, throttled or failed, and
verify returns one uniform 400 for an unknown, expired, reused or stale token.
No email address or token is logged. Plain ``def`` handlers (threadpool).
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from backend.auth.dependencies import get_current_user
from backend.auth.email_verification import (
    EmailVerificationManager, is_enabled, send_verification_email,
)
from backend.auth.email_verification_config import get_email_verification_config
from backend.rate_limiting import limiter

logger = logging.getLogger(__name__)

email_verification_router = APIRouter(prefix="/auth/email")


class VerifyEmail(BaseModel):
    token: str = Field(min_length=1, max_length=256)


def _require_enabled() -> None:
    if not is_enabled():
        raise HTTPException(status_code=404, detail="Not found")


def _rate_verify() -> str:
    return get_email_verification_config().rate_limit_verify


def _rate_resend() -> str:
    return get_email_verification_config().rate_limit_resend


def _rate_status() -> str:
    return get_email_verification_config().rate_limit_status


@email_verification_router.get("/status")
@limiter.limit(_rate_status)
def email_status(request: Request, response: Response, user_id: str = Depends(get_current_user)) -> dict:
    response.headers["Cache-Control"] = "no-store"
    cfg = get_email_verification_config()
    if not cfg.enabled:
        return {"enabled": False, "verified": False}
    mgr = EmailVerificationManager()
    try:
        verified = mgr.is_verified(user_id)
    finally:
        mgr.close()
    return {"enabled": True, "verified": verified, "resend_cooldown_seconds": cfg.resend_cooldown_seconds}


@email_verification_router.post("/resend", status_code=202, dependencies=[Depends(_require_enabled)])
@limiter.limit(_rate_resend)
def email_resend(request: Request, response: Response, user_id: str = Depends(get_current_user)) -> dict:
    """Mail a new link to the session user's own address (uniform response)."""
    response.headers["Cache-Control"] = "no-store"
    cfg = get_email_verification_config()
    mgr = EmailVerificationManager()
    try:
        already = mgr.is_verified(user_id)
        email = None
        if not already:
            mgr.cur.execute("SELECT email FROM users WHERE _id = %s", (user_id,))
            row = mgr.cur.fetchone()
            email = row[0] if row else None
    finally:
        mgr.close()
    if email:
        send_verification_email(user_id, email)
    return {"detail": "If a verification email is due, it has been sent.",
            "resend_cooldown_seconds": cfg.resend_cooldown_seconds}


@email_verification_router.post("/verify", dependencies=[Depends(_require_enabled)])
@limiter.limit(_rate_verify)
def email_verify(request: Request, response: Response, info: VerifyEmail) -> dict:
    """Consume an emailed token. One uniform 400 for every failure mode."""
    response.headers["Cache-Control"] = "no-store"
    mgr = EmailVerificationManager()
    try:
        ok = mgr.verify(info.token)
    finally:
        mgr.close()
    if not ok:
        raise HTTPException(status_code=400, detail="Invalid or expired verification link")
    return {"verified": True}
