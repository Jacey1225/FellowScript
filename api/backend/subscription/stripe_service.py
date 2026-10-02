"""Stripe billing integration (web).

Thin wrapper around the Stripe SDK: creates hosted Checkout Sessions for the
subscription flow (optional trial per TRIAL_MONTHS), verifies incoming webhooks, and cancels
subscriptions. All plan pricing is derived from GROUP_PRICE_CENTS (inline
price_data) so no pre-created Stripe Products/Prices are required.

Secrets come from the environment (same pattern as DB_PASSWORD / APNs):
    STRIPE_SECRET_KEY      — sk_test_… / sk_live_…
    TRIAL_MONTHS           — web free-trial length in months; 0 = no trial (required)
    STRIPE_SIGNING_SECRET  — whsec_…  (set after registering the webhook endpoint;
                             STRIPE_WEBHOOK_SECRET is also accepted as an alias)
"""

import os
import logging
import stripe
from schemas.subscription import price_for, MIN_MEMBERS, MAX_MEMBERS

logger = logging.getLogger(__name__)

stripe.api_key = os.getenv("STRIPE_SECRET_KEY", "")


def _plain(obj):
    """Return plain dicts/lists for a Stripe SDK object. stripe>=13 objects are
    no longer dict subclasses (no ``.get``), and this module and the webhook
    handlers read them with ``.get``; convert once at the SDK boundary."""
    to_dict = getattr(obj, "to_dict", None)
    return to_dict() if callable(to_dict) else obj

# Where Stripe returns the browser after checkout. The query lives before the
# HashRouter fragment so window.location.search sees it on the account page.
_SITE = os.getenv("SITE_URL", "https://fellowscript.com")
SUCCESS_URL = f"{_SITE}/?sub=success#/account"
CANCEL_URL  = f"{_SITE}/?sub=cancel#/account"
DONATE_SUCCESS_URL = f"{_SITE}/?donate=success#/account"
DONATE_CANCEL_URL  = f"{_SITE}/?donate=cancel#/account"

class TrialConfigError(RuntimeError):
    """Raised at startup when TRIAL_MONTHS is missing or invalid."""


_TRIAL_MONTHS_RAW = os.getenv("TRIAL_MONTHS")
# Parsed by validate_trial_config() at boot; read via trial_months().
_trial_months: int | None = None


def validate_trial_config() -> None:
    """Eagerly validate and parse TRIAL_MONTHS (web/Stripe free-trial length).

    Call once at process startup (main.py lifespan). There is no implicit
    default: 0 means "no trial" and must be set explicitly.

    Raises:
        TrialConfigError: if TRIAL_MONTHS is unset or not a non-negative integer.
    """
    global _trial_months
    raw = os.getenv("TRIAL_MONTHS", _TRIAL_MONTHS_RAW)
    if raw is None or not raw.strip():
        raise TrialConfigError(
            "TRIAL_MONTHS is not set. There is no implicit default for the web "
            "free-trial length -- set it explicitly (0 = no trial, 1 = one month)."
        )
    try:
        months = int(raw)
    except ValueError:
        raise TrialConfigError(f"TRIAL_MONTHS ({raw!r}) is not a valid integer.")
    if months < 0:
        raise TrialConfigError(f"TRIAL_MONTHS ({months}) must be 0 or greater.")
    _trial_months = months


def trial_months() -> int:
    """Validated TRIAL_MONTHS. Raises if validate_trial_config() has not run."""
    if _trial_months is None:
        raise TrialConfigError("TRIAL_MONTHS has not been validated; call validate_trial_config() at startup.")
    return _trial_months


def is_configured() -> bool:
    return bool(stripe.api_key)


def promo_coupon_id(percent_off: int) -> str:
    """Deterministic id of the single shared first-month coupon for a percent."""
    return f"fellowscript-first-month-{percent_off}pct"


def ensure_promo_coupon(percent_off: int) -> str:
    """Return the id of the shared ``percent_off`` / ``duration=once`` coupon,
    creating it on first use. One coupon serves every promo code (the DB is
    authoritative for which codes are valid; creator/referrer attribution
    travels in session metadata)."""
    cid = promo_coupon_id(percent_off)
    try:
        coupon = _plain(stripe.Coupon.retrieve(cid))
    except stripe.InvalidRequestError:
        stripe.Coupon.create(
            id=cid, percent_off=percent_off, duration="once",
            name=f"FellowScript first month {percent_off}% off",
        )
        return cid
    # Fail closed if someone edited/replaced the coupon with different terms.
    if coupon.get("percent_off") != percent_off or coupon.get("duration") != "once":
        raise RuntimeError(f"Stripe coupon {cid} has unexpected terms")
    return cid


