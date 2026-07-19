from pydantic import BaseModel, Field
import uuid
from datetime import datetime

# Server-authoritative plan catalog. Price and member cap are derived from the
# plan_type here — never trusted from the client.
PLAN_CONFIG: dict[str, dict[str, int]] = {
    "individual": {"price_cents": 1000, "max_members": 1},   # $10 / month, one user
    "group":      {"price_cents": 4000, "max_members": 5},   # $40 / month, up to 5 users
}

# Every new subscription starts with a free trial of this length. The first
# billing date is computed as created_at + TRIAL_MONTHS and stored as trial_end.
TRIAL_MONTHS = 1

# Safety-net for lapsed plans. A subscription whose paid period (current_period_end)
# ended more than this many days ago — and which was never renewed via a processor
# notification — is treated as expired: reads stop reporting it as active and a
# scheduler sweep removes it. The grace window absorbs a renewal that is briefly
# mid-webhook (Stripe) or not-yet-resynced (Apple refreshes current_period_end on
# app launch and DID_RENEW), so a healthy subscription is never dropped prematurely.
EXPIRY_GRACE_DAYS = 3

# Usage caps for users WITHOUT an active plan (the free tier). Subscribed users
# (individual or group, trialing or active) bypass these entirely — unlimited.
# Enforced server-side in the create routes via LimitsManager, so the caps hold
# regardless of client (web or iOS).
#   - notes:               rolling-7-day window (notes the user authors)
#   - agent_events:        total heartbeats the user owns
#   - agent_notifications: total scheduled notifications the user owns
FREE_LIMITS: dict[str, int] = {
    "notes": 10,
    "agent_events": 1,
    "agent_notifications": 3,
}
NOTES_WINDOW_DAYS = 7


class Subscription(BaseModel):
    """A subscription plan owned by a host user."""
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    user_id: str = Field(description="UUID of the host who owns/pays for the plan")
    plan_type: str = Field(default="individual", description="'individual' or 'group'")
    provider: str = Field(default="stripe", description="'stripe' or 'apple'")
    stripe_customer_id: str = Field(default="")
    default_payment_method_id: str = Field(default="", description="opaque processor token (pm_...)")
    card_brand: str = Field(default="", description="display only, e.g. 'visa'")
    card_last4: str = Field(default="", description="display only, last 4 digits")
    card_exp_month: str = Field(default="", description="display only, e.g. '08'")
    card_exp_year: str = Field(default="", description="display only, e.g. '2027'")
    status: str = Field(default="inactive", description="trialing | active | past_due | canceled | inactive")
    price_cents: int = Field(default=1000, description="derived from plan_type")
    max_members: int = Field(default=1, description="derived from plan_type")
    trial_end: str = Field(default="", description="when the free trial ends / first billing date")
    current_period_end: str = Field(default="", description="next billing date")
    created_at: str = Field(default_factory=lambda: str(datetime.now()))


class SubscriptionCreate(BaseModel):
    """Payload to start a new plan. Price/cap and trial are set server-side.

    Only NON-SENSITIVE billing fields are accepted — never a full card number
    or CVC. The client derives brand/last4/exp locally (or from the processor)
    and sends only those, plus opaque processor tokens.
    """
    user_id: str
    plan_type: str = "individual"
    provider: str = "stripe"
    stripe_customer_id: str = ""
    default_payment_method_id: str = ""
    card_brand: str = ""
    card_last4: str = ""
    card_exp_month: str = ""
    card_exp_year: str = ""


class SubscriptionUpdate(BaseModel):
    """Partial update; only non-None fields are applied."""
    plan_type: str | None = None
    provider: str | None = None
    default_payment_method_id: str | None = None
    card_brand: str | None = None
    card_last4: str | None = None
    status: str | None = None
    current_period_end: str | None = None


class SubscriptionRequest(BaseModel):
    """A user's request to join a host's group plan."""
    subscription_id: str
    from_user_id: str
