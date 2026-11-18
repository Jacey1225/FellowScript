from pydantic import BaseModel, Field
import json
import uuid
from pathlib import Path
from datetime import datetime

# Server-authoritative seat pricing for the single "group" plan tier. The host
# picks how many people the plan covers (any count >= 1); price is computed
# here from api/config/seat_pricing.json -- never trusted from the client and
# never hardcoded in code (Configuration Philosophy). Web-only payments (task
# 20261117-web-only-payments) removed the old 8-member cap and the old tier
# table (1=499 ... 8=3240; historical copy lives only in
# api/scripts/stripe_price_migration.py). Formula, decided by Jacey 2026-11-18:
#   n <  discount_start_seats : n * base_per_seat_cents
#   n >= discount_start_seats : round_half_up(n * base * (100 - discount) / 100)
# Defaults: base 500, discount 10%, start 2 => 1 seat $5.00, 2 seats $9.00,
# 10 seats $45.00. ``max_members`` (default 100) is only an abuse guard: counts
# outside [min_members, max_members] raise ValueError (fail closed, no fallback
# price). Mirrored (not fetched) by the web and iOS fallbacks; drift tests
# compare them to price_for.
_SEAT_PRICING_PATH = Path(__file__).resolve().parents[1] / "config" / "seat_pricing.json"
_SEAT_PRICING_KEYS = {"min_members", "max_members", "base_per_seat_cents",
                      "group_discount_percent", "discount_start_seats"}


def _load_seat_pricing() -> dict:
    try:
        raw = json.loads(_SEAT_PRICING_PATH.read_text())["seat_pricing"]
        if set(raw) != _SEAT_PRICING_KEYS:
            raise ValueError("unexpected keys")
        if any(isinstance(v, bool) or not isinstance(v, int) for v in raw.values()):
            raise ValueError("all values must be integers")
        if raw["min_members"] < 1 or raw["max_members"] < raw["min_members"]:
            raise ValueError("invalid member bounds")
        if raw["base_per_seat_cents"] < 1:
            raise ValueError("base_per_seat_cents must be positive")
        if not (0 <= raw["group_discount_percent"] < 100):
            raise ValueError("group_discount_percent must be in [0, 100)")
        if raw["discount_start_seats"] < 1:
            raise ValueError("discount_start_seats must be >= 1")
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        raise RuntimeError(f"seat_pricing.json missing or invalid: {e}") from None
    return raw


def _load_legacy_seat_pricing() -> dict:
    try:
        raw = json.loads(_SEAT_PRICING_PATH.read_text())["legacy_seat_pricing"]
        raw = {k: v for k, v in raw.items() if k != "_note"}
        if set(raw) != {"max_members", "tier_table_cents", "extra_seat_cents"}:
            raise ValueError("unexpected keys")
        table = {int(k): v for k, v in raw["tier_table_cents"].items()}
        hi, extra = raw["max_members"], raw["extra_seat_cents"]
        if any(isinstance(v, bool) or not isinstance(v, int) for v in (*table.values(), hi, extra)):
            raise ValueError("all values must be integers")
        if sorted(table) != list(range(1, len(table) + 1)) or hi < len(table) or extra < 1 \
                or any(v < 1 for v in table.values()):
            raise ValueError("invalid legacy table")
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        raise RuntimeError(f"seat_pricing.json legacy block missing or invalid: {e}") from None
    return {"max_members": hi, "table": table, "extra": extra}


SEAT_PRICING = _load_seat_pricing()
LEGACY_SEAT_PRICING = _load_legacy_seat_pricing()
MIN_MEMBERS = SEAT_PRICING["min_members"]
MAX_MEMBERS = SEAT_PRICING["max_members"]


def price_for(member_count: int) -> int:
    """Monthly price in cents for ``member_count`` seats.

    Raises:
        ValueError: not an int (bool rejected) or outside [MIN_MEMBERS, MAX_MEMBERS].
    """
    if isinstance(member_count, bool) or not isinstance(member_count, int) \
            or not (MIN_MEMBERS <= member_count <= MAX_MEMBERS):
        raise ValueError(f"member_count must be a whole number between {MIN_MEMBERS} and {MAX_MEMBERS}")
    cfg = SEAT_PRICING
    gross = member_count * cfg["base_per_seat_cents"]
    if member_count < cfg["discount_start_seats"]:
        return gross
    return (gross * (100 - cfg["group_discount_percent"]) + 50) // 100


def legacy_price_for(member_count: int) -> int:
    """FROZEN pre-2026-11-18 schedule (tier table for 1-8, then +extra per seat).

    Only for repricing subscriptions that already existed; new checkouts always
    use ``price_for``. Raises ValueError outside [1, legacy max_members].
    """
    cfg = LEGACY_SEAT_PRICING
    if isinstance(member_count, bool) or not isinstance(member_count, int) \
            or not (1 <= member_count <= cfg["max_members"]):
        raise ValueError(f"member_count must be a whole number between 1 and {cfg['max_members']}")
    table = cfg["table"]
    top = max(table)
    if member_count <= top:
        return table[member_count]
    return table[top] + (member_count - top) * cfg["extra"]


def is_legacy_plan(max_members, price_cents) -> bool:
    """True if a stored plan row is on the legacy schedule.

    Marker (no data migration needed): every row written by the new code stores
    ``price_for(max_members)`` in ``price_cents``. A paid row whose stored price
    does NOT equal the new formula for its stored seat count predates the new
    pricing, so it is legacy. The two schedules never coincide for any count in
    1-100 (asserted in tests), so the check is unambiguous.
    """
    try:
        return int(price_cents) != price_for(int(max_members))
    except (TypeError, ValueError):
        return True  # unreadable/out-of-range stored data: never move to the new formula


def seat_change_price(max_members, price_cents, new_count: int) -> int:
    """Monthly price in cents after a seat change on an existing plan.

    Legacy plans stay on the legacy schedule; new-schedule plans use ``price_for``.
    Raises ValueError for an invalid ``new_count`` (fail closed).
    """
    if is_legacy_plan(max_members, price_cents):
        return legacy_price_for(new_count)
    return price_for(new_count)


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
        if k == "agent_events":
            # 0 = scheduled devotions are paid-only (task
            # 20261117-scheduled-devotions-paid-only). Never negative.
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                raise RuntimeError("free_limits.json: counts.agent_events must be a non-negative integer")
            continue
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
# Scheduled devotions (agent_events) are paid-only when the free allowance is 0.
# Derived from the one config value so it cannot drift; surfaced in the usage
# payload's "paid_only" map so clients show a locked state, not "0 of 0".
PAID_ONLY_RESOURCES["scheduled_devotions"] = FREE_LIMITS["agent_events"] == 0
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
    max_members: int = Field(default=1, description="the host-selected member_count (seat count)")
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
