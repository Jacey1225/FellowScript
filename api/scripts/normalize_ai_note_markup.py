"""One-off cleanup (PROPOSED, never run by the pipeline): rewrite existing AI session-summary
notes that still carry literal markdown markers into editor-safe markup
(task 20261104-ai-note-format-normalizer). See cleanup-assessment.md in the task directory.

Selection (conservative): notes.summary_dedupe_key IS NOT NULL (session summaries written
by the fan-out path), whose text contains NO '<' (never touch anything the editor already
saved as HTML, which is also the main user-edit guard) and contains a markdown marker
(**, __, a line-start '#', '*' or '_' emphasis, backtick, '](' ). Everything else is left alone.
Heartbeat notes and summaries written before the dedupe key existed have no reliable marker and
are NOT selected.

Dry run by default: counts only, nothing printed from note content. Writing needs
``--apply --backup-confirmed "<label>" --rollback-file <path>``. The rollback file receives
one JSON line per rewritten note ({id, field, old, new}) and contains note text: keep it
private (created 0600), and delete it after the retention window.

Run from api/ (operator, after a verified DB backup):
    ../.venv/bin/python scripts/normalize_ai_note_markup.py
    ../.venv/bin/python scripts/normalize_ai_note_markup.py --apply \
        --backup-confirmed "<label>" --rollback-file /secure/path/rollback.jsonl
Rollback: ../.venv/bin/python scripts/normalize_ai_note_markup.py --rollback /secure/path/rollback.jsonl
(dry run) then add --apply --backup-confirmed "<label>".
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from backend import content_store  # noqa: E402
from backend.interactions.note_markup import NoteMarkupError, normalize_note_markup  # noqa: E402

_MARKER_RE = re.compile(r"\*\*|__|`|\]\(|(?m:^[ \t]{0,3}#{1,6}[ \t])|(?<![\w*])\*[^\s*]|(?<![\w_])_[^\s_]")
_FIELD = content_store.F_NOTE_TEXT
_SELECT = (
    "SELECT _id, text FROM notes WHERE summary_dedupe_key IS NOT NULL "
    "AND (%s::uuid IS NULL OR _id > %s::uuid) ORDER BY _id LIMIT %s"
)


def _is_candidate(text: str) -> bool:
    return bool(text) and "<" not in text and bool(_MARKER_RE.search(text))


def _rewrite(db, note_id, stored_old, new_plain, apply) -> str:
    """Compare-and-set one note. Returns 'changed' | 'raced'."""
    if not apply:
        return "changed"
    db.cur.execute(
        "UPDATE notes SET text = %s WHERE _id = %s AND text = %s",
        (content_store.seal(note_id, _FIELD, new_plain), note_id, stored_old),
    )
    ok = db.cur.rowcount == 1
    db.conn.commit()
    return "changed" if ok else "raced"


def run_cleanup(db, *, apply, rollback_path, batch_size=200, max_rows=None) -> dict:
    counts = dict(scanned=0, candidates=0, changed=0, skipped_has_tags_or_clean=0, failed=0, raced=0)
    last = None
    rb = None
    if apply:
        fd = os.open(rollback_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        rb = os.fdopen(fd, "a")
    try:
        while True:
            db.cur.execute(_SELECT, (last, last, batch_size))
            rows = db.cur.fetchall()
            if not rows:
                break
            for note_id, stored in rows:
                last = str(note_id)
                counts["scanned"] += 1
                try:
                    plain = content_store.open_(note_id, _FIELD, stored)
                except Exception:  # noqa: BLE001 - undecryptable rows are counted, never overwritten
                    counts["failed"] += 1
                    print(f"decrypt failed: notes._id={note_id}", file=sys.stderr)
                    continue
                if not _is_candidate(plain):
                    counts["skipped_has_tags_or_clean"] += 1
                    continue
                counts["candidates"] += 1
                try:
                    new = normalize_note_markup(plain)
                except NoteMarkupError:
                    counts["failed"] += 1
                    print(f"normalize failed: notes._id={note_id}", file=sys.stderr)
                    continue
                if rb:
                    rb.write(json.dumps({"id": last, "field": _FIELD, "old": plain, "new": new}) + "\n")
                    rb.flush()
                counts[_rewrite(db, note_id, stored, new, apply)] += 1
            if max_rows and counts["scanned"] >= max_rows:
                break
    finally:
        if rb:
            rb.close()
    return counts


def run_rollback(db, path, *, apply) -> dict:
    counts = dict(read=0, restored=0, raced=0, failed=0)
    with open(path) as f:
        for line in f:
            rec = json.loads(line)
            counts["read"] += 1
            db.cur.execute("SELECT text FROM notes WHERE _id = %s", (rec["id"],))
            row = db.cur.fetchone()
            try:
                current = content_store.open_(rec["id"], _FIELD, row[0]) if row else None
            except Exception:  # noqa: BLE001
                current = None
            if current != rec["new"]:  # edited since the cleanup (or gone): leave it
                counts["raced"] += 1
                continue
            if apply:
                db.cur.execute(
                    "UPDATE notes SET text = %s WHERE _id = %s AND text = %s",
                    (content_store.seal(rec["id"], _FIELD, rec["old"]), rec["id"], row[0]),
                )
                db.conn.commit()
            counts["restored"] += 1
    return counts


def main(argv=None, *, connect=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apply", action="store_true", help="write changes (default: dry run, counts only)")
    p.add_argument("--backup-confirmed", metavar="LABEL", help="label of the verified backup; required with --apply")
    p.add_argument("--rollback-file", help="JSONL of old/new text; required with --apply")
    p.add_argument("--rollback", metavar="FILE", help="restore old text from a rollback file (dry run unless --apply)")
    p.add_argument("--batch-size", type=int, default=200)
    p.add_argument("--max-rows", type=int)
    args = p.parse_args(argv)
    if args.apply and not args.backup_confirmed:
        print("--apply requires --backup-confirmed '<label of the verified backup>'", file=sys.stderr)
        return 2
    if args.apply and not args.rollback and not args.rollback_file:
        print("--apply requires --rollback-file <path>", file=sys.stderr)
        return 2
    if connect is None:
        from backend import content_crypto
        from db import DBManager
        content_crypto.validate_content_keys()
        connect = DBManager
    db = connect()
    try:
        if args.rollback:
            counts = run_rollback(db, args.rollback, apply=args.apply)
        else:
            counts = run_cleanup(db, apply=args.apply, rollback_path=args.rollback_file,
                                 batch_size=args.batch_size, max_rows=args.max_rows)
    finally:
        db.close()
    print(("APPLY " if args.apply else "DRY-RUN ") + " ".join(f"{k}={v}" for k, v in counts.items()))
    return 1 if counts.get("failed") else 0


if __name__ == "__main__":
    sys.exit(main())
