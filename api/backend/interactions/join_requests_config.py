"""Validated tunables for join requests (``api/config/explorer.json``,
section ``join_requests``).

Loaded through the shared ``config_loader`` (every key required, unknown keys
and wrong types rejected, no implicit defaults) and cached after the first
successful load. ``validate_join_requests_config()`` runs from
``startup_checks`` so a bad file refuses to boot. The flags ``join_requests``
and ``join_request_push`` are DB rows (see ``flags``), not config keys.
"""
from __future__ import annotations

from dataclasses import dataclass

from limits import parse as _parse_rate

from backend.config_loader import ConfigSectionError, load_section
from backend.interactions.listings_config import CONFIG_PATH

SECTION = "join_requests"

# One entry per limited operation; every route uses a shared_limit with a FIXED
# scope (path-parameter buckets are a known flaw), keyed per user or per IP.
RATE_LIMIT_KEYS = ("create", "create_ip", "withdraw", "mine", "owner_read", "decide", "accepting")

_INT_KEYS = (
    "max_pending_per_group", "max_pending_per_user", "max_requests_per_user_per_day",
    "cooldown_days", "pending_expiry_days", "retention_days", "note_max_length",
    "min_account_age_hours", "undo_deny_seconds", "notify_window_minutes", "lock_timeout_ms",
)
_REQUIRED = _INT_KEYS + ("rate_limits",)
_TYPES = {k: int for k in _INT_KEYS}
_TYPES["rate_limits"] = dict

# (low, high) bounds per key; 0 is legal only where the low bound says so.
_BOUNDS = {
    "max_pending_per_group": (1, 1000),
    "max_pending_per_user": (1, 100),
    "max_requests_per_user_per_day": (1, 1000),
    "cooldown_days": (0, 365),
    "pending_expiry_days": (1, 365),
    "retention_days": (1, 3650),
    "note_max_length": (1, 1000),
    "min_account_age_hours": (0, 8760),
    "undo_deny_seconds": (1, 3600),
    "notify_window_minutes": (1, 1440),
    # Bounded lock wait: a route holds one of the 40 shared threadpool tokens
    # for at most this long. 0 would mean "wait forever" in Postgres.
    "lock_timeout_ms": (100, 10000),
}


@dataclass(frozen=True)
class JoinRequestsConfig:
    max_pending_per_group: int
    max_pending_per_user: int
    max_requests_per_user_per_day: int
    cooldown_days: int
    pending_expiry_days: int
    retention_days: int
    note_max_length: int
    min_account_age_hours: int
    undo_deny_seconds: int
    notify_window_minutes: int
    lock_timeout_ms: int
    rate_limits: dict


_cached: JoinRequestsConfig | None = None


def _err(msg: str) -> ConfigSectionError:
    return ConfigSectionError(f"explorer.json[{SECTION}]: {msg}")


def _load() -> JoinRequestsConfig:
    raw = load_section(CONFIG_PATH, SECTION, required_keys=_REQUIRED, types=_TYPES)
    for key, (low, high) in _BOUNDS.items():
        if not low <= raw[key] <= high:
            raise _err(f"{key} must be between {low} and {high}")
    if raw["retention_days"] < raw["cooldown_days"]:
        raise _err("retention_days must not be shorter than cooldown_days")
    rates = raw["rate_limits"]
    if set(rates) != set(RATE_LIMIT_KEYS):
        raise _err(f"rate_limits must contain exactly {list(RATE_LIMIT_KEYS)}")
    for key, value in rates.items():
        try:
            if not isinstance(value, str):
                raise ValueError("not a string")
            _parse_rate(value)
        except Exception as e:
            raise _err(f"rate_limits.{key} is not a valid rate limit: {e}") from None
    return JoinRequestsConfig(rate_limits=dict(rates), **{k: raw[k] for k in _INT_KEYS})


def get_join_requests_config() -> JoinRequestsConfig:
    """Validated config, loaded once. Raises ``ConfigSectionError``; never defaults."""
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def validate_join_requests_config() -> None:
    """Startup check: load uncached so a file edited since import is re-read."""
    global _cached
    _cached = _load()


def reset_for_tests() -> None:
    global _cached
    _cached = None
