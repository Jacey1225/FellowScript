"""DDL module ``email_verification`` (task 20261007-email-verification).

Additive and idempotent. ``users.email_verified`` defaults FALSE for every row
(no backfill: existing accounts verify lazily, only where an email-linked
privilege needs it). ``email_verified_hash`` binds the verified state to the
exact (lowercased) address that was verified, so a later email change can never
silently inherit "verified" even if some path forgets to reset the flag.

``email_verification_tokens`` stores only the sha256 of the emailed token and
the sha256 of the address it was issued for (never the raw email).
"""


def apply(cur) -> None:
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT FALSE")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMPTZ")
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_hash VARCHAR(64)")
    cur.execute(
        "CREATE TABLE IF NOT EXISTS email_verification_tokens("
        "_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id UUID NOT NULL REFERENCES users(_id) ON DELETE CASCADE,"
        "token_hash VARCHAR(64) NOT NULL,"
        "email_hash VARCHAR(64) NOT NULL,"
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "expires_at TIMESTAMPTZ NOT NULL,"
        "used BOOLEAN NOT NULL DEFAULT FALSE)"
    )
    cur.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_email_verification_token_hash "
        "ON email_verification_tokens(token_hash)"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS idx_email_verification_user "
        "ON email_verification_tokens(user_id, created_at)"
    )
