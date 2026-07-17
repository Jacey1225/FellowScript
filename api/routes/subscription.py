from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel
from datetime import datetime, timezone
import time
import logging
from backend.subscription.subscriptions import SubscriptionsManager
from backend.subscription.limits import LimitsManager
from backend.subscription import stripe_service
from backend.subscription import apple_service
from schemas.subscription import SubscriptionCreate, SubscriptionUpdate

subscription_router = APIRouter(prefix="/subscriptions")
logger = logging.getLogger(__name__)


class CheckoutRequest(BaseModel):
    user_id: str
    plan_type: str = "individual"


class AppleSyncRequest(BaseModel):
    user_id: str
    jws: str          # StoreKit 2 signed transaction (jwsRepresentation)


def _ts(epoch):
    """Stripe unix epoch (seconds) → tz-aware datetime (or None)."""
    return datetime.fromtimestamp(epoch, tz=timezone.utc) if epoch else None


def _ms(epoch_ms):
    """Apple unix epoch (milliseconds) → tz-aware datetime (or None)."""
    return datetime.fromtimestamp(epoch_ms / 1000, tz=timezone.utc) if epoch_ms else None


# ── Plans: CRUD ────────────────────────────────────────────────────────────────

@subscription_router.post("/", status_code=201)
async def create_subscription(sub: SubscriptionCreate) -> dict:
    """Start a new subscription plan; the host becomes its first member.

    Args:
        sub: Plan payload. ``plan_type`` ('individual' | 'group') determines the
            price and member cap server-side.

    Returns:
        dict: ``{"id": str}`` of the created plan.
    """
    db = SubscriptionsManager()
    try:
        return {"id": db.create_subscription(sub)}
    finally:
        db.close()


# ── Stripe billing (web) ────────────────────────────────────────────────────────
# These literal routes are declared before the "/{subscription_id}" wildcard.

@subscription_router.post("/checkout")
async def create_checkout(req: CheckoutRequest) -> dict:
    """Create a Stripe Checkout Session for a free-trial subscription.

    Returns ``{"url": str}`` — the browser redirects there to enter payment on
    Stripe's hosted page. The subscription row is created by the webhook once
    checkout completes.
    """
    if not stripe_service.is_configured():
        raise HTTPException(status_code=503, detail="Payments are not configured.")
    db = SubscriptionsManager()
    try:
        email = db.get_user_email(req.user_id)
    finally:
        db.close()
    try:
        url = stripe_service.create_checkout_session(req.user_id, email, req.plan_type)
        return {"url": url}
    except Exception as e:
        logger.error("Stripe checkout error: %s", e)
        raise HTTPException(status_code=502, detail="Could not start checkout.")


@subscription_router.post("/stripe/webhook")
async def stripe_webhook(request: Request) -> dict:
    """Stripe → server events. Signature-verified; the source of truth for status.

    Handles trial start, renewals, payment failures, and cancellations, keeping
    the subscriptions table in sync with Stripe.
    """
    payload = await request.body()
    sig     = request.headers.get("stripe-signature", "")
    try:
        event = stripe_service.construct_event(payload, sig)
    except Exception as e:
        logger.warning("Rejected Stripe webhook: %s", e)
        raise HTTPException(status_code=400, detail="Invalid webhook signature")

    etype = event["type"]
    obj   = event["data"]["object"]
    db = SubscriptionsManager()
    try:
        if etype == "checkout.session.completed":
            user_id   = obj.get("client_reference_id") or (obj.get("metadata") or {}).get("user_id")
            plan_type = (obj.get("metadata") or {}).get("plan_type", "individual")
            customer  = obj.get("customer") or ""
            sub_id    = obj.get("subscription") or ""
            if user_id and sub_id:
                sub  = stripe_service.retrieve_subscription(sub_id)
                card = stripe_service.card_from_subscription(sub)
                db.upsert_from_stripe(
                    user_id=user_id, plan_type=plan_type, customer_id=customer,
                    stripe_sub_id=sub_id, status=sub.get("status") or "active",
                    trial_end=_ts(sub.get("trial_end")),
                    current_period_end=_ts(sub.get("current_period_end")),
                    card=card,
                )
                logger.info("Stripe checkout completed → plan for user %s", user_id)

        elif etype == "customer.subscription.updated":
            db.update_status_from_stripe(
                obj.get("id"), obj.get("status") or "active",
                current_period_end=_ts(obj.get("current_period_end")),
                trial_end=_ts(obj.get("trial_end")),
            )

        elif etype == "customer.subscription.deleted":
            db.cancel_by_stripe_sub(obj.get("id"))

        elif etype == "invoice.payment_failed":
            if obj.get("subscription"):
                db.update_status_from_stripe(obj.get("subscription"), "past_due")
    except Exception as e:
        logger.error("Error handling %s: %s", etype, e)
    finally:
        db.close()
    return {"received": True}


