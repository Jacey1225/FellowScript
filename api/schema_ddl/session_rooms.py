"""DDL module ``session_rooms``: discussion rooms (breakouts) tied to a session.

Task 20261009-discussion-rooms. A room is its own Chime meeting hanging off one
live session (``devotions`` row). Additive only: three new tables, no change to
any existing table. Needs ``devotions`` and ``users`` (both created earlier in
``create_tables``).

``session_rooms``
  - ``session_id`` cascades: deleting the main session deletes its rooms.
  - ``creator_id`` is ``ON DELETE SET NULL`` (a room outlives its creator's
    account; the session host can still end it), so it gets a partial index for
    the user-delete path.
  - ``slot`` is the room's number (1..max_rooms_per_session). The partial unique
    index over ACTIVE rooms makes "no two live rooms share a slot" a database
    guarantee; with the per-session advisory lock taken by the manager it also
    bounds the rooms-per-session cap under concurrency.
  - ``chime_meeting_id`` / ``chime_meeting`` start empty; the meeting is created
    lazily on the first join (a room nobody joins costs nothing).
  - ``visibility`` is ``open`` (any session participant may join) or
    ``invite_only`` (creator + rows in ``session_room_invites`` only). Blocks
    apply in both modes.
  - ``ended_at`` set = ended; ended rows are kept until the main session goes.

``session_room_invites``
  - One row per (room, invitee); only meaningful for ``invite_only`` rooms.

``session_room_members``
  - One row per (room, user). Rejoining clears ``left_at``.
  - Presence is ``left_at IS NULL AND last_seen > NOW() - stale_seconds``;
    ``last_seen`` is refreshed by join and by the client heartbeat.

All statements are idempotent and run inside the boot transaction (the runner
sets ``lock_timeout``), so never ``CREATE INDEX CONCURRENTLY`` here.
"""

_ROOMS = """
CREATE TABLE IF NOT EXISTS session_rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES devotions(_id) ON DELETE CASCADE,
    creator_id UUID REFERENCES users(_id) ON DELETE SET NULL,
    slot INTEGER NOT NULL CHECK (slot >= 1),
    title VARCHAR(80) NOT NULL DEFAULT '',
    visibility TEXT NOT NULL DEFAULT 'open' CHECK (visibility IN ('open', 'invite_only')),
    chime_meeting_id VARCHAR(255) NOT NULL DEFAULT '',
    chime_meeting JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at TIMESTAMPTZ
)
"""

_MEMBERS = """
CREATE TABLE IF NOT EXISTS session_room_members (
    room_id UUID NOT NULL REFERENCES session_rooms(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    left_at TIMESTAMPTZ,
    last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (room_id, user_id)
)
"""


_INVITES = """
CREATE TABLE IF NOT EXISTS session_room_invites (
    room_id UUID NOT NULL REFERENCES session_rooms(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,
    invited_by UUID REFERENCES users(_id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (room_id, user_id)
)
"""


def apply(cur) -> None:
    cur.execute(_ROOMS)
    cur.execute(_MEMBERS)
    cur.execute(_INVITES)
    # Rows created by an earlier boot of this module predate ``visibility``.
    cur.execute(
        "ALTER TABLE session_rooms ADD COLUMN IF NOT EXISTS visibility TEXT NOT NULL DEFAULT 'open'"
    )
    # A user's invites; also serves the users FK cascade.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_room_invites_user ON session_room_invites (user_id)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_room_invites_inviter "
        "ON session_room_invites (invited_by) WHERE invited_by IS NOT NULL"
    )
    # At most one ACTIVE room per (session, slot).
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_session_rooms_active_slot "
        "ON session_rooms (session_id, slot) WHERE ended_at IS NULL"
    )
    # Per-session lists, caps and the sweep.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_rooms_session "
        "ON session_rooms (session_id, ended_at)"
    )
    # Per-user create-rate check.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_rooms_creator_created "
        "ON session_rooms (creator_id, created_at) WHERE creator_id IS NOT NULL"
    )
    # Sweep of ended rooms past retention.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_rooms_ended "
        "ON session_rooms (ended_at) WHERE ended_at IS NOT NULL"
    )
    # Live members of a room (caps, presence, auto-delete occupancy).
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_room_members_live "
        "ON session_room_members (room_id, last_seen) WHERE left_at IS NULL"
    )
    # A user's rooms; also serves the users FK cascade.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_room_members_user_all "
        "ON session_room_members (user_id)"
    )
