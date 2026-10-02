"""DDL module ``chat_pagination``: ordering column, soft-delete columns, indexes.

ORDER MATTERS (contract 6.15). The group index references ``seq`` so it must
come after the column exists; creating it first fails with
``column "seq" does not exist``. Steps, all idempotent:

  1  CREATE SEQUENCE IF NOT EXISTS messages_seq
  2  ADD COLUMN IF NOT EXISTS seq BIGINT              (nullable, no rewrite)
  3  ALTER COLUMN seq SET DEFAULT nextval('messages_seq')
     (set separately so existing rows are not rewritten; they keep NULL and
     read as 0 through COALESCE)
  4  ADD COLUMN IF NOT EXISTS deleted_at / deleted_by
  4b partial index on deleted_by so the ON DELETE SET NULL foreign key does
     not scan ``messages`` on every DELETE FROM users
  5  idx_messages_group_page

Never ``CREATE INDEX CONCURRENTLY`` here: this runs inside the boot
transaction. For a very large table the operator builds the index out of band
(ALTER steps 1-4, then CONCURRENTLY, then checks ``pg_index.indisvalid``); a
failed concurrent build leaves an INVALID index that ``IF NOT EXISTS``
silently skips, which is why the validity check is part of the runbook.
"""


def apply(cur) -> None:
    cur.execute("CREATE SEQUENCE IF NOT EXISTS messages_seq")
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS seq BIGINT")
    cur.execute("ALTER TABLE messages ALTER COLUMN seq SET DEFAULT nextval('messages_seq')")
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ")
    cur.execute(
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_by UUID "
        "REFERENCES users(_id) ON DELETE SET NULL"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_messages_deleted_by "
        "ON messages (deleted_by) WHERE deleted_by IS NOT NULL"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_messages_group_page "
        "ON messages (group_id, timestamp DESC, (COALESCE(seq, 0)) DESC, _id DESC)"
    )
