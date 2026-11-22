"""DDL module ``threads``: group message threads.

Owns the ONLY CREATE/ALTER of ``threads``, ``thread_messages`` and
``thread_followers``. It never alters ``messages`` (``chat_pagination`` owns
``messages.seq`` / ``deleted_at`` / ``deleted_by``) and must run after that
module: ``thread_messages.seq`` defaults to the shared ``messages_seq``
sequence it creates, and the tables reference ``groups`` / ``messages`` /
``users``.

Foreign keys: ``threads.group_id`` and ``thread_messages.thread_id`` cascade
(a thread dies only with its group). Every user or message reference is
``ON DELETE SET NULL`` so an account or message deletion never removes a
thread. ``thread_messages.deleted_by`` is the only SET NULL key on a table
that can grow large, so it gets a partial index and the ``DELETE FROM users``
path does not scan the table. ``threads.created_by``, ``root_author_id``,
``root_message_id`` and ``thread_messages.from_user`` point at small or
low-churn tables and are accepted without an index.

One thread per root message (partial unique index). All statements are
idempotent and run inside the boot transaction (lock_timeout is set by the
runner), so never ``CREATE INDEX CONCURRENTLY`` here.
"""

_THREADS = """
CREATE TABLE IF NOT EXISTS threads (
    _id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID NOT NULL REFERENCES groups(_id) ON DELETE CASCADE,
    root_message_id UUID REFERENCES messages(_id) ON DELETE SET NULL,
    root_preview TEXT,
    root_author_id UUID REFERENCES users(_id) ON DELETE SET NULL,
    title VARCHAR(80) NOT NULL,
    created_by UUID REFERENCES users(_id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""

_THREAD_MESSAGES = """
CREATE TABLE IF NOT EXISTS thread_messages (
    _id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id UUID NOT NULL REFERENCES threads(_id) ON DELETE CASCADE,
    from_user UUID REFERENCES users(_id) ON DELETE SET NULL,
    text TEXT NOT NULL DEFAULT '',
    attachment_kind TEXT,
    attachment_key TEXT,
    attachment_meta JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    seq BIGINT NOT NULL DEFAULT nextval('messages_seq'),
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES users(_id) ON DELETE SET NULL
)
"""

_THREAD_FOLLOWERS = """
CREATE TABLE IF NOT EXISTS thread_followers (
    thread_id UUID NOT NULL REFERENCES threads(_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,
    PRIMARY KEY (thread_id, user_id)
)
"""

# Per-user read marker: the highest thread_messages.seq the user has seen in a
# thread. Separate from thread_followers (which holds only the creator and root
# author) so any current member can have a marker. Rows die with the thread or
# the user. No row means nothing read yet.
_THREAD_READS = """
CREATE TABLE IF NOT EXISTS thread_reads (
    thread_id UUID NOT NULL REFERENCES threads(_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,
    last_read_seq BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (thread_id, user_id)
)
"""

# Reactions on thread messages (the main-chat table references ``messages``).
# One row per (message, user, emoji); rows survive a soft delete (readers
# filter ``thread_messages.deleted_at``) and cascade with the message or user.
_THREAD_MESSAGE_REACTIONS = """
CREATE TABLE IF NOT EXISTS thread_message_reactions (
    message_id UUID NOT NULL REFERENCES thread_messages(_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,
    emoji TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id, emoji)
)
"""

# Pins scoped to ONE thread (a thread pin never shows in the group's pin list).
# A pin is shared by every member of the thread. No cap.
_THREAD_MESSAGE_PINS = """
CREATE TABLE IF NOT EXISTS thread_message_pins (
    message_id UUID PRIMARY KEY REFERENCES thread_messages(_id) ON DELETE CASCADE,
    thread_id UUID NOT NULL REFERENCES threads(_id) ON DELETE CASCADE,
    pinned_by UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,
    pinned_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""


def apply(cur) -> None:
    cur.execute(_THREADS)
    cur.execute(_THREAD_MESSAGES)
    cur.execute(_THREAD_FOLLOWERS)
    cur.execute(_THREAD_READS)
    cur.execute(_THREAD_MESSAGE_REACTIONS)
    cur.execute(_THREAD_MESSAGE_PINS)
    # Reply target: no foreign key and no copy of the original (derived at read
    # time, like ``messages.reply_to_id``); same-thread is enforced at send.
    cur.execute("ALTER TABLE thread_messages ADD COLUMN IF NOT EXISTS reply_to_id UUID")
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_threads_root_message "
        "ON threads (root_message_id) WHERE root_message_id IS NOT NULL"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_threads_group_activity "
        "ON threads (group_id, last_activity_at DESC, _id DESC)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread_messages_page "
        "ON thread_messages (thread_id, created_at DESC, seq DESC, _id DESC)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread_messages_deleted_by "
        "ON thread_messages (deleted_by) WHERE deleted_by IS NOT NULL"
    )
    # Followers are looked up by user when a user is deleted (cascade).
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread_followers_user "
        "ON thread_followers (user_id)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread_reads_user "
        "ON thread_reads (user_id)"
    )
    # Unread counts scan a thread's messages by seq.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread_messages_seq "
        "ON thread_messages (thread_id, seq)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread_message_reactions_user "
        "ON thread_message_reactions (user_id)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread_message_pins_thread "
        "ON thread_message_pins (thread_id, pinned_at DESC)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread_message_pins_pinned_by "
        "ON thread_message_pins (pinned_by)"
    )
