"""DDL module ``home_messages``: admin-managed announcement headlines shown on
the iOS home screen (task 20261002-home-announcement-headline).

Plain-text only (validated by the app before insert; the column is VARCHAR(500)
as a hard backstop above the configurable cap). New rows start disabled.
``destination`` is reserved and currently restricted to 'none'; widening the
CHECK later is a one-line DDL change. ``created_by``/``updated_by`` are text
with no FK so deleting an admin account never touches the table.
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS home_messages("
        "_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "text VARCHAR(500) NOT NULL,"
        "enabled BOOLEAN NOT NULL DEFAULT FALSE,"
        "starts_at TIMESTAMPTZ,"
        "ends_at TIMESTAMPTZ,"
        "priority INTEGER NOT NULL DEFAULT 0,"
        "destination TEXT NOT NULL DEFAULT 'none' CHECK (destination IN ('none')),"
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "created_by TEXT,"
        "updated_by TEXT,"
        "CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at))"
    )
