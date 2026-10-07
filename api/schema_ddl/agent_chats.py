"""DDL module ``agent_chats``: multiple named chats per (user, agent).

Owns the ONLY CREATE of ``agent_chats`` and the ONLY ``chat_id`` column on
``agent_messages`` (flag ``agent_chats``). ``agent_messages.chat_id`` is
nullable on purpose: NULL marks a legacy row written before this feature (or by
a client that does not send a chat id); those rows are adopted into the
deterministic default chat lazily by ``AgentChatStore.ensure_default_chat`` --
no destructive migration, no data loss. All statements are idempotent.
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS agent_chats("
        "_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,"
        "agent_id UUID NOT NULL REFERENCES agents(_id) ON DELETE CASCADE,"
        "title VARCHAR(80) NOT NULL DEFAULT '',"
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "last_message_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_agent_chats_user_agent "
        "ON agent_chats (user_id, agent_id, last_message_at DESC)"
    )
    cur.execute(
        "ALTER TABLE agent_messages ADD COLUMN IF NOT EXISTS "
        "chat_id UUID REFERENCES agent_chats(_id) ON DELETE CASCADE"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_agent_messages_chat "
        "ON agent_messages (chat_id, timestamp)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_agent_messages_legacy "
        "ON agent_messages (user_id, agent_id) WHERE chat_id IS NULL"
    )
    # Server-side rolling summary (flag ``agent_chat_memory``). Never returned
    # by any endpoint. ``summary_through_ts`` is the timestamp of the newest
    # message folded into ``summary`` (NULL = nothing summarized yet).
    cur.execute("ALTER TABLE agent_chats ADD COLUMN IF NOT EXISTS summary TEXT")
    cur.execute("ALTER TABLE agent_chats ADD COLUMN IF NOT EXISTS summary_through_ts TIMESTAMPTZ")
