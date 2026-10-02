"""Generic loader for one section of a structured config file.

Same rules as ``invites_config``: every key is required (no implicit
defaults), unknown keys and wrong types are rejected, rate-limit strings must
parse with ``limits.parse``. Call it eagerly at startup (from a
``startup_checks`` entry) so a bad file refuses to boot.

    load_section(path, "pagination",
                 required_keys=("default_limit", "rate"),
                 types={"default_limit": int, "rate": str},
                 rate_keys=("rate",))

``bool`` is never accepted where ``int`` is declared. Errors name the file,
section and key, never the offending value's content beyond its repr of a
config literal.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable, Mapping

from limits import parse as _parse_rate


class ConfigSectionError(RuntimeError):
    """Config file missing, malformed or invalid."""


def _type_ok(value, expected) -> bool:
    expected_t = expected if isinstance(expected, tuple) else (expected,)
    if isinstance(value, bool):
        return bool in expected_t
    return isinstance(value, expected_t)


def load_section(
    path: str | Path,
    section: str,
    required_keys: Iterable[str],
    types: Mapping[str, type | tuple[type, ...]],
    rate_keys: Iterable[str] = (),
) -> dict:
    required = tuple(required_keys)
    rate = tuple(rate_keys)
    missing_types = [k for k in required if k not in types]
    if missing_types:
        raise ValueError(f"types missing for keys {missing_types}")  # programmer error
    for k in rate:
        if k not in required:
            raise ValueError(f"rate key {k!r} is not a required key")
    where = f"{Path(path).name}[{section}]"
    try:
        raw = json.loads(Path(path).read_text())
    except FileNotFoundError:
        raise ConfigSectionError(f"config file not found: {path}") from None
    except json.JSONDecodeError as e:
        raise ConfigSectionError(f"config file is not valid JSON ({Path(path).name}): {e}") from None
    if not isinstance(raw, dict):
        raise ConfigSectionError(f"{Path(path).name}: top level must be a JSON object")
    sec = raw.get(section)
    if not isinstance(sec, dict):
        raise ConfigSectionError(f"{where}: section missing or not an object")
    missing = [k for k in required if k not in sec]
    if missing:
        raise ConfigSectionError(f"{where}: missing keys {missing}; there are no implicit defaults")
    unknown = [k for k in sec if k not in required]
    if unknown:
        raise ConfigSectionError(f"{where}: unknown keys {unknown}")
    for k in required:
        if not _type_ok(sec[k], types[k]):
            raise ConfigSectionError(f"{where}: {k} has the wrong type ({type(sec[k]).__name__})")
    for k in rate:
        try:
            if not isinstance(sec[k], str):
                raise ValueError("not a string")
            _parse_rate(sec[k])
        except Exception as e:  # limits raises ValueError on a bad string
            raise ConfigSectionError(f"{where}: {k} ({sec[k]!r}) is not a valid rate limit: {e}") from None
    return dict(sec)
