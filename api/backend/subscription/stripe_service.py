"""Stripe billing integration (web).

Thin wrapper around the Stripe SDK: creates hosted Checkout Sessions for the
free-trial subscription flow, verifies incoming webhooks, and cancels
subscriptions. All plan pricing is derived from GROUP_PRICE_CENTS (inline
price_data) so no pre-created Stripe Products/Prices are required.

Secrets come from the environment (same pattern as DB_PASSWORD / APNs):
    STRIPE_SECRET_KEY      — sk_test_… / sk_live_…
    STRIPE_SIGNING_SECRET  — whsec_…  (set after registering the webhook endpoint;
                             STRIPE_WEBHOOK_SECRET is also accepted as an alias)
"""

import os
import logging
import stripe
from schemas.subscription import price_for, MIN_MEMBERS, MAX_MEMBERS, TRIAL_MONTHS

logger = logging.getLogger(__name__)

stripe.api_key = os.getenv("STRIPE_SECRET_KEY", "")

# Where Stripe returns the browser after checkout. The query lives before the
# HashRouter fragment so window.location.search sees it on the account page.
_SITE = os.getenv("SITE_URL", "https://fellowscript.com")
SUCCESS_URL = f"{_SITE}/?sub=success#/account"
CANCEL_URL  = f"{_SITE}/?sub=cancel#/account"
DONATE_SUCCESS_URL = f"{_SITE}/?donate=success#/account"
DONATE_CANCEL_URL  = f"{_SITE}/?donate=cancel#/account"

def is_configured() -> bool:
    return bool(stripe.api_key)


def create_checkout_session(user_id: str, email: str, member_count: int) -> str:
    """Create a subscription Checkout Session with a free trial; return its URL.

    Uses inline ``price_data`` derived from GROUP_PRICE_CENTS, so pricing is
    server-authoritative and no dashboard Products/Prices are needed. The trial
    length matches the app's TRIAL_MONTHS; the user is not charged until it ends.

    Raises:
        ValueError: if ``member_count`` is outside 1-8.
    """
    if not (MIN_MEMBERS <= member_count <= MAX_MEMBERS):
        raise ValueError(f"member_count must be between {MIN_MEMBERS} and {MAX_MEMBERS}")
    price_cents = price_for(member_count)
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
        subscription_data={
            "trial_period_days": TRIAL_MONTHS * 30,
            "metadata": {"user_id": user_id, "member_count": str(member_count)},
        },
        metadata={"user_id": user_id, "member_count": str(member_count)},
        success_url=SUCCESS_URL,
        cancel_url=CANCEL_URL,
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
    return stripe.Webhook.construct_event(payload, sig_header, secret)


def retrieve_subscription(subscription_id: str):
    """Fetch a Stripe subscription with its default payment method expanded."""
    return stripe.Subscription.retrieve(
        subscription_id, expand=["default_payment_method"]
    )


def cancel_subscription(subscription_id: str) -> None:
    """Cancel a Stripe subscription immediately (best-effort)."""
    if not subscription_id:
        return
    try:
        stripe.Subscription.delete(subscription_id)
    except Exception as e:  # already canceled / not found — safe to ignore
        logger.warning("Stripe cancel failed for %s: %s", subscription_id, e)


def card_from_subscription(sub) -> dict:
    """Extract non-sensitive card display fields from a subscription's PM."""
    pm = getattr(sub, "default_payment_method", None)
    card = getattr(pm, "card", None) if pm else None
    if not card:
        return {"brand": "", "last4": "", "exp_month": "", "exp_year": ""}
    return {
        "brand":     getattr(card, "brand", "") or "",
        "last4":     getattr(card, "last4", "") or "",
        "exp_month": str(getattr(card, "exp_month", "") or ""),
        "exp_year":  str(getattr(card, "exp_year", "") or ""),
    }