# ── Apple StoreKit billing (iOS) ────────────────────────────────────────────────

@subscription_router.post("/apple/sync")
async def apple_sync(req: AppleSyncRequest) -> dict:
    """Record/refresh an Apple subscription from a StoreKit 2 signed transaction.

    The iOS app sends the JWS after StoreKit has verified it on-device (on
    purchase, restore, or launch). We decode it, map the product to a plan, and
    upsert the row. If the transaction has expired/been refunded, the plan is
    removed. Returns the resulting plan (or ``{"status": ...}``).
    """
    try:
        payload = apple_service.decode_jws(req.jws)
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid transaction")

    plan_type = apple_service.plan_type_for(payload.get("productId", ""))
    if not plan_type:
        raise HTTPException(status_code=400, detail="Unknown product")

    otxn       = str(payload.get("originalTransactionId") or payload.get("transactionId") or "")
    expires_ms = payload.get("expiresDate")
    is_trial   = payload.get("offerType") == 1 or payload.get("offerDiscountType") == "FREE_TRIAL"
    active     = expires_ms is None or expires_ms > (time.time() * 1000)
    cpe        = _ms(expires_ms)

    db = SubscriptionsManager()
    try:
        if not active:
            db.cancel_by_apple_txn(otxn)
            return {"status": "expired"}
        status = "trialing" if is_trial else "active"
        db.upsert_from_apple(req.user_id, plan_type, otxn, status, cpe, cpe if is_trial else None)
        return db.get_user_subscription(req.user_id) or {"status": status}
    finally:
        db.close()


@subscription_router.post("/apple/notifications")
async def apple_notifications(request: Request) -> dict:
    """App Store Server Notifications V2 → keep status in sync (renew/expire/refund).

    Register this URL in App Store Connect. The signed payload is decoded and the
    matching plan updated by original transaction id.
    """
    try:
        body   = await request.json()
        note   = apple_service.decode_jws(body.get("signedPayload", ""))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid notification")

    ntype = note.get("notificationType")
    data  = note.get("data") or {}
    txn   = {}
    if data.get("signedTransactionInfo"):
        try:
            txn = apple_service.decode_jws(data["signedTransactionInfo"])
        except Exception:
            txn = {}
    otxn = str(txn.get("originalTransactionId") or "")
    if not otxn:
        return {"received": True}

    db = SubscriptionsManager()
    try:
        if ntype in ("DID_RENEW", "SUBSCRIBED", "DID_CHANGE_RENEWAL_STATUS", "OFFER_REDEEMED"):
            db.update_status_by_apple_txn(otxn, "active", _ms(txn.get("expiresDate")))
        elif ntype in ("EXPIRED", "REFUND", "REVOKE", "GRACE_PERIOD_EXPIRED"):
            db.cancel_by_apple_txn(otxn)
    except Exception as e:
        logger.error("Apple notification %s error: %s", ntype, e)
    finally:
        db.close()
    return {"received": True}


# NOTE: static-prefix routes ("/user/...") are declared before the "/{subscription_id}"
# wildcard so their literal segment matches first.

@subscription_router.get("/user/{user_id}")
async def get_user_subscription(user_id: str) -> dict:
    """Return the plan the given user currently belongs to.

    Raises:
        HTTPException 404: If the user is not on any plan.
    """
    db = SubscriptionsManager()
    try:
        result = db.get_user_subscription(user_id)
        if result is None:
            raise HTTPException(status_code=404, detail="No active subscription")
        return result
    finally:
        db.close()


@subscription_router.get("/user/{user_id}/requests")
async def get_user_requests(user_id: str) -> list[dict]:
    """List the group plans this user has an outstanding join request for."""
    db = SubscriptionsManager()
    try:
        return db.get_user_requests(user_id)
    finally:
        db.close()


@subscription_router.get("/user/{user_id}/usage")
async def get_usage(user_id: str) -> dict:
    """Free-tier usage snapshot for the gated resources.

    Returns the user's subscription state plus, for each resource (notes, agent
    events, agent notifications), how much has been used against the free cap.
    Subscribed users are reported as ``unlimited``. Drives the client's usage
    meters and upgrade prompts.

    Returns:
        dict: ``{"subscribed", "plan_type", "window_days", "resources": {...}}``.
    """
    db = LimitsManager()
    try:
        return db.usage_summary(user_id)
    finally:
        db.close()


