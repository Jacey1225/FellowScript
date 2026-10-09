"""Validated tunables for message threads and message delete
(``api/config/chat.json``, sections ``threads`` and ``message_delete``).

Same rules as ``chat_config``: loaded through the shared ``config_loader``
(every key required, unknown keys and wrong types rejected, rate strings must
parse), no implicit defaults, cached after the first successful load.
``validate_threads_config()`` runs from ``startup_checks`` so a bad file
refuses to boot. Tunables are baked JSON: changing one is an ordinary
reviewed deploy, not an emergency lever (feature flags are).
"""
from __future__ import annotations

from dataclasses import dataclass

from backend.config_loader import ConfigSectionError, load_section
from backend.interactions.chat_config import CONFIG_PATH

THREADS_SECTION = "threads"
DELETE_SECTION = "message_delete"

_MAX_TITLE_COLUMN = 80  # threads.title is VARCHAR(80)
_MAX_RETENTION_DAYS = 3650
_MAX_UNDO_SECONDS = 3600


@dataclass(frozen=True)
class ThreadsConfig:
    title_max_length: int
    auto_title_length: int
    root_preview_length: int
    max_threads_per_group: int
    create_rate: str
    send_rate: str
    delete_rate: str


@dataclass(frozen=True)
class MessageDeleteConfig:
    undo_seconds: int
    evidence_retention_days: int
    delete_rate: str
    restore_rate: str
    sweep_batch_size: int


_threads: ThreadsConfig | None = None
_delete: MessageDeleteConfig | None = None


def _bounded(section: str, name: str, value: int, low: int, high: int) -> int:
    if value < low or value > high:
        raise ConfigSectionError(f"chat.json[{section}]: {name} must be between {low} and {high}")
    return value


def _load_threads() -> ThreadsConfig:
    raw = load_section(
        CONFIG_PATH,
        THREADS_SECTION,
        required_keys=(
            "title_max_length", "auto_title_length", "root_preview_length",
            "max_threads_per_group", "create_rate", "send_rate", "delete_rate",
        ),
        types={
            "title_max_length": int, "auto_title_length": int, "root_preview_length": int,
            "max_threads_per_group": int, "create_rate": str, "send_rate": str, "delete_rate": str,
        },
        rate_keys=("create_rate", "send_rate", "delete_rate"),
    )
    title_max = _bounded(THREADS_SECTION, "title_max_length", raw["title_max_length"], 1, _MAX_TITLE_COLUMN)
    auto = _bounded(THREADS_SECTION, "auto_title_length", raw["auto_title_length"], 1, title_max)
    preview = _bounded(THREADS_SECTION, "root_preview_length", raw["root_preview_length"], 1, 1000)
    cap = _bounded(THREADS_SECTION, "max_threads_per_group", raw["max_threads_per_group"], 1, 100000)
    return ThreadsConfig(title_max, auto, preview, cap, raw["create_rate"], raw["send_rate"], raw["delete_rate"])


def _load_delete() -> MessageDeleteConfig:
    raw = load_section(
        CONFIG_PATH,
        DELETE_SECTION,
        required_keys=(
            "undo_seconds", "evidence_retention_days", "delete_rate",
            "restore_rate", "sweep_batch_size",
        ),
        types={
            "undo_seconds": int, "evidence_retention_days": int, "delete_rate": str,
            "restore_rate": str, "sweep_batch_size": int,
        },
        rate_keys=("delete_rate", "restore_rate"),
    )
    undo = _bounded(DELETE_SECTION, "undo_seconds", raw["undo_seconds"], 1, _MAX_UNDO_SECONDS)
    # 0 would revert to purging immediately, before a report can capture the text.
    days = _bounded(DELETE_SECTION, "evidence_retention_days", raw["evidence_retention_days"], 1, _MAX_RETENTION_DAYS)
    batch = _bounded(DELETE_SECTION, "sweep_batch_size", raw["sweep_batch_size"], 1, 10000)
    return MessageDeleteConfig(undo, days, raw["delete_rate"], raw["restore_rate"], batch)


def get_threads_config() -> ThreadsConfig:
    """Validated config, loaded once. Raises ``ConfigSectionError``; never defaults."""
    global _threads
    if _threads is None:
        _threads = _load_threads()
    return _threads


def get_message_delete_config() -> MessageDeleteConfig:
    global _delete
    if _delete is None:
        _delete = _load_delete()
    return _delete


def validate_threads_config() -> None:
    """Startup check: load both sections uncached so a file edited since import is re-read."""
    global _threads, _delete
    _threads = _load_threads()
    _delete = _load_delete()


def reset_for_tests() -> None:
    global _threads, _delete
    _threads = None
    _delete = None
