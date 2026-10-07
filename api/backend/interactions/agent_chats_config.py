"""Validated tunables for multi-chat agents (``api/config/chat.json``, section
``agent_chats``). Same rules as ``threads_config``: every key required, no
implicit defaults, validated at startup from ``startup_checks``.
"""
from __future__ import annotations

from dataclasses import dataclass

from backend.config_loader import ConfigSectionError, load_section
from backend.interactions.chat_config import CONFIG_PATH

SECTION = "agent_chats"
_MAX_TITLE_COLUMN = 80  # agent_chats.title is VARCHAR(80)


@dataclass(frozen=True)
class AgentChatsConfig:
    max_chats_per_agent: int
    title_max_length: int
    auto_title_length: int
    create_rate: str


_cached: AgentChatsConfig | None = None


def _bounded(name: str, value: int, low: int, high: int) -> int:
    if value < low or value > high:
        raise ConfigSectionError(f"chat.json[{SECTION}]: {name} must be between {low} and {high}")
    return value


def _load() -> AgentChatsConfig:
    raw = load_section(
        CONFIG_PATH,
        SECTION,
        required_keys=("max_chats_per_agent", "title_max_length", "auto_title_length", "create_rate"),
        types={"max_chats_per_agent": int, "title_max_length": int, "auto_title_length": int, "create_rate": str},
        rate_keys=("create_rate",),
    )
    cap = _bounded("max_chats_per_agent", raw["max_chats_per_agent"], 1, 10000)
    title_max = _bounded("title_max_length", raw["title_max_length"], 1, _MAX_TITLE_COLUMN)
    auto = _bounded("auto_title_length", raw["auto_title_length"], 1, title_max)
    return AgentChatsConfig(cap, title_max, auto, raw["create_rate"])


def get_agent_chats_config() -> AgentChatsConfig:
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def validate_agent_chats_config() -> None:
    global _cached
    _cached = _load()


def reset_for_tests() -> None:
    global _cached
    _cached = None
