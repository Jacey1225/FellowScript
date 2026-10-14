"""Validated tunables for live-call transcription used by session summaries
(``api/config/session_transcription.json``, section ``session_transcription``).

Every key required, no implicit defaults, validated at startup.
``is_transcription_enabled()`` is the runtime gate and fails closed: any config
error means the feature is off. Ships ``enabled: false``; turning it on needs
the user's approval (IAM, Transcribe cost, server-side collector).
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import Path

from backend.config_loader import ConfigSectionError, load_section

SECTION = "session_transcription"
CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "session_transcription.json"
_LANG_RE = re.compile(r"^[a-z]{2,3}-[A-Z]{2}$")

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SessionTranscriptionConfig:
    enabled: bool
    language_code: str
    max_transcript_chars: int
    min_transcript_chars: int
    ttl_seconds: int
    ingest_max_body_bytes: int
    ingest_max_segments: int
    ingest_max_segment_chars: int
    ingest_max_requests_per_minute: int   # per session, enforced in the store
    ingest_rate_limit: str                # per client IP (slowapi)
    relay_status_rate_limit: str
    relay_stale_seconds: int              # no sign of life for this long = not in the call
    relay_poll_interval_seconds: int      # how often clients should poll relay status


_cached: SessionTranscriptionConfig | None = None


def _load() -> SessionTranscriptionConfig:
    raw = load_section(
        CONFIG_PATH,
        SECTION,
        required_keys=("enabled", "language_code", "max_transcript_chars", "min_transcript_chars", "ttl_seconds",
                       "ingest_max_body_bytes", "ingest_max_segments", "ingest_max_segment_chars",
                       "ingest_max_requests_per_minute", "ingest_rate_limit", "relay_status_rate_limit",
                       "relay_stale_seconds", "relay_poll_interval_seconds"),
        types={"enabled": bool, "language_code": str, "max_transcript_chars": int,
               "min_transcript_chars": int, "ttl_seconds": int,
               "ingest_max_body_bytes": int, "ingest_max_segments": int, "ingest_max_segment_chars": int,
               "ingest_max_requests_per_minute": int, "ingest_rate_limit": str,
               "relay_status_rate_limit": str, "relay_stale_seconds": int,
               "relay_poll_interval_seconds": int},
        rate_keys=("ingest_rate_limit", "relay_status_rate_limit"),
    )
    if not _LANG_RE.match(raw["language_code"]):
        raise ConfigSectionError(f"session_transcription.json[{SECTION}]: language_code must look like en-US")
    if not (1000 <= raw["max_transcript_chars"] <= 200_000):
        raise ConfigSectionError(f"session_transcription.json[{SECTION}]: max_transcript_chars must be 1000..200000")
    if not (0 <= raw["min_transcript_chars"] < raw["max_transcript_chars"]):
        raise ConfigSectionError(f"session_transcription.json[{SECTION}]: min_transcript_chars must be >= 0 and < max")
    if not (60 <= raw["ttl_seconds"] <= 86_400):
        raise ConfigSectionError(f"session_transcription.json[{SECTION}]: ttl_seconds must be 60..86400")
    for k, lo, hi in (("ingest_max_body_bytes", 1024, 262_144), ("ingest_max_segments", 1, 500),
                      ("ingest_max_segment_chars", 50, 10_000), ("ingest_max_requests_per_minute", 1, 600),
                      ("relay_stale_seconds", 10, 600), ("relay_poll_interval_seconds", 2, 120)):
        if not (lo <= raw[k] <= hi):
            raise ConfigSectionError(f"session_transcription.json[{SECTION}]: {k} must be {lo}..{hi}")
    if raw["relay_poll_interval_seconds"] * 2 > raw["relay_stale_seconds"]:
        raise ConfigSectionError(
            f"session_transcription.json[{SECTION}]: relay_stale_seconds must be at least twice relay_poll_interval_seconds")
    return SessionTranscriptionConfig(**raw)


def get_session_transcription_config() -> SessionTranscriptionConfig:
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def is_transcription_enabled() -> bool:
    """Fail closed: a missing/invalid section reads as disabled."""
    try:
        return get_session_transcription_config().enabled
    except ConfigSectionError:
        logger.error("session_transcription config invalid; transcription treated as disabled")
        return False


def validate_session_transcription_config() -> None:
    global _cached
    _cached = _load()


def reset_for_tests() -> None:
    global _cached
    _cached = None
