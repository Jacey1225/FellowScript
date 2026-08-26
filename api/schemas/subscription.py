from pydantic import BaseModel, Field
import uuid
from datetime import datetime

# Server-authoritative price table for the single "group" plan tier. The host
# picks how many people (1-8) the plan covers; price is looked up by that
# count here — never trusted from the client.
GROUP_PRICE_CENTS: dict[int, int] = {
    1: 1000, 2: 1799, 3: 2699, 4: 3599, 5: 4499, 6: 5399, 7: 6299, 8: 7199,
}
MIN_MEMBERS = 1
MAX_MEMBERS = 8


def price_for(member_count: int) -> int:
    return GROUP_PRICE_CENTS.get(member_count, GROUP_PRICE_CENTS[MIN_MEMBERS])

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
#   - notes:        rolling-7-day window (notes the user authors)
#   - agent_events: total heartbeats the user owns
#
# The former `agent_notifications` cap (total user-authored "agentic"
# notifications) was removed along with that subsystem — see
# .claude/pipeline/20260826-activity-based-notifications.
FREE_LIMITS: dict[str, int] = {
    "notes": 10,
    "agent_events": 1,
}
NOTES_WINDOW_DAYS = 7


class Subscription(BaseModel):
    """A subscription plan owned by a host user."""
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    user_id: str = Field(description="UUID of the host who owns/pays for the plan")
    plan_type: str = Field(default="group", description="'free' or 'group'")
    provider: str = Field(default="stripe", description="'stripe' or 'apple'")
    stripe_customer_id: str = Field(default="")
    default_payment_method_id: str = Field(default="", description="opaque processor token (pm_...)")
    card_brand: str = Field(default="", description="display only, e.g. 'visa'")
    card_last4: str = Field(default="", description="display only, last 4 digits")
    card_exp_month: str = Field(default="", description="display only, e.g. '08'")
    card_exp_year: str = Field(default="", description="display only, e.g. '2027'")
    status: str = Field(default="inactive", description="trialing | active | past_due | canceled | inactive")
    price_cents: int = Field(default=1000, description="derived from member_count")
    max_members: int = Field(default=1, description="the host-selected member_count (1-8)")
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
    member_count: int = 1
    provider: str = "stripe"
    stripe_customer_id: str = ""
    default_payment_method_id: str = ""
    card_brand: str = ""
    card_last4: str = ""
    card_exp_month: str = ""
    card_exp_year: str = ""


class SubscriptionUpdate(BaseModel):
    """Partial update; only non-None fields are applied."""
    member_count: int | None = None
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
