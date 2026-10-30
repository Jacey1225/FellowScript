"""DDL module ``chat_announcements`` (task 20261030-chat-announcements; flag ``chat_announcements``).

Idempotent (ADD COLUMN / CREATE INDEX IF NOT EXISTS only), additive, no backfill:

- ``group_announcements.post_to_chat``: the author's choice, made at create time,
  to also show the announcement in the group's message timeline. Existing rows
  stay FALSE, so nothing published before the flag turns on ever appears.
- ``messages.announcement_id``: links a timeline line (``system_kind =
  'announcement'``) to its one announcement record. CASCADE: a hard delete of
  the announcement (group delete, account delete) removes the line. NULL for
  every ordinary message.
- unique partial index on ``messages.announcement_id``: at most one line per
  announcement, which makes emission idempotent under retries and concurrent
  workers.
- partial index on ``group_announcements(publish_at) WHERE post_to_chat`` for
  the scheduler's due scan.

Depends on ``messages`` (plus ``system_kind``, added by ``message_pins``) and
``group_announcements`` (created before DDL modules run).
"""


def apply(cur) -> None:
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS system_kind TEXT")
    cur.execute(
        "ALTER TABLE group_announcements ADD COLUMN IF NOT EXISTS post_to_chat BOOLEAN NOT NULL DEFAULT FALSE"
    )
    cur.execute(
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS announcement_id UUID "
        "REFERENCES group_announcements(_id) ON DELETE CASCADE"
    )
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_messages_announcement_id "
        "ON messages (announcement_id) WHERE announcement_id IS NOT NULL"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_group_announcements_chat_due "
        "ON group_announcements (publish_at) WHERE post_to_chat"
    )
