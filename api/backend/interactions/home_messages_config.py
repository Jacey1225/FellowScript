"""Validated tunables for home announcement messages
(``api/config/home_messages.json``, section ``home_messages``).

Loaded through the shared ``config_loader`` (every key required, unknown keys
and wrong types rejected, no implicit defaults), cached after first load.
``validate_home_messages_config()`` runs from ``startup_checks``.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from limits import parse as _parse_rate

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "home_messages.json"
SECTION = "home_messages"
RATE_KEYS = ("read", "admin")
_COLUMN_MAX = 500  # home_messages.text is VARCHAR(500)


@dataclass(frozen=True)
class HomeMessagesConfig:
    text_max_length: int
    max_enabled: int
    cache_ttl_seconds: int
    admin_list_limit: int
    rate_limits: dict


_cfg: HomeMessagesConfig | None = None


def _bounded(name: str, value: int, low: int, high: int) -> int:
    if value < low or value > high:
        raise ConfigSectionError(f"home_messages.json[{SECTION}]: {name} must be between {low} and {high}")
    return value


def _load() -> HomeMessagesConfig:
    raw = load_section(
        CONFIG_PATH,
        SECTION,
        required_keys=("text_max_length", "max_enabled", "cache_ttl_seconds", "admin_list_limit", "rate_limits"),
        types={
            "text_max_length": int, "max_enabled": int, "cache_ttl_seconds": int,
            "admin_list_limit": int, "rate_limits": dict,
        },
    )
    rates = raw["rate_limits"]
    if sorted(rates) != sorted(RATE_KEYS):
        raise ConfigSectionError(f"home_messages.json[{SECTION}]: rate_limits must contain exactly {list(RATE_KEYS)}")
    for key, value in rates.items():
        try:
            if not isinstance(value, str):
                raise ValueError("not a string")
            _parse_rate(value)
        except Exception:
            raise ConfigSectionError(f"home_messages.json[{SECTION}]: rate_limits.{key} is not a valid rate limit") from None
    return HomeMessagesConfig(
        text_max_length=_bounded("text_max_length", raw["text_max_length"], 1, _COLUMN_MAX),
        max_enabled=_bounded("max_enabled", raw["max_enabled"], 1, 50),
        cache_ttl_seconds=_bounded("cache_ttl_seconds", raw["cache_ttl_seconds"], 0, 3600),
        admin_list_limit=_bounded("admin_list_limit", raw["admin_list_limit"], 1, 1000),
        rate_limits=dict(rates),
    )


def get_home_messages_config() -> HomeMessagesConfig:
    global _cfg
    if _cfg is None:
        _cfg = _load()
    return _cfg


def validate_home_messages_config() -> None:
    """Startup check: reload uncached so a file edited since import is re-read."""
    global _cfg
    _cfg = _load()


def reset_for_tests() -> None:
    global _cfg
    _cfg = None
