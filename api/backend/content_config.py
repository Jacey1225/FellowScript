"""Validated tunables for content encryption at rest
(``api/config/content_encryption.json``, section ``content_encryption``).

Loaded through the shared ``config_loader`` (every key required, unknown keys
and wrong types rejected), no implicit defaults, cached after the first
successful load. ``validate_content_config()`` runs from ``startup_checks``.
The key ring itself is NEVER in this file: it is the env var
``CONTENT_ENCRYPTION_KEYS`` (see ``backend.content_crypto``).
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[1] / "config" / "content_encryption.json"
SECTION = "content_encryption"

_INT_KEYS = (
    "search_batch_size", "search_scan_cap", "group_search_scan_cap",
    "backfill_batch_size", "backfill_throttle_ms",
    "backfill_statement_timeout_ms", "backfill_lock_timeout_ms",
)
_MAX_SCAN_CAP = 100_000
_MAX_BATCH = 5_000


@dataclass(frozen=True)
class ContentConfig:
    search_batch_size: int
    search_scan_cap: int
    group_search_scan_cap: int
    backfill_batch_size: int
    backfill_throttle_ms: int
    backfill_statement_timeout_ms: int
    backfill_lock_timeout_ms: int


_cached: ContentConfig | None = None


def _load() -> ContentConfig:
    raw = load_section(
        CONFIG_PATH, SECTION,
        required_keys=_INT_KEYS,
        types={k: int for k in _INT_KEYS},
    )
    for k in _INT_KEYS:
        floor = 0 if k == "backfill_throttle_ms" else 1
        if raw[k] < floor:
            raise ConfigSectionError(f"content_encryption.json[{SECTION}]: {k} must be >= {floor}")
    for k in ("search_batch_size", "backfill_batch_size"):
        if raw[k] > _MAX_BATCH:
            raise ConfigSectionError(f"content_encryption.json[{SECTION}]: {k} must be <= {_MAX_BATCH}")
    for k in ("search_scan_cap", "group_search_scan_cap"):
        if raw[k] > _MAX_SCAN_CAP:
            raise ConfigSectionError(f"content_encryption.json[{SECTION}]: {k} must be <= {_MAX_SCAN_CAP}")
    return ContentConfig(**{k: raw[k] for k in _INT_KEYS})


def get_content_config() -> ContentConfig:
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def validate_content_config() -> None:
    get_content_config()