@subscription_router.get("/{subscription_id}")
async def get_subscription(subscription_id: str) -> dict:
    """Fetch a single plan by id.

    Raises:
        HTTPException 404: If the plan does not exist.
    """
    db = SubscriptionsManager()
    try:
        result = db.get_subscription(subscription_id)
        if result is None:
            raise HTTPException(status_code=404, detail="Subscription not found")
        return result
    finally:
        db.close()


@subscription_router.put("/{subscription_id}")
async def update_subscription(subscription_id: str, upd: SubscriptionUpdate) -> dict:
    """Update a plan (payment method, status, or plan_type — which re-derives price).

    Raises:
        HTTPException 404: If the plan does not exist.
    """
    db = SubscriptionsManager()
    try:
        if not db.update_subscription(subscription_id, upd):
            raise HTTPException(status_code=404, detail="Subscription not found")
        return {"ok": True}
    finally:
        db.close()


@subscription_router.delete("/{subscription_id}", status_code=204)
async def delete_subscription(subscription_id: str) -> None:
    """Cancel a plan and detach all of its members.

    If the plan is backed by a Stripe subscription, it is canceled in Stripe
    first so billing stops, then the local row is removed.
    """
    db = SubscriptionsManager()
    try:
        stripe_sub = db.get_stripe_sub_id(subscription_id)
        if stripe_sub:
            stripe_service.cancel_subscription(stripe_sub)
        db.delete_subscription(subscription_id)
    finally:
        db.close()


# ── Members ────────────────────────────────────────────────────────────────────

@subscription_router.get("/{subscription_id}/members")
async def get_members(subscription_id: str) -> list[dict]:
    """List every user enrolled in the plan (host included)."""
    db = SubscriptionsManager()
    try:
        return db.get_members(subscription_id)
    finally:
        db.close()


@subscription_router.delete("/{subscription_id}/members/{user_id}", status_code=204)
async def remove_member(subscription_id: str, user_id: str) -> None:
    """Remove a member from a group plan (host removes, or member leaves).

    Raises:
        HTTPException 400: If the plan is missing or the target is the host.
    """
    db = SubscriptionsManager()
    try:
        result = db.remove_member(subscription_id, user_id)
        if result and "error" in result:
            raise HTTPException(status_code=400, detail=result["error"])
    finally:
        db.close()


# ── Group join requests ────────────────────────────────────────────────────────

@subscription_router.post("/{subscription_id}/requests", status_code=201)
async def create_request(subscription_id: str, from_user_id: str) -> dict:
    """Request to join a host's group plan.

    Args:
        subscription_id: The group plan to join.
        from_user_id: UUID of the requesting user (query parameter).

    Raises:
        HTTPException 400: If the plan is missing, not a group, full, or the
            user is already the host/a member.
    """
    db = SubscriptionsManager()
    try:
        result = db.create_request(subscription_id, from_user_id)
        if result and "error" in result:
            raise HTTPException(status_code=400, detail=result["error"])
        return {"ok": True}
    finally:
        db.close()


@subscription_router.get("/{subscription_id}/requests")
async def get_requests(subscription_id: str) -> list[dict]:
    """List pending join requests for a plan (for the host to review)."""
    db = SubscriptionsManager()
    try:
        return db.get_requests(subscription_id)
    finally:
        db.close()


@subscription_router.post("/{subscription_id}/requests/{from_user_id}/accept")
async def accept_request(subscription_id: str, from_user_id: str) -> dict:
    """Host accepts a pending request, enrolling the user in the plan.

    Raises:
        HTTPException 400: If the plan is missing, no such request exists, or
            the plan is full.
    """
    db = SubscriptionsManager()
    try:
        result = db.accept_request(subscription_id, from_user_id)
        if result and "error" in result:
            raise HTTPException(status_code=400, detail=result["error"])
        return {"ok": True}
    finally:
        db.close()


@subscription_router.delete("/{subscription_id}/requests/{from_user_id}", status_code=204)
async def decline_request(subscription_id: str, from_user_id: str) -> None:
    """Decline (host) or cancel (requester) a pending join request."""
    db = SubscriptionsManager()
    try:
        db.delete_request(subscription_id, from_user_id)
    finally:
        db.close()
