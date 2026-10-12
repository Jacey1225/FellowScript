"""DDL module ``message_pins`` (task 20261012-message-pins).

Idempotent (CREATE ... IF NOT EXISTS / ADD COLUMN IF NOT EXISTS only):

- ``message_pins``: one row per pinned message (a pin is shared by every member
  of the chat, not per user). ``chat_key`` is the group id for a group chat or
  the sorted ``"uidA|uidB"`` participant key for a DM, the same room key the
  rest of the chat code uses. No cap. Rows survive a soft delete (readers filter
  ``messages.deleted_at``) so a restore brings the pin back; a hard delete of the
  message or the pinner cascades them away.
- ``message_pin_push_claims``: atomic throttle for the "X pinned a message"
  push and in-chat line, one row per (chat, pinner); pin/unpin churn inside the
  window stays silent.
- ``messages.system_kind``: nullable marker for a server-generated system line
  (``'pin'``). NULL for every ordinary message; old clients ignore it.

Depends on ``messages`` and ``users`` (created before DDL modules run).
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS message_pins ("
        "message_id UUID PRIMARY KEY REFERENCES messages(_id) ON DELETE CASCADE, "
        "chat_key TEXT NOT NULL, "
        "pinned_by UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE, "
        "pinned_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_message_pins_chat ON message_pins (chat_key, pinned_at DESC)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_message_pins_pinned_by ON message_pins (pinned_by)"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS message_pin_push_claims ("
        "chat_key TEXT NOT NULL, "
        "pinner_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE, "
        "last_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), "
        "PRIMARY KEY (chat_key, pinner_id))"
    )
    cur.execute("ALTER TABLE messages ADD COLUMN IF NOT EXISTS system_kind TEXT")
