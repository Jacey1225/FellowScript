"""Structured, eagerly-validated config for invite links (task
20260929-group-invite-links).

Application-behavior tunables live in ``api/config/invites.json`` (a
structured file, not env vars) per the project's configuration philosophy:
no implicit defaults -- every key is required, unknown keys and wrong types
are rejected, and ``validate_invites_config()`` runs at startup (main.py
lifespan) so a bad file refuses to boot. ``get_invites_config()`` lazily loads
+ validates on first use as well (never falls back to defaults), so harnesses
that don't run the lifespan still get a validated config or a loud error.

The feature flag (``enabled``) ships ``false``: the backend can deploy ahead
of the client builds, and flipping it is a deliberate, separate step.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from limits import parse as _parse_rate

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "invites.json"

_RATE_KEYS = ("preview", "redeem", "redeem_per_user", "create", "list", "revoke")
_TOP_KEYS = (
    "enabled", "public_base_url", "default_expiry_days", "allowed_expiry_days",
    "default_max_uses", "allowed_max_uses", "max_active_links_per_user_per_group",
    "rate_limits",
    # Phase 2 (subscription-seat invites): per-kind tunables. Seat caps make
    # subscription links deliberately tighter than group links.
    "subscription_default_expiry_days", "subscription_allowed_expiry_days",
    "subscription_default_max_uses", "subscription_allowed_max_uses",
    "max_active_links_per_subscription", "max_pending_requests_per_subscription",
)


class InvitesConfigError(RuntimeError):
    """Raised when config/invites.json is missing, malformed, or invalid."""


@dataclass(frozen=True)
class InvitesConfig:
    enabled: bool
    public_base_url: str
    default_expiry_days: int
    allowed_expiry_days: tuple[int, ...]
    default_max_uses: int
    allowed_max_uses: tuple[int, ...]
    max_active_links_per_user_per_group: int
    rate_limits: dict[str, str]
    subscription_default_expiry_days: int
    subscription_allowed_expiry_days: tuple[int, ...]
    subscription_default_max_uses: int
    subscription_allowed_max_uses: tuple[int, ...]
    max_active_links_per_subscription: int
    max_pending_requests_per_subscription: int


def _pos_int(name: str, v) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or v <= 0:
        raise InvitesConfigError(f"invites config: {name} must be a positive integer, got {v!r}")
    return v


def _pos_int_list(name: str, v) -> tuple[int, ...]:
    if not isinstance(v, list) or not v:
        raise InvitesConfigError(f"invites config: {name} must be a non-empty list of positive integers")
    out = tuple(_pos_int(f"{name}[]", x) for x in v)
    if len(set(out)) != len(out):
        raise InvitesConfigError(f"invites config: {name} contains duplicates")
    return out


def parse_invites_config(raw: object) -> InvitesConfig:
    """Validate a decoded JSON object into an ``InvitesConfig``.

    Raises:
        InvitesConfigError: on any missing/unknown key or invalid value.
    """
    if not isinstance(raw, dict):
        raise InvitesConfigError("invites config: top level must be a JSON object")
    missing = [k for k in _TOP_KEYS if k not in raw]
    if missing:
        raise InvitesConfigError(f"invites config: missing keys {missing}; there are no implicit defaults")
    unknown = [k for k in raw if k not in _TOP_KEYS]
    if unknown:
        raise InvitesConfigError(f"invites config: unknown keys {unknown}")

    if not isinstance(raw["enabled"], bool):
        raise InvitesConfigError("invites config: enabled must be a JSON boolean")

    base = raw["public_base_url"]
    parsed = urlparse(base) if isinstance(base, str) else None
    if (
        parsed is None or parsed.scheme != "https" or not parsed.netloc
        or parsed.path not in ("", "/") or parsed.query or parsed.fragment
        or base.endswith("/")
    ):
        raise InvitesConfigError(
            "invites config: public_base_url must be an https origin with no path "
            "or trailing slash, e.g. https://fellowscript.com"
        )

    allowed_days = _pos_int_list("allowed_expiry_days", raw["allowed_expiry_days"])
    allowed_uses = _pos_int_list("allowed_max_uses", raw["allowed_max_uses"])
    default_days = _pos_int("default_expiry_days", raw["default_expiry_days"])
    default_uses = _pos_int("default_max_uses", raw["default_max_uses"])
    if default_days not in allowed_days:
        raise InvitesConfigError("invites config: default_expiry_days must be one of allowed_expiry_days")
    if default_uses not in allowed_uses:
        raise InvitesConfigError("invites config: default_max_uses must be one of allowed_max_uses")

    sub_days = _pos_int_list("subscription_allowed_expiry_days", raw["subscription_allowed_expiry_days"])
    sub_uses = _pos_int_list("subscription_allowed_max_uses", raw["subscription_allowed_max_uses"])
    sub_default_days = _pos_int("subscription_default_expiry_days", raw["subscription_default_expiry_days"])
    sub_default_uses = _pos_int("subscription_default_max_uses", raw["subscription_default_max_uses"])
    if sub_default_days not in sub_days:
        raise InvitesConfigError(
            "invites config: subscription_default_expiry_days must be one of subscription_allowed_expiry_days")
    if sub_default_uses not in sub_uses:
        raise InvitesConfigError(
            "invites config: subscription_default_max_uses must be one of subscription_allowed_max_uses")

    rl = raw["rate_limits"]
    if not isinstance(rl, dict) or set(rl) != set(_RATE_KEYS):
        raise InvitesConfigError(f"invites config: rate_limits must have exactly the keys {list(_RATE_KEYS)}")
    for k, v in rl.items():
        try:
            if not isinstance(v, str):
                raise ValueError("not a string")
            _parse_rate(v)
        except Exception as e:  # limits raises ValueError on a bad string
            raise InvitesConfigError(f"invites config: rate_limits.{k} ({v!r}) is not a valid limit: {e}")

    return InvitesConfig(
        enabled=raw["enabled"],
        public_base_url=base,
        default_expiry_days=default_days,
        allowed_expiry_days=allowed_days,
        default_max_uses=default_uses,
        allowed_max_uses=allowed_uses,
        max_active_links_per_user_per_group=_pos_int(
            "max_active_links_per_user_per_group", raw["max_active_links_per_user_per_group"]),
        rate_limits=dict(rl),
        subscription_default_expiry_days=sub_default_days,
        subscription_allowed_expiry_days=sub_days,
        subscription_default_max_uses=sub_default_uses,
        subscription_allowed_max_uses=sub_uses,
        max_active_links_per_subscription=_pos_int(
            "max_active_links_per_subscription", raw["max_active_links_per_subscription"]),
        max_pending_requests_per_subscription=_pos_int(
            "max_pending_requests_per_subscription", raw["max_pending_requests_per_subscription"]),
    )


_config: InvitesConfig | None = None


def load_invites_config(path: Path = CONFIG_PATH) -> InvitesConfig:
    try:
        raw = json.loads(Path(path).read_text())
    except FileNotFoundError:
        raise InvitesConfigError(f"invites config not found at {path}")
    except json.JSONDecodeError as e:
        raise InvitesConfigError(f"invites config is not valid JSON: {e}")
    return parse_invites_config(raw)


def validate_invites_config() -> None:
    """Load + validate config/invites.json. Call once at startup (main.py
    lifespan); deliberately not caught so an invalid file stops the boot."""
    global _config
    _config = load_invites_config()


def get_invites_config() -> InvitesConfig:
    global _config
    if _config is None:
        _config = load_invites_config()
    return _config


def set_invites_config_for_tests(cfg: InvitesConfig | None) -> None:
    """Test hook: install (or clear, with None) an in-memory config."""
    global _config
    _config = cfg
