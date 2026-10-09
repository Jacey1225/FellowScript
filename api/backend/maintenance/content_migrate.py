"""Backfill / reverse / key-rotation engine for content encryption at rest
(task 20261008-content-encryption-at-rest).

NEVER run automatically and NEVER by the build pipeline. The operator runs it
after the runbook's backup step (docs/architecture/backend.md, "Content
encryption at rest"):

    docker exec fellowscript-api python -m backend.maintenance.content_migrate \\
        --mode encrypt --target primary                       # dry run, counts only
    docker exec fellowscript-api python -m backend.maintenance.content_migrate \\
        --mode encrypt --target primary --apply --backup-confirmed "<backup label>"

Modes
  encrypt  plaintext -> ``enc:v1:`` ciphertext under the CURRENT key (the backfill)
  decrypt  ciphertext -> plaintext (the scripted ROLLBACK; needs the key ring)
  rotate   ciphertext under an older key id -> current key id

Safety properties (each is covered by a test):
- DRY RUN by default: ``--apply`` is required to write, and ``--apply`` also
  requires ``--backup-confirmed <label>`` (recorded in the audit row).
- Idempotent and resumable: only rows still in the wrong form are changed; a
  keyset cursor (``_id``) is checkpointed after every committed batch
  (``--resume``); a re-run after a kill re-scans from the checkpoint and is safe.
- Batched and throttled: ``backfill_batch_size`` rows per transaction, sleeping
  ``backfill_throttle_ms`` between batches; each batch sets transaction-local
  ``statement_timeout`` and ``lock_timeout`` (config/content_encryption.json).
- Verify before commit: each new value is decrypted and compared to the source
  text in memory, written with a compare-and-set (``WHERE col = <old value>``, so
  a concurrent edit wins and the row is retried by the next run), then READ BACK
  and compared again inside the same transaction. Any mismatch rolls the whole
  batch back and aborts the run; a stored value is never replaced by something
  that did not verify.
- Fail closed: an existing ciphertext that cannot be authenticated is counted as
  ``failed`` and left untouched (never overwritten, never treated as plaintext).
- Counts only: nothing here prints or logs row content; failures name table,
  column and row id.
- Audit: one ``content_encryption_audit`` row per table per run (counts,
  timestamps, backup label, actor) plus a JSON-lines file next to the checkpoint.

Because the stored value is replaced in place, "verify-before-null" here means
verify-before-replace; the pre-backfill plaintext survives only in the operator's
backup and in dead tuples until the separate, later reclaim step
(``backend.maintenance.content_reclaim``).
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone

from backend import content_crypto, content_store
from backend.content_config import get_content_config

logger = logging.getLogger(__name__)

MODES = ("encrypt", "decrypt", "rotate")
TARGETS = ("primary", "backup")

# What each database holds. The backup database only mirrors notes title/text.
BACKUP_TABLES: dict[str, dict[str, str]] = {
    "notes": {
        "title": content_store.F_NOTE_TITLE,
        "text": content_store.F_NOTE_TEXT,
    },
}


class MigrationVerifyError(RuntimeError):
    """A verification step failed; the batch was rolled back. Names ids only."""


@dataclass
class Counts:
    table: str
    scanned: int = 0          # rows read
    changed: int = 0          # values written (or that WOULD be written in a dry run)
    already: int = 0          # values already in the target form
    empty: int = 0            # NULL / '' values (nothing to protect)
    failed: int = 0           # ciphertext that could not be authenticated (left untouched)
    raced: int = 0            # row changed under us; the next run picks it up
    batches: int = 0
    last_id: str | None = None
    failures: list[str] = field(default_factory=list)  # "<column>:<row id>" only


def tables_for(target: str) -> dict[str, dict[str, str]]:
    return BACKUP_TABLES if target == "backup" else content_store.TABLE_COLUMNS


def _existing_columns(cur, table: str, wanted: dict[str, str]) -> dict[str, str]:
    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = current_schema() AND table_name = %s",
        (table,),
    )
    have = {r[0] for r in cur.fetchall()}
    return {c: f for c, f in wanted.items() if c in have}


def _new_value(mode: str, rid: str, fld: str, stored: str, current_kid: int | None) -> tuple[str | None, str | None]:
    """(new stored value or None for "leave", plaintext it must decrypt back to).

    Raises ContentDecryptError for an existing ciphertext that fails to authenticate.
    """
    if mode == "encrypt":
        if content_crypto.is_ciphertext(stored):
            content_crypto.decrypt_field(rid, fld, stored)  # authenticates or raises
            return None, None
        plain = content_crypto.open_value(rid, fld, stored)  # what readers see today
        return content_crypto.encrypt_field(rid, fld, plain), plain
    if mode == "decrypt":
        if not content_crypto.is_ciphertext(stored):
            return None, None
        plain = content_crypto.decrypt_field(rid, fld, stored)
        return content_crypto.escape_plain(plain), plain
    # rotate
    if not content_crypto.is_ciphertext(stored):
        return None, None
    plain = content_crypto.decrypt_field(rid, fld, stored)
    if content_crypto.key_id_of(stored) == current_kid:
        return None, None
    return content_crypto.encrypt_field(rid, fld, plain), plain


def migrate_table(
    db,
    table: str,
    columns: dict[str, str],
    mode: str,
    *,
    apply: bool,
    batch_size: int,
    throttle_ms: int = 0,
    statement_timeout_ms: int = 15000,
    lock_timeout_ms: int = 3000,
    start_after: str | None = None,
    max_rows: int | None = None,
    on_batch_committed=None,
    sleep=time.sleep,
) -> Counts:
    """Process one table. ``db`` is a DBManager (autocommit off). Returns counts."""
    assert mode in MODES
    counts = Counts(table=table)
    cur, conn = db.cur, db.conn
    columns = _existing_columns(cur, table, columns)
    conn.rollback()
    if not columns:
        return counts
    cols = list(columns)
    col_sql = ", ".join(cols)
    current_kid = content_crypto.current_key_id() if mode == "rotate" else None
    last = start_after
    while True:
        limit = batch_size if max_rows is None else min(batch_size, max_rows - counts.scanned)
        if limit <= 0:
            break
        try:
            cur.execute("SELECT set_config('statement_timeout', %s, true)", (str(statement_timeout_ms),))
            cur.execute("SELECT set_config('lock_timeout', %s, true)", (str(lock_timeout_ms),))
            if last is None:
                cur.execute(f"SELECT _id::text, {col_sql} FROM {table} ORDER BY _id LIMIT %s", (limit,))
            else:
                cur.execute(
                    f"SELECT _id::text, {col_sql} FROM {table} WHERE _id > %s::uuid ORDER BY _id LIMIT %s",
                    (last, limit),
                )
            rows = cur.fetchall()
            if not rows:
                conn.rollback()
                break
            written: list[tuple[str, str, str, str]] = []  # (rid, col, field, expected plaintext)
            for row in rows:
                rid = row[0]
                counts.scanned += 1
                for col, stored in zip(cols, row[1:]):
                    if stored is None or stored == "":
                        counts.empty += 1
                        continue
                    fld = columns[col]
                    try:
                        new, plain = _new_value(mode, rid, fld, stored, current_kid)
                    except content_crypto.ContentDecryptError:
                        counts.failed += 1
                        counts.failures.append(f"{col}:{rid}")
                        continue
                    if new is None:
                        counts.already += 1
                        continue
                    # In-memory verify before anything is written.
                    if content_crypto.open_value(rid, fld, new) != plain:
                        raise MigrationVerifyError(f"pre-write verify failed table={table} col={col} row={rid}")
                    if not apply:
                        counts.changed += 1
                        continue
                    cur.execute(
                        f"UPDATE {table} SET {col} = %s WHERE _id = %s::uuid AND {col} = %s",
                        (new, rid, stored),
                    )
                    if cur.rowcount != 1:
                        counts.raced += 1
                        continue
                    counts.changed += 1
                    written.append((rid, col, fld, plain))
            # Read back inside the same transaction before committing.
            for rid, col, fld, plain in written:
                cur.execute(f"SELECT {col} FROM {table} WHERE _id = %s::uuid", (rid,))
                back = cur.fetchone()
                ok = False
                if back is not None and isinstance(back[0], str):
                    try:
                        ok = content_crypto.open_value(rid, fld, back[0]) == plain
                    except content_crypto.ContentDecryptError:
                        ok = False
                if not ok:
                    raise MigrationVerifyError(f"read-back verify failed table={table} col={col} row={rid}")
            if apply:
                conn.commit()
            else:
                conn.rollback()
        except Exception:
            conn.rollback()
            raise
        counts.batches += 1
        last = rows[-1][0]
        counts.last_id = last
        if apply and on_batch_committed is not None:
            on_batch_committed(table, last)
        if len(rows) < limit:
            break
        if throttle_ms:
            sleep(throttle_ms / 1000.0)
    return counts


# -- audit + checkpoint -------------------------------------------------------

def write_audit(db, *, run_id: str, mode: str, target: str, apply: bool, backup_label: str | None,
                counts: Counts, started_at: datetime, actor: str) -> None:
    db.cur.execute(
        "INSERT INTO content_encryption_audit "
        "(run_id, mode, target, applied, backup_label, table_name, rows_scanned, values_changed, values_already, "
        "values_failed, values_raced, started_at, finished_at, actor) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,NOW(),%s)",
        (run_id, mode, target, apply, backup_label, counts.table, counts.scanned, counts.changed,
         counts.already, counts.failed, counts.raced, started_at, actor),
    )
    db.conn.commit()


def _load_checkpoint(path: str | None) -> dict:
    if not path or not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def _save_checkpoint(path: str | None, data: dict) -> None:
    if not path:
        return
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def run(args, *, connect=None, sleep=time.sleep) -> int:
    """CLI body. ``connect(dbname_or_None) -> DBManager`` is injectable for tests."""
    from db import BACKUP_DB_NAME, DBManager

    connect = connect or (lambda name: DBManager(dbname=name) if name else DBManager())
    content_crypto.validate_content_keys()
    cfg = get_content_config()
    apply = bool(args.apply)
    if apply and not args.backup_confirmed:
        print("--apply requires --backup-confirmed '<label of the verified backup>'", file=sys.stderr)
        return 2
    wanted = tables_for(args.target)
    only = set(args.tables.split(",")) if args.tables else None
    if only and not only <= set(wanted):
        print(f"unknown table(s) for target {args.target}: {sorted(only - set(wanted))}", file=sys.stderr)
        return 2
    run_id = str(uuid.uuid4())
    started = datetime.now(timezone.utc)
    ckpt = _load_checkpoint(args.checkpoint) if args.resume else {}
    ckpt_key = lambda t: f"{args.target}:{args.mode}:{t}"  # noqa: E731
    audit_db = connect(None)
    data_db = connect(BACKUP_DB_NAME if args.target == "backup" else None)
    exit_code = 0
    try:
        for table, columns in wanted.items():
            if only and table not in only:
                continue

            def on_batch(t, last_id, _t=table):
                ckpt[ckpt_key(_t)] = last_id
                _save_checkpoint(args.checkpoint, ckpt)

            counts = migrate_table(
                data_db, table, columns, args.mode, apply=apply,
                batch_size=args.batch_size or cfg.backfill_batch_size,
                throttle_ms=cfg.backfill_throttle_ms if args.throttle_ms is None else args.throttle_ms,
                statement_timeout_ms=cfg.backfill_statement_timeout_ms,
                lock_timeout_ms=cfg.backfill_lock_timeout_ms,
                start_after=ckpt.get(ckpt_key(table)) if args.resume else None,
                max_rows=args.max_rows, on_batch_committed=on_batch, sleep=sleep,
            )
            if counts.failed:
                exit_code = 1
            print(
                f"{args.target}.{table}: mode={args.mode} {'APPLY' if apply else 'DRY-RUN'} "
                f"scanned={counts.scanned} changed={counts.changed} already={counts.already} "
                f"empty={counts.empty} failed={counts.failed} raced={counts.raced} batches={counts.batches}"
                + (f" failures={counts.failures[:20]}" if counts.failures else "")
            )
            if apply:
                write_audit(audit_db, run_id=run_id, mode=args.mode, target=args.target, apply=apply,
                            backup_label=args.backup_confirmed, counts=counts, started_at=started,
                            actor=args.actor)
                if args.checkpoint:
                    with open(args.checkpoint + ".audit.jsonl", "a") as f:
                        f.write(json.dumps({"run_id": run_id, "mode": args.mode, "target": args.target,
                                            "backup_label": args.backup_confirmed, **asdict(counts),
                                            "failures": counts.failures[:100]}) + "\n")
    finally:
        data_db.close()
        audit_db.close()
    return exit_code


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=MODES, required=True)
    p.add_argument("--target", choices=TARGETS, default="primary")
    p.add_argument("--tables", help="comma-separated subset of tables")
    p.add_argument("--apply", action="store_true", help="write changes (default: dry run, counts only)")
    p.add_argument("--backup-confirmed", metavar="LABEL", help="label of the verified backup; required with --apply")
    p.add_argument("--resume", action="store_true", help="continue from the checkpoint file")
    p.add_argument("--checkpoint", default="content_migrate.checkpoint.json")
    p.add_argument("--batch-size", type=int)
    p.add_argument("--throttle-ms", type=int)
    p.add_argument("--max-rows", type=int, help="stop each table after this many rows (smoke runs)")
    p.add_argument("--actor", default=os.environ.get("USER", "cli"))
    return p


def main(argv=None) -> int:
    return run(build_parser().parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
