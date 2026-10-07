"""Validated tunables for agent chat memory (``api/config/chat.json``, section
``agent_chat_memory``). Every key required, no implicit defaults, validated at
startup from ``startup_checks`` (same rules as ``agent_chats_config``).
"""
from __future__ import annotations

from dataclasses import dataclass

from backend.config_loader import ConfigSectionError, load_section
from backend.interactions.chat_config import CONFIG_PATH

SECTION = "agent_chat_memory"
_KEYS = (
    "window_messages",
    "summary_threshold",
    "summary_batch_max_messages",
    "message_max_chars",
    "summary_max_chars",
    "summary_max_tokens",
    "summary_model",
    "summary_timeout_seconds",
)


@dataclass(frozen=True)
class AgentMemoryConfig:
    window_messages: int
    summary_threshold: int
    summary_batch_max_messages: int
    message_max_chars: int
    summary_max_chars: int
    summary_max_tokens: int
    summary_model: str
    summary_timeout_seconds: int


_cached: AgentMemoryConfig | None = None


def _bounded(name: str, value: int, low: int, high: int) -> int:
    if value < low or value > high:
        raise ConfigSectionError(f"chat.json[{SECTION}]: {name} must be between {low} and {high}")
    return value


def _load() -> AgentMemoryConfig:
    types = {k: int for k in _KEYS}
    types["summary_model"] = str
    raw = load_section(CONFIG_PATH, SECTION, required_keys=_KEYS, types=types)
    model = raw["summary_model"].strip()
    if not model or len(model) > 200:
        raise ConfigSectionError(f"chat.json[{SECTION}]: summary_model must be a non-empty model name")
    return AgentMemoryConfig(
        window_messages=_bounded("window_messages", raw["window_messages"], 1, 200),
        summary_threshold=_bounded("summary_threshold", raw["summary_threshold"], 1, 1000),
        summary_batch_max_messages=_bounded("summary_batch_max_messages", raw["summary_batch_max_messages"], 1, 500),
        message_max_chars=_bounded("message_max_chars", raw["message_max_chars"], 100, 100000),
        summary_max_chars=_bounded("summary_max_chars", raw["summary_max_chars"], 200, 50000),
        summary_max_tokens=_bounded("summary_max_tokens", raw["summary_max_tokens"], 50, 8000),
        summary_model=model,
        summary_timeout_seconds=_bounded("summary_timeout_seconds", raw["summary_timeout_seconds"], 1, 300),
    )


def get_agent_memory_config() -> AgentMemoryConfig:
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def validate_agent_memory_config() -> None:
    global _cached
    _cached = _load()


def reset_for_tests() -> None:
    global _cached
    _cached = None
