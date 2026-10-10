"""DDL module ``reaction_highlight_push`` (task 20261010-reaction-highlight-push).

Three small tables, all idempotent (CREATE ... IF NOT EXISTS only):

- ``push_preferences``: one optional row per user. ``friend_highlight`` defaults
  TRUE; a missing row also means "on", so no backfill is needed.
- ``message_reaction_push_claims``: one row per message. The reaction push claims
  it atomically; reactions inside the coalescing window do not push again.
- ``friend_highlight_push_claims``: one row per (highlighter, recipient). The
  highlight push claims it atomically; at most one push per pair per hour.

Rows cascade away with the message or either user. Depends on ``messages`` and
``users`` (created before DDL modules run).
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS push_preferences ("
        "user_id UUID PRIMARY KEY REFERENCES users(_id) ON DELETE CASCADE, "
        "friend_highlight BOOLEAN NOT NULL DEFAULT TRUE, "
        "updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS message_reaction_push_claims ("
        "message_id UUID PRIMARY KEY REFERENCES messages(_id) ON DELETE CASCADE, "
        "last_pushed_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS friend_highlight_push_claims ("
        "highlighter_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE, "
        "recipient_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE, "
        "last_pushed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), "
        "PRIMARY KEY (highlighter_id, recipient_id))"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_friend_highlight_push_claims_recipient "
        "ON friend_highlight_push_claims (recipient_id)"
    )
