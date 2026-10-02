"""Invite-link endpoints (task 20260929-group-invite-links, phase 1; task
20260930-subscription-seat-invites, phase 2).

The ``kind`` is part of the *internal* API (route paths name ``groups`` /
``subscriptions``); the subscription routes are siblings of the group ones and
leave them unchanged. Behavior lives in ``backend/interactions/invites.py``; this
module is only auth, rate limits, the feature flag, and HTTP mapping.

  POST   /invites/preview                          public, per-IP limited
  POST   /invites/{user_id}/redeem                 authenticated
  POST   /invites/{user_id}/groups/{group_id}      create (any member)
  GET    /invites/{user_id}/groups/{group_id}      list active (metadata only)
  POST   /invites/{user_id}/groups/{group_id}/reset  revoke all the caller may
  POST   /invites/{user_id}/subscriptions/{subscription_id}        create (plan owner only)
  GET    /invites/{user_id}/subscriptions/{subscription_id}        list (plan owner only)
  POST   /invites/{user_id}/subscriptions/{subscription_id}/reset  revoke all (plan owner only)
  GET    /invites/{user_id}/{invite_id}/reveal     re-show a derived group link (creator/manager)
  DELETE /invites/{user_id}/{invite_id}            revoke one

The token travels in a POST *body* (never a URL path/query) for preview and
redeem so it doesn't land in nginx/uvicorn access logs. Every response that
carries or depends on a token is ``Cache-Control: no-store``. When the
feature flag (config/invites.json ``enabled``) is off, every route answers
the same uniform 404 as an invalid token.
"""
import logging

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from backend.auth.dependencies import require_match
from backend.interactions.invites import InviteError, InvitesManager
from backend.interactions.invites_config import get_invites_config
from backend.rate_limiting import get_client_ip, limiter

invites_router = APIRouter(prefix="/invites")
logger = logging.getLogger(__name__)


class TokenBody(BaseModel):
    """Preview/redeem body. Length-bounded so a huge body is rejected (422)
    before any work is done."""
    token: str = Field(min_length=1, max_length=256)


class CreateInviteBody(BaseModel):
    """Both optional; omitted values use the configured defaults. Values must
    be members of the configured allowed sets. ``expires_in_days`` applies to
    subscription links only; group links never expire and ignore it."""
    expires_in_days: int | None = None
    max_uses: int | None = None


def _rate(name: str):
    return lambda: get_invites_config().rate_limits[name]


def _user_key(request: Request) -> str:
    # Runs after require_match resolved the path user_id against the session.
    return f"invites-user:{request.path_params.get('user_id')}"


def _require_enabled() -> None:
    if not get_invites_config().enabled:
        raise HTTPException(
            status_code=404,
            detail={"code": "not_found", "message": "This invite link isn't valid anymore."},
        )


def _http(err: InviteError) -> HTTPException:
    return HTTPException(status_code=err.status, detail=err.detail())


@invites_router.post("/preview")
@limiter.limit(_rate("preview"))
async def preview_invite(request: Request, response: Response, body: TokenBody) -> dict:
    """Public, unauthenticated. Minimal info for a currently-usable token:
    ``{"kind", "group_name", "photo_url", "inviter_username", "member_count"}``
    for a group link, ``{"kind": "subscription", "inviter_username", "plan_type"}``
    for a subscription link.

    Raises:
        HTTPException 404: uniform body for any unusable token (unknown,
        malformed, expired, revoked, exhausted, feature off). 429: rate limit.
    """
    response.headers["Cache-Control"] = "no-store"
    _require_enabled()
    manager = InvitesManager()
    try:
        return manager.preview(body.token, ip=get_client_ip(request))
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()


