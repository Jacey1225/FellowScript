"""DDL module ``bible_reading_days``: one row per (user, local day) on which the
user read the Bible in the app (task 20261114-activity-calendar).

Stores the DAY ONLY: never the book, chapter or verse. Composite primary key
makes the record endpoint idempotent per user per day. ON DELETE CASCADE on the
user, so account deletion removes it with no manual step (like agent_chats).
There is no backfill: the table starts empty at ship date.
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS bible_reading_days("
        "user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,"
        "day DATE NOT NULL,"
        "PRIMARY KEY (user_id, day))"
    )