def ensure_owner_reward_coupon(percent_off: int) -> str:
    """Shared ``percent_off`` / ``duration=once`` coupon for owner rewards
    (separate id from the invitee first-month coupon). Fails closed if the
    existing coupon's terms were changed."""
    cid = f"fellowscript-owner-reward-{percent_off}pct"
    try:
        coupon = _plain(stripe.Coupon.retrieve(cid))
    except stripe.InvalidRequestError:
        stripe.Coupon.create(
            id=cid, percent_off=percent_off, duration="once",
            name=f"FellowScript owner reward {percent_off}% off next month",
        )
        return cid
    if coupon.get("percent_off") != percent_off or coupon.get("duration") != "once":
        raise RuntimeError(f"Stripe coupon {cid} has unexpected terms")
    return cid


def apply_owner_reward(stripe_sub_id: str, percent_off: int, reward_id: str) -> bool:
    """Attach the once-off owner-reward coupon to a Stripe subscription so the
    NEXT invoice is discounted. Returns True if the discount for ``reward_id``
    is in place (applied now, or already applied by an earlier attempt that
    crashed before the ledger commit: recognized via subscription metadata
    ``owner_reward_id``). Returns False (nothing changed) when applying would
    be ambiguous: subscription not active, set to cancel, or already carrying
    some OTHER discount (never stack or overwrite). Stripe errors propagate.
    """
    sub = _plain(stripe.Subscription.retrieve(stripe_sub_id))
    coupon = ensure_owner_reward_coupon(percent_off)
    if (sub.get("metadata") or {}).get("owner_reward_id") == reward_id:
        d = sub.get("discount") or {}
        if (d.get("coupon") or {}).get("id") == coupon:
            return True
    if sub.get("status") != "active" or sub.get("cancel_at_period_end"):
        return False
    if sub.get("discount") or sub.get("discounts"):
        return False
    stripe.Subscription.modify(
        stripe_sub_id, discounts=[{"coupon": coupon}],
        metadata={"owner_reward_id": reward_id},
        idempotency_key=f"owner-reward-{reward_id}",
    )
    return True


def customer_has_subscription_history(email: str) -> bool:
    """True if any Stripe customer with this email ever had a real subscription.

    Used by the promo new-subscriber check. Fails closed: any ambiguity
    (more than one page of customers/subscriptions) returns True, and Stripe
    errors propagate so the caller denies the discount.
    """
    if not email:
        return True
    variants = {email, email.strip().lower()}
    for em in variants:
        customers = _plain(stripe.Customer.list(email=em, limit=20))
        if customers.get("has_more"):
            return True
        for cust in customers.get("data", []):
            subs = _plain(stripe.Subscription.list(customer=cust["id"], status="all", limit=100))
            if subs.get("has_more"):
                return True
            for sub in subs.get("data", []):
                if sub.get("status") not in ("incomplete", "incomplete_expired"):
                    return True
    return False


