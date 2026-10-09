"""Re-encrypt content under the CURRENT content key
(task 20261008-content-encryption-at-rest). Idempotent: values already on the
current key are skipped. Prints counts only, never content.

Procedure: prepend '<new id>:<new base64 key>' to CONTENT_ENCRYPTION_KEYS (keep
the old entries), restart, run this script, confirm it reports 0 values left on
old key ids, then remove the retired entries and restart again. Take a backup
first, exactly as for the backfill.

Dry run by default. Run (from api/):
    ../.venv/bin/python scripts/rotate_content_keys.py [--target primary|backup]
    ../.venv/bin/python scripts/rotate_content_keys.py --apply --backup-confirmed "<label>"

This is a thin wrapper over ``backend.maintenance.content_migrate --mode rotate``.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from backend.maintenance import content_migrate  # noqa: E402

if __name__ == "__main__":
    sys.exit(content_migrate.main(["--mode", "rotate", *sys.argv[1:]]))
