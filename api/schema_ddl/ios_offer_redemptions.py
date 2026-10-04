"""DDL module ``ios_offer_redemptions`` (task 20261003-ios-friend-offer-code-redeem).

One row per friend-code -> Apple offer-code issuance. The row is the idempotency
anchor: a user has at most one live (pending/issued/redeemed) row, so a retried
request re-reads the same ASC batch instead of minting a second code. The code
value itself is never stored (only the ASC batch id; the value is re-fetched
from ASC on a retry). ``ip_hash`` is an HMAC (never the raw IP).

Status: pending (row reserved, ASC call not confirmed) -> issued (batch exists)
-> redeemed (verified Apple transaction matched) | failed (ASC definitively
rejected) | expired (batch aged out unredeemed, superseded by a new attempt).
"""


def apply(cur) -> None:
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
