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


def check_media_config() -> None:
    from backend.interactions.listings_media_config import validate_media_config

    validate_media_config()


def check_threads_config() -> None:
    from backend.interactions.threads_config import validate_threads_config

    validate_threads_config()


def check_join_requests_config() -> None:
    from backend.interactions.join_requests_config import validate_join_requests_config

    validate_join_requests_config()


def check_agent_chats_config() -> None:
    from backend.interactions.agent_chats_config import validate_agent_chats_config

    validate_agent_chats_config()


def check_session_summary_fanout_config() -> None:
    from backend.interactions.session_summary_fanout_config import validate_session_summary_fanout_config

    validate_session_summary_fanout_config()


def check_agent_chat_memory_config() -> None:
    from backend.interactions.agent_memory_config import validate_agent_memory_config

    validate_agent_memory_config()


def check_home_messages_config() -> None:
    from backend.interactions.home_messages_config import validate_home_messages_config

    validate_home_messages_config()


def check_affiliates_config() -> None:
    from backend.subscription.affiliates_config import validate_affiliates_config

    validate_affiliates_config()


def check_payout_encryption_keys() -> None:
    from backend.subscription.payout_crypto import validate_payout_keys

    validate_payout_keys()


def check_content_encryption_keys() -> None:
    from backend.content_crypto import validate_content_keys

    validate_content_keys()


def check_content_encryption_config() -> None:
    from backend.content_config import validate_content_config

    validate_content_config()


def check_email_verification_config() -> None:
    from backend.auth.email_verification_config import validate_email_verification_config

    validate_email_verification_config()


def check_session_rooms_config() -> None:
    from backend.interactions.session_rooms_config import validate_session_rooms_config

    validate_session_rooms_config()


CHECKS = (
    check_flag_registry,
    check_chat_pagination_config,
    check_listings_config,
    check_media_config,
    check_threads_config,
    check_join_requests_config,
    check_home_messages_config,
    check_agent_chats_config,
    check_agent_chat_memory_config,
    check_session_summary_fanout_config,
    check_affiliates_config,
    check_payout_encryption_keys,
    check_content_encryption_keys,
    check_content_encryption_config,
    check_email_verification_config,
    check_session_rooms_config,
)


def validate_all() -> None:
    for check in CHECKS:
        check()
