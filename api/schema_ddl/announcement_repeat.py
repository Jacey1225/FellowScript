"""DDL module ``announcement_repeat`` (task 20261016-announcement-recurring-reminder).

Recurring re-push of a published group announcement. Additive and idempotent
(``ADD COLUMN IF NOT EXISTS`` / ``CREATE INDEX IF NOT EXISTS`` only); every
column is NULL or defaulted, so existing rows are unchanged (NULL
``repeat_interval`` = no repeat) and old code keeps working against the new
schema.

Columns on ``group_announcements``:

- ``repeat_interval``      NULL | 'daily' | 'weekly' | 'monthly' (CHECK-enforced)
- ``repeat_until``         author's explicit end (TIMESTAMPTZ), NULL = none
- ``repeat_tz``            IANA name the wall-clock time is anchored in; NULL = UTC
- ``repeat_started_at``    when the repeat was last set/changed (365-day horizon base)
- ``next_repeat_at``       next occurrence to fire; NULL = disarmed
- ``repeat_push_count``    occurrences pushed so far (lifetime cap per announcement)
- ``last_repeat_push_at``  last repeat push (per-group rolling cap)

This DDL is NOT applied to production by the pipeline; it runs on the next
normal boot (``create_tables``) after Jacey approves a deploy.
"""


def apply(cur) -> None:
    cur.execute(
        "ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS repeat_interval VARCHAR(8) "
        "CHECK (repeat_interval IN ('daily', 'weekly', 'monthly'))"
    )
    cur.execute("ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS repeat_until TIMESTAMPTZ")
    cur.execute("ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS repeat_tz VARCHAR(64)")
    cur.execute("ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS repeat_started_at TIMESTAMPTZ")
    cur.execute("ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS next_repeat_at TIMESTAMPTZ")
    cur.execute(
        "ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS repeat_push_count INTEGER NOT NULL DEFAULT 0"
    )
    cur.execute("ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS last_repeat_push_at TIMESTAMPTZ")
    # Serves the scheduler's due-scan; tiny because only armed rows are indexed.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_group_announcements_repeat_due "
        "ON group_announcements(next_repeat_at) "
        "WHERE next_repeat_at IS NOT NULL AND deleted_at IS NULL"
    )
