"""Startup validation scaffold, called once from the main.py lifespan.

``CHECKS`` holds zero-argument callables, one per line. A check that raises
stops the boot (deliberately not caught). Later tasks append a line for their
config section validator, e.g. ``load_listings_config``.
"""
from __future__ import annotations

from backend.interactions import flags


def check_flag_registry() -> None:
    """The flag registry and the DDL seed list must agree on seeded names."""
    from schema_ddl.flags import SEED_FLAG_NAMES

    registered = flags.registry()
    for name in SEED_FLAG_NAMES:
        if name not in registered:
            raise RuntimeError(f"seeded flag {name!r} is not registered in flags.py")
    if not registered["explorer_browse"].no_canary:
        raise RuntimeError("explorer_browse must stay no_canary (off/on only)")


def check_chat_pagination_config() -> None:
    from backend.interactions.chat_config import validate_pagination_config

    validate_pagination_config()


def check_listings_config() -> None:
    from backend.interactions.listings_config import validate_listings_config

    validate_listings_config()


def check_threads_config() -> None:
    from backend.interactions.threads_config import validate_threads_config

    validate_threads_config()


CHECKS = (
    check_flag_registry,
    check_chat_pagination_config,
    check_listings_config,
    check_threads_config,
)


def validate_all() -> None:
    for check in CHECKS:
        check()
