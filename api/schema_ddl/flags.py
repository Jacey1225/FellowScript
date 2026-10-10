"""DDL module ``flags``: the feature_flags table and its seed rows."""

# Every flag ships ``off``. A flag that is registered in
# backend.interactions.flags but missing here still works: the admin writer
# upserts, and a missing row reads as off.
SEED_FLAG_NAMES = (
    "chat_pagination",
    "chat_pagination_dm",
    "threads",
    "message_delete",
    "message_reactions",
    "verse_reactions",
    "explorer_publish",
    "explorer_browse",
    "join_requests",
    "join_request_push",
    "agent_chats",
    "agent_chat_memory",
    "affiliates",
    "affiliate_payouts",
    "content_encryption_write",
)


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS feature_flags("
        "name TEXT PRIMARY KEY,"
        "state TEXT NOT NULL DEFAULT 'off' CHECK (state IN ('off','canary','on')),"
        "canary_user_ids UUID[] NOT NULL DEFAULT '{}',"
        "updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        # Actor user id (or 'cli'); text on purpose, no FK, so deleting an
        # admin account never touches this table.
        "updated_by TEXT)"
    )
    for name in SEED_FLAG_NAMES:
        cur.execute(
            "INSERT INTO feature_flags (name, state) VALUES (%s, 'off') "
            "ON CONFLICT (name) DO NOTHING",
            (name,),
        )
