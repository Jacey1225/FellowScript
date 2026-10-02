"""DDL module ``outbox``: S3 keys waiting to be deleted.

Keys only (no bucket, no URLs, no user data). Callers INSERT inside the same
transaction as the row deletion; a scheduler job drains it off the event loop.
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS pending_s3_deletes("
        "key TEXT PRIMARY KEY,"
        "enqueued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "attempts INTEGER NOT NULL DEFAULT 0,"
        "last_attempt_at TIMESTAMPTZ)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_pending_s3_deletes_attempts "
        "ON pending_s3_deletes (attempts, enqueued_at)"
    )
