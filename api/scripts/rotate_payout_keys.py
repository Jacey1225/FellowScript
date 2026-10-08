"""Re-encrypt affiliate payout details under the CURRENT payout key
(task 20261008-affiliate-payout-details). Idempotent: rows already on the current
key are skipped. Prints counts only, never values.

Procedure: prepend '<new id>:<new base64 key>' to PAYOUT_ENCRYPTION_KEYS (keep the
old entries), restart, run this script, confirm it reports 0 rows on old key ids,
then remove the retired entries and restart again.

Run: cd api && ../.venv/bin/python scripts/rotate_payout_keys.py [--dry-run]
"""
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from db import DBManager  # noqa: E402
from backend.subscription import payout_crypto  # noqa: E402

COLS = (("routing_enc", "routing"), ("account_enc", "account"), ("holder_enc", "holder"), ("type_enc", "type"))


def main(dry_run: bool) -> int:
    payout_crypto.validate_payout_keys()
    cur_id = payout_crypto.current_key_id()
    db = DBManager()
    seen, rotated = Counter(), 0
    try:
        db.cur.execute("SELECT owner_email, row_id, routing_enc, account_enc, holder_enc, type_enc "
                       "FROM affiliate_payout_details FOR UPDATE")
        for owner, rid, *encs in db.cur.fetchall():
            ids = [payout_crypto.key_id_of(e) for e in encs]
            seen.update(ids)
            if all(i == cur_id for i in ids):
                continue
            new = [payout_crypto.encrypt(payout_crypto.decrypt(e, str(rid), f), str(rid), f)
                   for e, (_, f) in zip(encs, COLS)]
            if not dry_run:
                db.cur.execute(
                    "UPDATE affiliate_payout_details SET routing_enc=%s, account_enc=%s, holder_enc=%s, type_enc=%s "
                    "WHERE owner_email=%s", (*new, owner))
            rotated += 1
        if not dry_run:
            db.cur.execute("INSERT INTO affiliate_payout_audit (event_type, actor_id, subject, reason) "
                           "VALUES ('key_rotation','cli',NULL,%s)", (f"rows={rotated} current_key={cur_id}",))
            db.conn.commit()
        else:
            db.conn.rollback()
    finally:
        db.close()
    print(f"current key id: {cur_id}; field counts by key id: {dict(seen)}; rows re-encrypted: {rotated}"
          + (" (dry run)" if dry_run else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main("--dry-run" in sys.argv))