@invites_router.post("/{user_id}/redeem")
@limiter.limit(_rate("redeem"))
@limiter.limit(_rate("redeem_per_user"), key_func=_user_key)
async def redeem_invite(
    request: Request, response: Response, user_id: str, body: TokenBody,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Join via a token. Idempotent for an existing member.

    Returns:
        dict: ``{"kind", "target_id", "joined", "already_member"}``; for
        ``kind == "subscription"`` also ``"requested"``/``"pending"`` -- the
        caller has filed a join request, NOT joined the plan.

    Raises:
        HTTPException 404 not_found, 410 expired/revoked, 409 full,
        403 blocked (generic), 429 rate limited. ``detail`` is
        ``{"code", "message"}``.
    """
    response.headers["Cache-Control"] = "no-store"
    _require_enabled()
    manager = InvitesManager(user_id)
    try:
        return manager.redeem(body.token, ip=get_client_ip(request))
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()


@invites_router.post("/{user_id}/groups/{group_id}", status_code=201)
@limiter.limit(_rate("create"))
async def create_group_invite(
    request: Request, response: Response, user_id: str, group_id: str,
    body: CreateInviteBody | None = None,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Create a link (any member). The plaintext ``token``/``url`` are in this
    response only -- they cannot be retrieved again.

    Raises:
        HTTPException 403 not a member, 409 link_limit, 422 value not allowed.
    """
    response.headers["Cache-Control"] = "no-store"
    _require_enabled()
    body = body or CreateInviteBody()
    manager = InvitesManager(user_id)
    try:
        return manager.create("group", group_id, body.expires_in_days, body.max_uses,
                              ip=get_client_ip(request))
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()


@invites_router.get("/{user_id}/groups/{group_id}")
@limiter.limit(_rate("list"))
async def list_group_invites(
    request: Request, response: Response, user_id: str, group_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Active links the caller can manage (own; all for the group creator).
    Metadata only, never a token. Also returns the configured create options
    so clients don't hardcode them.

    Raises:
        HTTPException 403: not a member.
    """
    response.headers["Cache-Control"] = "no-store"
    _require_enabled()
    cfg = get_invites_config()
    manager = InvitesManager(user_id)
    try:
        invites = manager.list_active("group", group_id)
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()
    return {
        "invites": invites,
        "options": {
            "default_expiry_days": cfg.default_expiry_days,
            "allowed_expiry_days": list(cfg.allowed_expiry_days),
            "default_max_uses": cfg.default_max_uses,
            "allowed_max_uses": list(cfg.allowed_max_uses),
            "max_active_links_per_user_per_group": cfg.max_active_links_per_user_per_group,
            "max_group_members_ceiling": cfg.max_group_members_ceiling,
        },
    }


# ── Subscription-seat invites (plan owner only) ───────────────────────────────

@invites_router.post("/{user_id}/subscriptions/{subscription_id}", status_code=201)
@limiter.limit(_rate("create"))
async def create_subscription_invite(
    request: Request, response: Response, user_id: str, subscription_id: str,
    body: CreateInviteBody | None = None,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Create a join-request link for a plan. Owner only, on an active group
    plan with more than one seat. The plaintext ``token``/``url`` are in this
    response only. Opening the link files a *request*; it never grants access.

    Raises:
        HTTPException 403 not the plan owner, 409 not_eligible / link_limit,
        422 value not allowed.
    """
    response.headers["Cache-Control"] = "no-store"
    _require_enabled()
    body = body or CreateInviteBody()
    manager = InvitesManager(user_id)
    try:
        return manager.create("subscription", subscription_id, body.expires_in_days,
                              body.max_uses, ip=get_client_ip(request))
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()


@invites_router.get("/{user_id}/subscriptions/{subscription_id}")
@limiter.limit(_rate("list"))
async def list_subscription_invites(
    request: Request, response: Response, user_id: str, subscription_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Active links for a plan (metadata only, never a token) plus the
    subscription create options. Owner only.

    Raises:
        HTTPException 403: not the plan owner.
    """
    response.headers["Cache-Control"] = "no-store"
    _require_enabled()
    cfg = get_invites_config()
    manager = InvitesManager(user_id)
    try:
        invites = manager.list_active("subscription", subscription_id)
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()
    return {
        "invites": invites,
        "options": {
            "default_expiry_days": cfg.subscription_default_expiry_days,
            "allowed_expiry_days": list(cfg.subscription_allowed_expiry_days),
            "default_max_uses": cfg.subscription_default_max_uses,
            "allowed_max_uses": list(cfg.subscription_allowed_max_uses),
            "max_active_links_per_subscription": cfg.max_active_links_per_subscription,
        },
    }


@invites_router.post("/{user_id}/subscriptions/{subscription_id}/reset")
@limiter.limit(_rate("revoke"))
async def reset_subscription_invites(
    request: Request, response: Response, user_id: str, subscription_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Revoke every active link for the plan. Owner only. Returns ``{"revoked": n}``."""
    _require_enabled()
    manager = InvitesManager(user_id)
    try:
        return {"revoked": manager.reset("subscription", subscription_id, ip=get_client_ip(request))}
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()


@invites_router.post("/{user_id}/groups/{group_id}/reset")
@limiter.limit(_rate("revoke"))
async def reset_group_invites(
    request: Request, response: Response, user_id: str, group_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Revoke every active link the caller may revoke. Returns ``{"revoked": n}``."""
    _require_enabled()
    manager = InvitesManager(user_id)
    try:
        return {"revoked": manager.reset("group", group_id, ip=get_client_ip(request))}
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()


@invites_router.get("/{user_id}/{invite_id}/reveal")
@limiter.limit(_rate("reveal"))
@limiter.limit(_rate("reveal_per_user"), key_func=_user_key)
async def reveal_invite(
    request: Request, response: Response, user_id: str, invite_id: str,
    _: str = Depends(require_match("user_id")),
) -> dict:
    """Re-show an active group link's URL to its creator or the group's
    manager. Legacy (non-derived) links cannot be revealed.

    Returns:
        dict: ``{"invite_id", "url"}``. ``Cache-Control: no-store``.

    Raises:
        HTTPException 404: one uniform not_found for every failure (unknown,
        revoked, expired, exhausted, legacy, subscription, not authorized).
        429: rate limited.
    """
    response.headers["Cache-Control"] = "no-store"
    _require_enabled()
    manager = InvitesManager(user_id)
    try:
        return manager.reveal(invite_id, ip=get_client_ip(request))
    except InviteError as e:
        exc = _http(e)
        exc.headers = {"Cache-Control": "no-store"}
        raise exc
    finally:
        manager.close()


@invites_router.delete("/{user_id}/{invite_id}", status_code=204)
@limiter.limit(_rate("revoke"))
async def revoke_invite(
    request: Request, response: Response, user_id: str, invite_id: str,
    _: str = Depends(require_match("user_id")),
) -> None:
    """Revoke one link (its creator, or the group creator). Idempotent.

    Raises:
        HTTPException 404 unknown id / not a member, 403 not creator/manager.
    """
    _require_enabled()
    manager = InvitesManager(user_id)
    try:
        manager.revoke(invite_id, ip=get_client_ip(request))
    except InviteError as e:
        raise _http(e)
    finally:
        manager.close()
