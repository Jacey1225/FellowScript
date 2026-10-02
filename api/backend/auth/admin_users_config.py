"""Config for the admin "User actions" routes (task 20261002-admin-user-actions).

Tunables live in ``api/config/admin_users.json``; every key is required and
unknown keys or wrong types are rejected (no implicit defaults), matching
``invites_config``. ``validate_admin_users_config()`` runs at startup and
``get_admin_users_config()`` lazily loads on first use, never falling back.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from limits import parse as _parse_rate

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "admin_users.json"
_TOP_KEYS = ("default_page_size", "max_page_size", "max_search_length", "rate_limits")
_RATE_KEYS = ("list", "mutate", "mutate_per_admin")


class AdminUsersConfigError(RuntimeError):
    """Raised when config/admin_users.json is missing, malformed, or invalid."""


@dataclass(frozen=True)
class AdminUsersConfig:
    default_page_size: int
    max_page_size: int
    max_search_length: int
    rate_limits: dict[str, str]


def _pos_int(name: str, v) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or v <= 0:
        raise AdminUsersConfigError(f"admin_users config: {name} must be a positive integer, got {v!r}")
    return v


def parse_admin_users_config(raw: object) -> AdminUsersConfig:
    if not isinstance(raw, dict):
        raise AdminUsersConfigError("admin_users config: top level must be an object")
    missing = [k for k in _TOP_KEYS if k not in raw]
    unknown = [k for k in raw if k not in _TOP_KEYS]
    if missing or unknown:
        raise AdminUsersConfigError(f"admin_users config: missing={missing} unknown={unknown}")
    default_size = _pos_int("default_page_size", raw["default_page_size"])
    max_size = _pos_int("max_page_size", raw["max_page_size"])
    if default_size > max_size:
        raise AdminUsersConfigError("admin_users config: default_page_size exceeds max_page_size")
    rates = raw["rate_limits"]
    if not isinstance(rates, dict) or sorted(rates) != sorted(_RATE_KEYS):
        raise AdminUsersConfigError(f"admin_users config: rate_limits must contain exactly {list(_RATE_KEYS)}")
    for key, value in rates.items():
        try:
            _parse_rate(value)
        except Exception:
            raise AdminUsersConfigError(f"admin_users config: rate_limits.{key} is not a valid rate limit") from None
    return AdminUsersConfig(default_size, max_size, _pos_int("max_search_length", raw["max_search_length"]), dict(rates))


_config: AdminUsersConfig | None = None


def get_admin_users_config() -> AdminUsersConfig:
    global _config
    if _config is None:
        try:
            raw = json.loads(CONFIG_PATH.read_text())
        except (OSError, ValueError) as e:
            raise AdminUsersConfigError(f"admin_users config: cannot load {CONFIG_PATH}: {e}") from None
        _config = parse_admin_users_config(raw)
    return _config


def validate_admin_users_config() -> None:
    get_admin_users_config()
