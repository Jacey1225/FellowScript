"""Validated tunables for the session-summary personal fan-out
(``api/config/chat.json``, section ``session_summary_fanout``).

Same rules as ``agent_chats_config``: every key required, no implicit
defaults, validated at startup. ``is_fanout_enabled()`` is the runtime gate and
fails closed: any config error means the feature is off.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

from backend.config_loader import ConfigSectionError, load_section
from backend.interactions.chat_config import CONFIG_PATH

SECTION = "session_summary_fanout"
_MAX_RECIPIENTS_CEILING = 50

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SessionSummaryFanoutConfig:
    enabled: bool
    max_recipients_per_session: int


_cached: SessionSummaryFanoutConfig | None = None


def _load() -> SessionSummaryFanoutConfig:
    raw = load_section(
        CONFIG_PATH,
        SECTION,
        required_keys=("enabled", "max_recipients_per_session"),
        types={"enabled": bool, "max_recipients_per_session": int},
    )
    cap = raw["max_recipients_per_session"]
    if cap < 1 or cap > _MAX_RECIPIENTS_CEILING:
        raise ConfigSectionError(
            f"chat.json[{SECTION}]: max_recipients_per_session must be between 1 and {_MAX_RECIPIENTS_CEILING}"
        )
    return SessionSummaryFanoutConfig(enabled=raw["enabled"], max_recipients_per_session=cap)


def get_session_summary_fanout_config() -> SessionSummaryFanoutConfig:
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def is_fanout_enabled() -> bool:
    """Fail closed: a missing/invalid section reads as disabled."""
    try:
        return get_session_summary_fanout_config().enabled
    except ConfigSectionError:
        logger.error("session_summary_fanout config invalid; fan-out treated as disabled")
        return False


def validate_session_summary_fanout_config() -> None:
    global _cached
    _cached = _load()


def reset_for_tests() -> None:
    global _cached
    _cached = None
