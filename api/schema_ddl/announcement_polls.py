"""DDL module ``announcement_polls``: one optional poll per group announcement.

Idempotent (CREATE ... IF NOT EXISTS only). Depends on ``group_announcements``
and ``users`` (created before DDL modules run).

* ``group_announcement_polls``: one row per announcement (PK = the announcement).
* ``group_announcement_poll_options``: 2-6 ordered options per poll.
* ``group_announcement_poll_votes``: one row per (option, user). Single-choice
  is enforced in the API layer under a row lock on the poll, not by a
  constraint, because a poll may allow several answers.
Everything cascades with the announcement; a vote cascades with its user.
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS group_announcement_polls ("
        "announcement_id UUID PRIMARY KEY REFERENCES group_announcements(_id) ON DELETE CASCADE, "
        "question TEXT NOT NULL, "
        "multiple BOOLEAN NOT NULL DEFAULT FALSE, "
        "closes_at TIMESTAMPTZ, "
        "closed_at TIMESTAMPTZ, "
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS group_announcement_poll_options ("
        "_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), "
        "announcement_id UUID NOT NULL REFERENCES group_announcement_polls(announcement_id) ON DELETE CASCADE, "
        "position SMALLINT NOT NULL, "
        "label TEXT NOT NULL, "
        "UNIQUE (announcement_id, position))"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS group_announcement_poll_votes ("
        "option_id UUID NOT NULL REFERENCES group_announcement_poll_options(_id) ON DELETE CASCADE, "
        "announcement_id UUID NOT NULL REFERENCES group_announcement_polls(announcement_id) ON DELETE CASCADE, "
        "user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE, "
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), "
        "PRIMARY KEY (option_id, user_id))"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_poll_votes_announcement_user "
        "ON group_announcement_poll_votes (announcement_id, user_id)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_poll_votes_user ON group_announcement_poll_votes (user_id)"
    )
