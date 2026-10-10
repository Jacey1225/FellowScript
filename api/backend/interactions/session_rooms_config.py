"""Validated tunables for discussion rooms (``api/config/session_rooms.json``,
section ``session_rooms``). Task 20261009-discussion-rooms.

Loaded through the shared ``config_loader`` (every key required, unknown keys and
wrong types rejected, no implicit defaults) and cached after first load.
``validate_session_rooms_config()`` runs from ``startup_checks`` so a bad file
refuses to boot. The flag ``discussion_rooms`` is a DB row (see ``flags``).
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from limits import parse as _parse_rate

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "session_rooms.json"
SECTION = "session_rooms"
RATE_LIMIT_KEYS = ("create", "join", "list", "heartbeat", "other")
_TITLE_COLUMN_MAX = 80  # session_rooms.title is VARCHAR(80)

_INT_KEYS = (
    "max_members_per_room", "max_rooms_per_session", "max_creates_per_user_per_minute",
    "title_max_length", "max_invites_per_room", "member_stale_seconds", "empty_grace_seconds",
    "ended_retention_seconds", "lock_timeout_ms", "sweep_interval_seconds",
    "sweep_chime_checks_per_run",
)
_BOUNDS = {
    # Chime allows 250 attendees per meeting; 50 is a sane product ceiling.
    "max_members_per_room": (2, 50),
    "max_rooms_per_session": (1, 20),
    "max_creates_per_user_per_minute": (1, 60),
    "title_max_length": (1, _TITLE_COLUMN_MAX),
    "max_invites_per_room": (1, 250),
    # Must comfortably exceed the client heartbeat interval.
    "member_stale_seconds": (30, 600),
    "empty_grace_seconds": (30, 3600),
    "ended_retention_seconds": (60, 604800),
    # Bounded lock wait: a route holds a threadpool token for at most this long.
    "lock_timeout_ms": (100, 10000),
    "sweep_interval_seconds": (10, 3600),
    # Chime GetMeeting/DeleteMeeting default quota is 10 requests/second/account.
    "sweep_chime_checks_per_run": (0, 20),
}


@dataclass(frozen=True)
class SessionRoomsConfig:
    max_members_per_room: int
    max_rooms_per_session: int
    max_creates_per_user_per_minute: int
    title_max_length: int
    max_invites_per_room: int
    member_stale_seconds: int
    empty_grace_seconds: int
    ended_retention_seconds: int
    lock_timeout_ms: int
    sweep_interval_seconds: int
    sweep_chime_checks_per_run: int
    rate_limits: dict


_cached: SessionRoomsConfig | None = None


def _err(msg: str) -> ConfigSectionError:
    return ConfigSectionError(f"session_rooms.json[{SECTION}]: {msg}")


def _load() -> SessionRoomsConfig:
    types = {k: int for k in _INT_KEYS}
    types["rate_limits"] = dict
    raw = load_section(CONFIG_PATH, SECTION, required_keys=_INT_KEYS + ("rate_limits",), types=types)
    for key, (low, high) in _BOUNDS.items():
        if not low <= raw[key] <= high:
            raise _err(f"{key} must be between {low} and {high}")
    rates = raw["rate_limits"]
    if set(rates) != set(RATE_LIMIT_KEYS):
        raise _err(f"rate_limits must contain exactly {list(RATE_LIMIT_KEYS)}")
    for key, value in rates.items():
        try:
            if not isinstance(value, str):
                raise ValueError("not a string")
            _parse_rate(value)
        except Exception:
            raise _err(f"rate_limits.{key} is not a valid rate limit") from None
    return SessionRoomsConfig(rate_limits=dict(rates), **{k: raw[k] for k in _INT_KEYS})


def get_session_rooms_config() -> SessionRoomsConfig:
    """Validated config, loaded once. Raises ``ConfigSectionError``; never defaults."""
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def validate_session_rooms_config() -> None:
    """Startup check: load uncached so a file edited since import is re-read."""
    global _cached
    _cached = _load()


def reset_for_tests() -> None:
    global _cached
    _cached = None
