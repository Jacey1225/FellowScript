from pydantic import BaseModel, Field
import json
import uuid
from pathlib import Path
from datetime import datetime

# Server-authoritative price table for the single "group" plan tier. The host
# picks how many people (1-8) the plan covers; price is looked up by that
# count here — never trusted from the client.
#
# Price cut 2026-10-01 (task 20261001-subscription-price-cut). Rule:
#   1 member  = 499 (pinned: 50% of the old 999/1000 tier).
#   2-8       = old tier price x 0.45 (50% off, then a further 10% off), rounded
#               half-up to the nearest 5 cents.
# Old table (kept only in api/scripts/stripe_price_migration.py as OLD_PRICE_CENTS):
#   1000, 1799, 2699, 3599, 4499, 5399, 6299, 7199.
# Mirrored (not fetched) by frontend/src/components/SubscriptionCard.jsx and the
# iOS fallback in Account/AccountView+Subscription.swift; a drift test compares them.
GROUP_PRICE_CENTS: dict[int, int] = {
    1: 499, 2: 810, 3: 1215, 4: 1620, 5: 2025, 6: 2430, 7: 2835, 8: 3240,
}
MIN_MEMBERS = 1
MAX_MEMBERS = 8


def price_for(member_count: int) -> int:
    return GROUP_PRICE_CENTS.get(member_count, GROUP_PRICE_CENTS[MIN_MEMBERS])

# Trial length for plans created through the internal create_subscription path
# (SubscriptionsManager.create_subscription). NOT the web checkout trial: Stripe
# Checkout reads the TRIAL_MONTHS env setting via stripe_service.trial_months()
# (0 = no trial). The first billing date here is computed as
# created_at + TRIAL_MONTHS and stored as trial_end.
TRIAL_MONTHS = 1

# Safety-net for lapsed plans. A subscription whose paid period (current_period_end)
# ended more than this many days ago — and which was never renewed via a processor
# notification — is treated as expired: reads stop reporting it as active and a
# scheduler sweep removes it. The grace window absorbs a renewal that is briefly
# mid-webhook (Stripe) or not-yet-resynced (Apple refreshes current_period_end on
# app launch and DID_RENEW), so a healthy subscription is never dropped prematurely.
EXPIRY_GRACE_DAYS = 3

# Distinct provider value for the admin free-individual-membership comp grant
# (see backend/subscription/subscriptions.py::grant_admin_comp and
# routes/subscription.py's admin grant endpoint). No Stripe/Apple write path
# ('stripe' / 'apple') ever produces this value, so a comp row can never
# collide with or be mistaken for real billing state; paired with
# plan_type='individual' it is unambiguous in the DB/audit log as
# admin-comped rather than paid.
ADMIN_COMP_PROVIDER = "admin_comp"

# Usage caps for users WITHOUT an active plan (the free tier). Subscribed users
# (individual or group, trialing or active) bypass these entirely — unlimited.
# Enforced server-side in the create routes via LimitsManager, so the caps hold
# regardless of client (web or iOS).
#   - notes:        rolling-7-day window (notes the user authors)
#   - agent_events: total heartbeats the user owns
#   - announcements: group announcements the user authored in the rolling
#                    ANNOUNCEMENTS_WINDOW_DAYS window, across all groups,
#                    counted from created_at (task 20260929-group-announcements)
#   - sessions:     free users may CREATE at most ``sessions.max_active``
#                   not-yet-ended sessions at a time (no lifetime cap);
#                   joining is never limited (task 20261002-free-plan-limits-ui)
#   - PAID_ONLY_RESOURCES: gates with no free allowance (session summaries,
#                   Explorer publish/submit)
#
# Tunables live in api/config/free_limits.json (every key required, validated
# eagerly at import so a bad file refuses to boot).
#
# The former `agent_notifications` cap (total user-authored "agentic"
# notifications) was removed along with that subsystem — see
# .claude/pipeline/20260826-activity-based-notifications.
_FREE_LIMITS_PATH = Path(__file__).resolve().parents[1] / "config" / "free_limits.json"