def create_checkout_session(user_id: str, email: str, member_count: int,
                            promo: dict | None = None) -> str:
    """Create a subscription Checkout Session; return its URL.

    Uses inline ``price_data`` derived from GROUP_PRICE_CENTS, so pricing is
    server-authoritative and no dashboard Products/Prices are needed. A free
    trial is applied only when the TRIAL_MONTHS config is > 0 (production: 0,
    so the buyer is charged immediately); ``trial_period_days`` is omitted
    entirely when there is no trial.

    ``promo`` (already validated server-side by PromoManager; keys ``code_id``,
    ``percent_off``) applies the shared once-off coupon to the first invoice and
    stamps its ids in session/subscription metadata. It is refused (ValueError)
    for group plans and when a trial is configured (no stacking).

    Raises:
        ValueError: if ``member_count`` is outside 1-8, or a promo is combined
            with a group plan or a trial.
    """
    if not (MIN_MEMBERS <= member_count <= MAX_MEMBERS):
        raise ValueError(f"member_count must be between {MIN_MEMBERS} and {MAX_MEMBERS}")
    price_cents = price_for(member_count)
    months = trial_months()
    metadata = {"user_id": user_id, "member_count": str(member_count)}
    extra = {}
    if promo:
        if member_count != 1 or months > 0:
            raise ValueError("promo not applicable")
        metadata["promo_code_id"] = str(promo["code_id"])
        extra["discounts"] = [{"coupon": ensure_promo_coupon(int(promo["percent_off"]))}]
    subscription_data = {"metadata": dict(metadata)}
    if months > 0:
        subscription_data["trial_period_days"] = months * 30
    name = f"FellowScript Group ({member_count} {'person' if member_count == 1 else 'people'})"
    session = stripe.checkout.Session.create(
        mode="subscription",
        client_reference_id=user_id,
        customer_email=email or None,
        line_items=[{
            "quantity": 1,
            "price_data": {
                "currency": "usd",
                "product_data": {"name": name},
                "unit_amount": price_cents,
                "recurring": {"interval": "month"},
            },
        }],
        subscription_data=subscription_data,
        metadata=metadata,
        success_url=SUCCESS_URL,
        cancel_url=CANCEL_URL,
        **extra,
    )
    return session.url


def create_donation_session(amount_cents: int, email: str = "") -> str:
    """Create a one-time (mode=payment) Checkout Session for a donation; return URL.

    Amount is set from the validated ``amount_cents`` the caller passes; the
    Checkout button reads "Donate" via submit_type.
    """
    session = stripe.checkout.Session.create(
        mode="payment",
        submit_type="donate",
        customer_email=email or None,
        line_items=[{
            "quantity": 1,
            "price_data": {
                "currency": "usd",
                "product_data": {
                    "name": "FellowScript Donation",
                    "description": "Thank you for supporting FellowScript \U0001F64F",
                },
                "unit_amount": amount_cents,
            },
        }],
        success_url=DONATE_SUCCESS_URL,
        cancel_url=DONATE_CANCEL_URL,
    )
    return session.url


def construct_event(payload: bytes, sig_header: str):
    """Verify a webhook payload against STRIPE_WEBHOOK_SECRET and return the event.

    Raises ValueError / stripe.error.SignatureVerificationError on tampering.
    """
    secret = os.getenv("STRIPE_SIGNING_SECRET") or os.getenv("STRIPE_WEBHOOK_SECRET") or ""
    if not secret:
        raise ValueError("STRIPE_SIGNING_SECRET is not set")
    return _plain(stripe.Webhook.construct_event(payload, sig_header, secret))


def retrieve_subscription(subscription_id: str):
    """Fetch a Stripe subscription with its default payment method expanded."""
    return _plain(stripe.Subscription.retrieve(
        subscription_id, expand=["default_payment_method"]
    ))


def cancel_subscription(subscription_id: str) -> bool:
    """Cancel a Stripe subscription immediately.

    Returns True if Stripe confirms the subscription is canceled (including
    the "already canceled / not found" case, which is not a failure — there
    is nothing left to bill). Returns False on a real failure (network error,
    Stripe outage, etc.) so the caller can refuse to delete its local record
    of a subscription that may still be live and billing.
    """
    if not subscription_id:
        return True
    try:
        stripe.Subscription.delete(subscription_id)
        return True
    except stripe.error.InvalidRequestError as e:
        # Already canceled / not found — nothing left to bill, safe to treat
        # as a successful cancellation.
        logger.warning("Stripe subscription %s already gone: %s", subscription_id, e)
        return True
    except Exception as e:
        logger.error("Stripe cancel failed for %s: %s", subscription_id, e)
        return False


def _field(obj, key):
    """Read ``key`` from a plain dict or an attribute-style object."""
    if obj is None:
        return None
    if isinstance(obj, dict):
        return obj.get(key)
    return getattr(obj, key, None)


def card_from_subscription(sub) -> dict:
    """Extract non-sensitive card display fields from a subscription's PM."""
    pm = _field(sub, "default_payment_method")
    card = _field(pm, "card") if pm else None
    if not card:
        return {"brand": "", "last4": "", "exp_month": "", "exp_year": ""}
    return {
        "brand":     _field(card, "brand") or "",
        "last4":     _field(card, "last4") or "",
        "exp_month": str(_field(card, "exp_month") or ""),
        "exp_year":  str(_field(card, "exp_year") or ""),
    }
