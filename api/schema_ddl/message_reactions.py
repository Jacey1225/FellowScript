"""DDL module ``message_reactions``: one row per (message, user, emoji).

Idempotent (CREATE ... IF NOT EXISTS only). Rows are kept when a message is
soft-deleted (readers filter on ``messages.deleted_at``) so a restore brings
them back; a hard delete of the message or the user cascades them away.
Depends on ``messages`` and ``users`` (created before DDL modules run).
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS message_reactions ("
        "message_id UUID NOT NULL REFERENCES messages(_id) ON DELETE CASCADE, "
        "user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE, "
        "emoji TEXT NOT NULL, "
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), "
        "PRIMARY KEY (message_id, user_id, emoji))"
    )
    # Aggregation is by message (PK prefix covers it); this covers the
    # user-side cascade on DELETE FROM users.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_message_reactions_user ON message_reactions (user_id)"
    )
