"""Validated tunables for chat history paging (``api/config/chat.json``,
section ``pagination``).

Loaded through the shared ``config_loader`` (every key required, unknown keys
and wrong types rejected) and cached after the first successful load. There
are no implicit defaults: a bad or missing file raises, and
``validate_pagination_config()`` runs from ``startup_checks`` so the boot
refuses to continue. Other tasks add their own sections to the same file;
this module only reads ``pagination``.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from limits import parse as _parse_rate

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "chat.json"
SECTION = "pagination"

_RATE_LIMIT_KEYS = ("messages_page",)
# A skew of 0 would reject any client whose clock runs a moment ahead; the
# ceiling keeps a typo from turning the clamp off in practice.
_MAX_SKEW_SECONDS = 86400


@dataclass(frozen=True)
class PaginationConfig:
    initial_page_size: int
    page_size: int
    max_page_size: int
    future_timestamp_skew_seconds: int
    rate_limits: dict[str, str]


_cached: PaginationConfig | None = None


def _positive(name: str, value: int) -> int:
    if value < 1:
        raise ConfigSectionError(f"chat.json[{SECTION}]: {name} must be >= 1")
    return value


def _load() -> PaginationConfig:
    raw = load_section(
        CONFIG_PATH,
        SECTION,
        required_keys=(
            "initial_page_size", "page_size", "max_page_size",
            "future_timestamp_skew_seconds", "rate_limits",
        ),
        types={
            "initial_page_size": int, "page_size": int, "max_page_size": int,
            "future_timestamp_skew_seconds": int, "rate_limits": dict,
        },
    )
    initial = _positive("initial_page_size", raw["initial_page_size"])
    page = _positive("page_size", raw["page_size"])
    maximum = _positive("max_page_size", raw["max_page_size"])
    if initial > maximum or page > maximum:
        raise ConfigSectionError(f"chat.json[{SECTION}]: page sizes must not exceed max_page_size")
    skew = raw["future_timestamp_skew_seconds"]
    if skew < 0 or skew > _MAX_SKEW_SECONDS:
        raise ConfigSectionError(
            f"chat.json[{SECTION}]: future_timestamp_skew_seconds must be between 0 and {_MAX_SKEW_SECONDS}"
        )
    rates = raw["rate_limits"]
    if set(rates) != set(_RATE_LIMIT_KEYS):
        raise ConfigSectionError(f"chat.json[{SECTION}]: rate_limits must contain exactly {list(_RATE_LIMIT_KEYS)}")
    for key, value in rates.items():
        try:
            if not isinstance(value, str):
                raise ValueError("not a string")
            _parse_rate(value)
        except Exception as e:
            raise ConfigSectionError(f"chat.json[{SECTION}]: rate_limits.{key} is not a valid rate limit: {e}") from None
    return PaginationConfig(
        initial_page_size=initial,
        page_size=page,
        max_page_size=maximum,
        future_timestamp_skew_seconds=skew,
        rate_limits=dict(rates),
    )


def get_pagination_config() -> PaginationConfig:
    """Validated config, loaded once. Raises ``ConfigSectionError``; never defaults."""
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def validate_pagination_config() -> None:
    """Startup check: load (uncached) so a file edited since import is re-read."""
    global _cached
    _cached = _load()


def reset_for_tests() -> None:
    global _cached
    _cached = None
