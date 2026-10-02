"""DDL module ``join_requests``: the requesting bucket for Explorer listings.

Owns the ONLY CREATE of ``group_join_requests``. It never alters another
task's table (``group_listings.accepting_requests`` belongs to the listings
module) and has no foreign key to ``group_listings``, so it has no ordering
dependency on that module; it only needs ``groups`` and ``users``.

Foreign keys: ``group_id`` and ``user_id`` cascade (a request dies with its
group or applicant). ``decided_by`` is ``ON DELETE SET NULL`` so deleting the
approver never removes the record; because ``DELETE FROM users`` must then find
the referencing rows, that column gets a partial index (same reasoning as
``threads``).

States: pending / approved / denied / withdrawn / expired. One PENDING request
per (group, applicant) (partial unique index); decided rows stay for the
cooldown and retention windows. ``block_reapply`` is the owner's per-request
"do not let this person ask again". ``owner_notified_at`` is the atomic claim
used to send at most one owner push per notify window.

All statements are idempotent and run inside the boot transaction (the runner
sets ``lock_timeout``), so never ``CREATE INDEX CONCURRENTLY`` here.
"""

_TABLE = """
CREATE TABLE IF NOT EXISTS group_join_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID NOT NULL REFERENCES groups(_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'denied', 'withdrawn', 'expired')),
    note TEXT,
    block_reapply BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decided_at TIMESTAMPTZ,
    decided_by UUID REFERENCES users(_id) ON DELETE SET NULL,
    owner_notified_at TIMESTAMPTZ
)
"""


def apply(cur) -> None:
    cur.execute(_TABLE)
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_group_join_requests_pending "
        "ON group_join_requests (group_id, user_id) WHERE status = 'pending'"
    )
    # Owner list and per-group pending cap.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_group_join_requests_group_status "
        "ON group_join_requests (group_id, status, created_at)"
    )
    # Per-user caps, daily cap and "my requests".
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_group_join_requests_user_created "
        "ON group_join_requests (user_id, created_at)"
    )
    # Cooldown / block_reapply lookup for one (group, applicant) pair.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_group_join_requests_pair "
        "ON group_join_requests (group_id, user_id, created_at DESC)"
    )
    # Sweeper: pending past expiry and decided rows past retention.
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_group_join_requests_status_created "
        "ON group_join_requests (status, created_at)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_group_join_requests_decided_by "
        "ON group_join_requests (decided_by) WHERE decided_by IS NOT NULL"
    )