def _load_free_limits_config() -> dict:
    try:
        raw = json.loads(_FREE_LIMITS_PATH.read_text())["free_limits"]
    except (OSError, ValueError, KeyError) as e:
        raise RuntimeError(f"free_limits.json missing or invalid: {e}") from None
    expected = {"counts", "sessions", "paid_only", "notes_window_days", "announcements_window_days"}
    if set(raw) != expected:
        raise RuntimeError(f"free_limits.json keys must be exactly {sorted(expected)}")

    def _pos_int(v, name):
        if isinstance(v, bool) or not isinstance(v, int) or v < 1:
            raise RuntimeError(f"free_limits.json: {name} must be a positive integer")
        return v

    counts = raw["counts"]
    if set(counts) != {"notes", "agent_events", "announcements"}:
        raise RuntimeError("free_limits.json: counts keys must be notes, agent_events, announcements")
    for k, v in counts.items():
        _pos_int(v, f"counts.{k}")
    if set(raw["sessions"]) != {"max_active"}:
        raise RuntimeError("free_limits.json: sessions keys must be exactly max_active")
    _pos_int(raw["sessions"]["max_active"], "sessions.max_active")
    if set(raw["paid_only"]) != {"session_summaries", "explorer_publish"} or not all(
        isinstance(v, bool) for v in raw["paid_only"].values()
    ):
        raise RuntimeError("free_limits.json: paid_only must be booleans for session_summaries, explorer_publish")
    _pos_int(raw["notes_window_days"], "notes_window_days")
    _pos_int(raw["announcements_window_days"], "announcements_window_days")
    return raw


_FREE_CFG = _load_free_limits_config()
FREE_LIMITS: dict[str, int] = {
    **_FREE_CFG["counts"],
    "sessions": _FREE_CFG["sessions"]["max_active"],
}
# Resources with no free allowance. True = blocked for free users (fail closed).
PAID_ONLY_RESOURCES: dict[str, bool] = dict(_FREE_CFG["paid_only"])
NOTES_WINDOW_DAYS = _FREE_CFG["notes_window_days"]
ANNOUNCEMENTS_WINDOW_DAYS = _FREE_CFG["announcements_window_days"]

# Per-note text length cap for the FREE tier (task 20260929-free-note-char-cap).
# Without it, the FREE_LIMITS["notes"] count cap can be dodged by editing one
# note forever. ~5000 words x ~6 chars/word (incl. spaces) = 30,000 characters.
# Counted as Python len(text) (Unicode code points; newlines as received);
# titles are not counted. Clients read this value from the usage summary
# (GET /subscriptions/user/{id}/usage -> "note_chars") instead of hardcoding it.
FREE_NOTE_CHAR_LIMIT = 30000
# Paid plans get a wider per-note limit (a real plan limit, enforced with the
# same create/reply/update + grandfather rules as the free limit).
PAID_NOTE_CHAR_LIMIT = 100000
# Hard cap on the request body of /notes routes (bytes), checked from
# Content-Length before the body is parsed. Sized for PAID_NOTE_CHAR_LIMIT
# worst case (JSON \uXXXX escaping of non-BMP characters).
NOTES_MAX_BODY_BYTES = 4 * 1024 * 1024

# Eager validation (Configuration Philosophy): a bad tunable fails at import.
assert isinstance(FREE_NOTE_CHAR_LIMIT, int) and FREE_NOTE_CHAR_LIMIT > 0
assert isinstance(PAID_NOTE_CHAR_LIMIT, int) and PAID_NOTE_CHAR_LIMIT >= FREE_NOTE_CHAR_LIMIT


class Subscription(BaseModel):
    """A subscription plan owned by a host user."""
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    user_id: str = Field(description="UUID of the host who owns/pays for the plan")
    plan_type: str = Field(default="group", description="'free', 'group', or 'individual' (admin comp)")
    provider: str = Field(default="stripe", description="'stripe', 'apple', or 'admin_comp'")
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
