"""PROPOSED later step: reclaim the plaintext that survives a content backfill
(task 20261008-content-encryption-at-rest). NOT part of the deploy and NOT run by
the pipeline.

After ``content_migrate --mode encrypt --apply`` every stored value is
ciphertext, but the OLD plaintext still exists physically as dead tuples (and in
TOAST) until the table is rewritten, and in any pre-backfill backup. This step
rewrites the affected tables so the dead tuples are gone:

    docker exec fellowscript-api python -m backend.maintenance.content_reclaim            # prints the plan
    docker exec fellowscript-api python -m backend.maintenance.content_reclaim --apply --i-understand-exclusive-lock

``VACUUM FULL`` takes an ACCESS EXCLUSIVE lock per table and needs free disk of
about the table's size: run it in a maintenance window, one table at a time. It
does not touch old pg_dump files, WAL archives or snapshots: expiring those is the
operator's separate decision (see the runbook). The default prints the plan only.
"""
from __future__ import annotations

import argparse
import sys

from backend import content_store


def plan() -> list[str]:
    return [f"VACUUM (FULL, ANALYZE) {t}" for t in sorted(content_store.TABLE_COLUMNS)] + [
        "-- backup database: VACUUM (FULL, ANALYZE) notes   (after the backup copy has been re-synced)",
    ]


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apply", action="store_true")
    p.add_argument("--i-understand-exclusive-lock", action="store_true")
    args = p.parse_args(argv)
    print("Reclaim plan (primary database):")
    for line in plan():
        print("  " + line)
    if not args.apply:
        print("Dry run: nothing executed. Re-run with --apply --i-understand-exclusive-lock to execute.")
        return 0
    if not args.i_understand_exclusive_lock:
        print("--apply also requires --i-understand-exclusive-lock", file=sys.stderr)
        return 2
    from db import DBManager

    db = DBManager()
    try:
        db.conn.autocommit = True  # VACUUM cannot run inside a transaction
        for table in sorted(content_store.TABLE_COLUMNS):
            db.cur.execute(f"VACUUM (FULL, ANALYZE) {table}")
            print(f"vacuumed {table}")
    finally:
        db.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
