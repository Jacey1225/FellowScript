"""DDL module ``affiliate_payouts`` (task 20261008-affiliate-payout-details).

Three tables, all idempotent (``CREATE TABLE IF NOT EXISTS``):

* ``affiliate_payout_details``  one row per affiliate (lowercased creator-code
  owner email). Bank fields are AES-256-GCM ciphertext (see
  ``backend/subscription/payout_crypto.py``); only the two last-4 digit strings
  are plaintext. ``row_id`` is the random id bound into each field's AAD, so a
  ciphertext cannot be moved between rows or fields (and an account email change
  cannot break decryption).
* ``affiliate_payout_proofs``  emailed re-auth codes and the single-use proof
  minted after a successful re-auth. Only hashes are stored. ``purpose`` keeps a
  write proof from satisfying an admin reveal and vice versa.
* ``affiliate_payout_audit``  append-only, value-free. Deliberately no foreign
  keys and no cascade: deleting a payout row, user or affiliate never touches it.
  Convention: the app role is only ever INSERTed into / SELECTed from here.
"""


def apply(cur) -> None:
    cur.execute(
        "CREATE TABLE IF NOT EXISTS affiliate_payout_details("
        "owner_email TEXT PRIMARY KEY CHECK (owner_email = LOWER(owner_email)),"
        "row_id UUID NOT NULL DEFAULT gen_random_uuid(),"
        "routing_enc TEXT NOT NULL,"
        "account_enc TEXT NOT NULL,"
        "holder_enc TEXT NOT NULL,"
        "type_enc TEXT NOT NULL,"
        "routing_last4 CHAR(4) NOT NULL CHECK (routing_last4 ~ '^[0-9]{4}$'),"
        "account_last4 CHAR(4) NOT NULL CHECK (account_last4 ~ '^[0-9]{4}$'),"
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
        "updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS affiliate_payout_proofs("
        "id UUID PRIMARY KEY DEFAULT gen_random_uuid(),"
        "user_id TEXT NOT NULL,"
        "purpose TEXT NOT NULL CHECK (purpose IN ('payout_write','payout_admin_reveal')),"
        "code_hash TEXT NOT NULL,"
        "code_expires_at TIMESTAMPTZ NOT NULL,"
        "attempts INTEGER NOT NULL DEFAULT 0,"
        "token_hash TEXT,"
        "proof_expires_at TIMESTAMPTZ,"
        "used BOOLEAN NOT NULL DEFAULT FALSE,"
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS affiliate_payout_proofs_user_idx "
        "ON affiliate_payout_proofs (user_id, purpose, created_at)"
    )
    cur.execute(
        "CREATE TABLE IF NOT EXISTS affiliate_payout_audit("
        "id BIGSERIAL PRIMARY KEY,"
        "event_type TEXT NOT NULL CHECK (event_type IN "
        "('create','update','delete','reveal','reauth_failed','retention_purge','key_rotation')),"
        "actor_id TEXT,"
        "subject TEXT,"
        "ip TEXT,"
        "user_agent TEXT,"
        "reason TEXT,"
        "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    )
    cur.execute(
        "CREATE INDEX IF NOT EXISTS affiliate_payout_audit_actor_idx "
        "ON affiliate_payout_audit (actor_id, event_type, created_at)"
    )
