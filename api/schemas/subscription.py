from pydantic import BaseModel, Field
import uuid
from datetime import datetime

# Server-authoritative plan catalog. Price and member cap are derived from the
# plan_type here — never trusted from the client.
PLAN_CONFIG: dict[str, dict[str, int]] = {
    "individual": {"price_cents": 1000, "max_members": 1},   # $10 / month, one user
    "group":      {"price_cents": 4000, "max_members": 5},   # $40 / month, up to 5 users
}


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
    status: str = Field(default="inactive", description="active | past_due | canceled | inactive")
    price_cents: int = Field(default=1000, description="derived from plan_type")
    max_members: int = Field(default=1, description="derived from plan_type")
    current_period_end: str = Field(default="")
    created_at: str = Field(default_factory=lambda: str(datetime.now()))


class SubscriptionCreate(BaseModel):
    """Payload to start a new plan. Price/cap are set server-side from plan_type."""
    user_id: str
    plan_type: str = "individual"
    provider: str = "stripe"
    stripe_customer_id: str = ""
    default_payment_method_id: str = ""
    card_brand: str = ""
    card_last4: str = ""


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
