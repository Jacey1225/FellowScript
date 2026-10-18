"""DDL module ``message_mentions`` (task 20261017-chat-mentions).

One nullable JSONB column on each message table, idempotent (ADD COLUMN IF NOT
EXISTS), so existing rows and old clients are untouched:

- ``messages.mentions`` (group main chat and DMs share ``messages``)
- ``thread_messages.mentions``

NULL means no mentions (never ``[]``). A value is the validated array of
``{"user_id", "start", "length"}`` (UTF-16 code unit offsets into the stored
text); usernames are never stored, they are resolved at read time. No default,
no index, no foreign key. Must run after ``threads`` (creates thread_messages).
"""


def apply(cur) -> None:
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS mentions JSONB")
    cur.execute("ALTER TABLE thread_messages ADD COLUMN IF NOT EXISTS mentions JSONB")
