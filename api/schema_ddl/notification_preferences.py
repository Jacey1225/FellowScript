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
    apply_reminders(cur)


# Task 20261016-push-notifications-and-ui. All additive and idempotent.
#
# Opt-in reminders (default FALSE; a missing row also means OFF, see
# ``push_preferences.DEFAULT_OFF_TYPES``) with a per-type local time of day.
# The time is a wall-clock TIME interpreted in the user's ``users.timezone``
# at fire time, so a timezone change moves the reminder with the user. The
# ``*_sent_date`` columns are the once-per-local-day dedup markers.
_OPT_IN_REMINDERS = (
    ("prayer_reminder", "08:00"),
    ("check_in_reminder", "18:00"),
    ("deep_question_reminder", "20:00"),
)


def apply_reminders(cur) -> None:
    for col, default_time in _OPT_IN_REMINDERS:
        cur.execute(f"ALTER TABLE push_preferences ADD COLUMN IF NOT EXISTS {col} BOOLEAN NOT NULL DEFAULT FALSE")
        cur.execute(
            f"ALTER TABLE push_preferences ADD COLUMN IF NOT EXISTS {col}_time TIME NOT NULL DEFAULT '{default_time}'"
        )
        cur.execute(f"ALTER TABLE push_preferences ADD COLUMN IF NOT EXISTS {col}_sent_date DATE")
    # Default-ON reminder one hour before a scheduled announcement goes live.
    cur.execute(
        "ALTER TABLE push_preferences ADD COLUMN IF NOT EXISTS announcement_reminder BOOLEAN NOT NULL DEFAULT TRUE"
    )
    # Single-winner dedup marker for the one-hour-before announcement reminder.
    cur.execute(
        "ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS reminder_push_sent_at TIMESTAMPTZ"
    )
