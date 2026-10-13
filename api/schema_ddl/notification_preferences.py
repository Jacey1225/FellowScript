"""DDL module ``notification_preferences`` (task 20261012-notification-settings).

Generalizes ``push_preferences`` (created by ``reaction_highlight_push``) with
one BOOLEAN column per user-toggleable push type. Every column defaults TRUE and
a missing row also means "on", so no backfill is needed. Additive and idempotent
(``ADD COLUMN IF NOT EXISTS`` only). The column names are the API keys and are
listed in ``backend.interactions.push_preferences.PUSH_TYPES``.
"""

_COLUMNS = (
    "messages",
    "pins",
    "reactions",
    "announcements",
    "session_reminders",
    "reminders",
    "friend_activity",
    "join_requests",
)


def apply(cur) -> None:
    for col in _COLUMNS:
        cur.execute(
            f"ALTER TABLE push_preferences ADD COLUMN IF NOT EXISTS {col} BOOLEAN NOT NULL DEFAULT TRUE"
        )
