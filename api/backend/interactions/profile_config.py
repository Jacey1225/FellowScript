"""Validated tunables for user profiles (``api/config/profile.json``, section
``profile``; task 20261030-user-profiles).

Loaded through the shared ``config_loader`` (every key required, unknown keys
and wrong types rejected, rate strings must parse). No implicit defaults: a
bad or missing file raises, and ``validate_profile_config()`` runs from
``startup_checks`` so the boot refuses to continue.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from limits import parse as _parse_rate

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "profile.json"
SECTION = "profile"

# Parser bound for the bio request body (security D8), not a tunable: the real
# limit is ``bio_max_length`` from config. Config may never exceed this.
BIO_REQUEST_CEILING = 1000

RATE_KEYS = (
    "profile_read_user", "profile_read_ip",
    "bio_edit_hour", "bio_edit_burst",
    "friend_request_hour", "friend_request_day",
    "friend_accept_hour", "friend_decline_hour",
)


@dataclass(frozen=True)
class ProfileConfig:
    bio_max_length: int
    distinct_profile_cap: int
    distinct_profile_window_seconds: int
    max_outstanding_friend_requests: int
    rate_limits: dict[str, str]


_cached: ProfileConfig | None = None


def _load() -> ProfileConfig:
    raw = load_section(
        CONFIG_PATH,
        SECTION,
        required_keys=(
            "bio_max_length", "distinct_profile_cap", "distinct_profile_window_seconds",
            "max_outstanding_friend_requests", "rate_limits",
        ),
        types={
            "bio_max_length": int, "distinct_profile_cap": int,
            "distinct_profile_window_seconds": int,
            "max_outstanding_friend_requests": int, "rate_limits": dict,
        },
    )
    for name in ("bio_max_length", "distinct_profile_cap", "distinct_profile_window_seconds",
                 "max_outstanding_friend_requests"):
        if raw[name] < 1:
            raise ConfigSectionError(f"profile.json[{SECTION}]: {name} must be >= 1")
    if raw["bio_max_length"] > BIO_REQUEST_CEILING // 2:
        raise ConfigSectionError(
            f"profile.json[{SECTION}]: bio_max_length must be <= {BIO_REQUEST_CEILING // 2}")
    rl = raw["rate_limits"]
    if set(rl) != set(RATE_KEYS):
        raise ConfigSectionError(f"profile.json[{SECTION}]: rate_limits must have exactly the keys {list(RATE_KEYS)}")
    for k, v in rl.items():
        try:
            if not isinstance(v, str):
                raise ValueError("not a string")
            _parse_rate(v)
        except Exception as e:  # limits raises ValueError on a bad string
            raise ConfigSectionError(f"profile.json[{SECTION}]: rate_limits.{k} ({v!r}) is not valid: {e}") from None
    return ProfileConfig(
        bio_max_length=raw["bio_max_length"],
        distinct_profile_cap=raw["distinct_profile_cap"],
        distinct_profile_window_seconds=raw["distinct_profile_window_seconds"],
        max_outstanding_friend_requests=raw["max_outstanding_friend_requests"],
        rate_limits=dict(rl),
    )


def validate_profile_config() -> None:
    """Load + validate; call once at startup. Deliberately not caught."""
    global _cached
    _cached = _load()


def get_profile_config() -> ProfileConfig:
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def set_profile_config_for_tests(cfg: ProfileConfig | None) -> None:
    """Test hook: install (or clear, with None) an in-memory config."""
    global _cached
    _cached = cfg
