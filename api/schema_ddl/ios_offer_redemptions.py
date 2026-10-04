"""DDL module ``ios_offer_redemptions`` (task 20261003-ios-friend-offer-code-redeem).

Apple only allows one-time-use offer-code batches of 500-25,000 codes, so codes
come from a POOL: ``ios_offer_batches`` holds one row per ASC batch (batch id,
size, expiry, and ``next_index``, the count of codes already handed out). A code
VALUE is never stored: to issue, the server reads the batch's values from ASC and
takes the code at the reserved index.

``ios_offer_redemptions`` is one row per friend-code -> Apple offer-code issuance
and the idempotency anchor: a user has at most one live (pending/issued/redeemed)
row, and that row owns exactly one (batch_id, code_index) (unique), so a retry
re-reads the SAME index and never takes a second one. ``ip_hash`` is an HMAC
(never the raw IP).

Redemption status: issued (index reserved) -> redeemed (verified Apple
transaction matched) | expired (batch aged out unredeemed, superseded by a new
attempt) | failed. ``pending`` is legacy from the abandoned single-code design
and is closed as failed if found.
Batch status: pending (create sent, outcome unknown) -> active | failed.
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS ios_offer_batches"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "asc_batch_id TEXT,"
        "status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','failed')),"
        "number_of_codes INTEGER NOT NULL CHECK (number_of_codes BETWEEN 500 AND 25000),"
        "next_index INTEGER NOT NULL DEFAULT 0 CHECK (next_index >= 0 AND next_index <= number_of_codes),"
        "expires_at TIMESTAMPTZ NOT NULL,"
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "ready_at TIMESTAMPTZ)"
    )
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_ios_offer_batches_asc "
        "ON ios_offer_batches(asc_batch_id) WHERE asc_batch_id IS NOT NULL"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS ios_offer_redemptions"
        "(_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id UUID REFERENCES users(_id) ON DELETE SET NULL,"
        "code_id UUID REFERENCES promo_codes(_id) ON DELETE SET NULL,"
        "referrer_user_id UUID REFERENCES users(_id) ON DELETE SET NULL,"
        "status TEXT NOT NULL DEFAULT 'pending' "
        "CHECK (status IN ('pending','issued','redeemed','failed','expired')),"
        "asc_batch_id TEXT,"
        "ip_hash TEXT,"
        "expires_at TIMESTAMPTZ,"
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "issued_at TIMESTAMPTZ,"
        "redeemed_at TIMESTAMPTZ,"
        "apple_transaction_id TEXT)"
    )
    # At most one live row per user: the idempotency / no-duplicate-mint guard.
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_ios_offer_redemptions_user_live "
        "ON ios_offer_redemptions(user_id) WHERE status IN ('pending','issued','redeemed')"
    )
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_ios_offer_redemptions_txn "
        "ON ios_offer_redemptions(apple_transaction_id) WHERE apple_transaction_id IS NOT NULL"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_ios_offer_redemptions_ip "
        "ON ios_offer_redemptions(ip_hash, created_at)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_ios_offer_redemptions_code "
        "ON ios_offer_redemptions(code_id, status)"
    )
    # Pool columns (added after the first design; idempotent for existing tables).
    cur.execute("ALTER TABLE ios_offer_redemptions ADD COLUMN IF NOT EXISTS "
                "batch_id UUID REFERENCES ios_offer_batches(_id) ON DELETE SET NULL")
    cur.execute("ALTER TABLE ios_offer_redemptions ADD COLUMN IF NOT EXISTS code_index INTEGER")
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_ios_offer_redemptions_batch_index "
        "ON ios_offer_redemptions(batch_id, code_index) WHERE batch_id IS NOT NULL"
    )
