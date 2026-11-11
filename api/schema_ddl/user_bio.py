"""DDL module ``user_bio`` (task 20261030-user-profiles).

Adds the user-authored bio to ``users``. Nullable TEXT: NULL means "no bio"
(an empty string is normalized to NULL by ``backend.interactions.profile_bio``
before it is ever written). Additive and idempotent; no backfill needed.

The column is deliberately NOT part of ``helpers.load_users_data`` or
``_upsert_user_row``: only the dedicated bio route may write it, and only the
allow-list projections in ``backend.interactions.profile`` may read it for
other users.
"""


def apply(cur) -> None:
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS bio TEXT")
