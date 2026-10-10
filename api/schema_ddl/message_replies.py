"""DDL module ``message_replies`` (task 20261010-announcement-location-chat-replies).

One nullable column on ``messages`` (group chats and DMs share that table;
group thread messages are deferred), idempotent (ADD COLUMN IF NOT EXISTS /
CREATE INDEX IF NOT EXISTS), so existing rows and old clients are untouched:

- ``reply_to_id``: the replied-to message id. Deliberately NO foreign key and no
  copy of the original's text or author: the label is derived at read time by
  joining to the original, so edits show and a hard-deleted original is retained
  nowhere. A pointer to a missing row reads as ``reply_to_deleted``.

The partial index serves the read-time join and "is a reply" lookups. Depends
on ``messages`` (created before DDL modules run).
"""


def apply(cur) -> None:
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_id UUID")
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_messages_reply_to_id "
        "ON messages (reply_to_id) WHERE reply_to_id IS NOT NULL"
    )
