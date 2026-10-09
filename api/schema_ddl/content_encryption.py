"""DDL module ``content_encryption`` (task 20261008-content-encryption-at-rest).

Content columns keep their names and types; ciphertext is stored in-column as
``enc:v1:<base64url>`` (see ``backend/content_crypto.py``). The only schema
change is widening VARCHAR columns that cannot hold the ~1.4x base64 overhead
(+ ~36 bytes) to TEXT. ``ALTER COLUMN ... TYPE TEXT`` from VARCHAR(n) is
binary-coercible in Postgres: no table rewrite, brief lock, and a no-op when the
column is already TEXT, so this is safe on every boot. Defaults and NOT NULL
are untouched (messages.text stays NOT NULL; ciphertext is never NULL/empty).

No index exists on any widened/encrypted column (verified: only
idx_notes_user_timestamp, uq_notes_summary_dedupe_key and the messages/threads
paging indexes, none of which cover content), so there is nothing to rebuild.
"""

# (table, column): all idempotent when already TEXT.
WIDEN_TO_TEXT = (
    ("notes", "title"),
    ("threads", "title"),
    ("agent_chats", "title"),
)


def apply(cur) -> None:
    for table, column in WIDEN_TO_TEXT:
        cur.execute(
            "SELECT data_type FROM information_schema.columns "
            "WHERE table_schema = current_schema() AND table_name = %s AND column_name = %s",
            (table, column),
        )
        row = cur.fetchone()
        if row is None or row[0] == "text":
            continue  # table/column absent in this schema variant, or already widened
        cur.execute(f'ALTER TABLE {table} ALTER COLUMN {column} TYPE TEXT')
    # Audit trail for backfill / rollback / rotation runs (counts and timestamps
    # only, never content). Written by backend.maintenance.content_migrate.
    cur.execute(
        "CREATE TABLE IF NOT EXISTS content_encryption_audit("
        "id BIGSERIAL PRIMARY KEY,"
        "run_id UUID NOT NULL,"
        "mode TEXT NOT NULL,"
        "target TEXT NOT NULL,"
        "applied BOOLEAN NOT NULL,"
        "backup_label TEXT,"
        "table_name TEXT NOT NULL,"
        "rows_scanned BIGINT NOT NULL DEFAULT 0,"
        "values_changed BIGINT NOT NULL DEFAULT 0,"
        "values_already BIGINT NOT NULL DEFAULT 0,"
        "values_failed BIGINT NOT NULL DEFAULT 0,"
        "values_raced BIGINT NOT NULL DEFAULT 0,"
        "started_at TIMESTAMPTZ NOT NULL,"
        "finished_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "actor TEXT)"
    )
