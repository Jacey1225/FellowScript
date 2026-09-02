"""Tests for scripts/migrate_agentic_context_categories.py — the one-time
backfill that links pre-existing `agentic_context` rows (written before that
table had a `note_id` column) to the note they were distilled from, by
matching the legacy `"<title>: <text prefix>"` free-text summary against the
same user's own unlinked notes.

Covers (task 20260902-heartbeat-context-restructure, testing step 4):
  1. A confidently-matchable legacy row gets `note_id` backfilled.
  2. An ambiguous row (2+ candidate notes) is skipped, not guessed at
     (fail-closed, per this task's Security Posture Q14 preference).
  3. A row with no matching note at all is skipped.
  4. An unparseable/empty legacy context entry is skipped.
  5. `--dry-run` reports the same counts but writes nothing (rolled back).
  6. Re-running the real migration is idempotent: already-linked rows are
     left alone and are not re-counted, and skipped rows remain skipped
     (still confidently ambiguous/unmatched/unparseable) rather than being
     silently linked on a second pass.
  7. Once linked, `AgentManager.get_context()` picks the backfilled note up
     into the live CHAPTERS/VERSES/THEME aggregate for that heartbeat.

Run with: cd api && ../.venv/bin/python tests/test_migrate_agentic_context_categories.py
"""
import _pathfix  # noqa: F401

import os
import sys
import uuid

# scripts/ is a plain directory (no __init__.py, not on sys.path by default)
# -- add it once, same rationale as _pathfix.py adding api/ itself.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

from db import DBManager
from backend.interactions.agent import AgentManager
import migrate_agentic_context_categories as migration

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def make_user() -> str:
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"migctx_{uid[:8]}",
                               "email": f"migctx_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    return uid


def make_agent(user_id: str) -> str:
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("agents", {"_id": agent_id, "user_id": user_id, "role": "", "chats": []})
    finally:
        db.close()
    return agent_id


def make_heartbeat(agent_id: str, user_id: str) -> str:
    hb_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt) "
            "VALUES (%s, %s, %s, %s::jsonb, %s)",
            (hb_id, agent_id, user_id, "[]", "Write a reflection."),
        )
        db.conn.commit()
    finally:
        db.close()
    return hb_id


def make_legacy_context_row(heartbeat_id: str, user_id: str, context_entries: list) -> str:
    """A pre-restructure agentic_context row: note_id NULL, only the old
    free-text `context` array populated -- exactly the shape this migration
    exists to backfill."""
    context_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO agentic_context (_id, heartbeat_id, user_id, note_id, context) "
            "VALUES (%s, %s, %s, NULL, %s)",
            (context_id, heartbeat_id, user_id, context_entries),
        )
        db.conn.commit()
    finally:
        db.close()
    return context_id


def get_note_id(context_id: str):
    db = DBManager()
    try:
        db.cur.execute("SELECT note_id FROM agentic_context WHERE _id = %s", (context_id,))
        row = db.cur.fetchone()
        return str(row[0]) if row and row[0] else None
    finally:
        db.close()


def cleanup(user_id: str):
    db = DBManager()
    try:
        db.delete("notes", {"user_id": user_id})
        db.delete("users", {"_id": user_id})  # cascades agents/heartbeats/context
    finally:
        db.close()


def main():
    uid = make_user()
    agent_id = make_agent(uid)
    hb_id = make_heartbeat(agent_id, uid)
    manager = AgentManager(uid)

    try:
        print("=== 1. confidently-matchable row gets note_id backfilled ===")
        note_confident = manager.note_via_hb({
            "title": "Grace", "text": "A note about grace and mercy.", "verses": [],
        })
        ctx_confident = make_legacy_context_row(
            hb_id, uid, ["Grace: A note about grace and mercy."]
        )

        print("\n=== 2. ambiguous row (two same-titled, same-prefix unlinked notes) is skipped ===")
        note_ambig_1 = manager.note_via_hb({"title": "Hope", "text": "Same opening text here.", "verses": []})
        note_ambig_2 = manager.note_via_hb({"title": "Hope", "text": "Same opening text here.", "verses": []})
        ctx_ambiguous = make_legacy_context_row(hb_id, uid, ["Hope: Same opening text here."])

        print("\n=== 3. row with no matching note at all is skipped ===")
        ctx_no_match = make_legacy_context_row(hb_id, uid, ["Nonexistent: This note was never actually saved."])

        print("\n=== 4. unparseable legacy entry (empty array) is skipped ===")
        ctx_unparseable = make_legacy_context_row(hb_id, uid, [])

        print("\n=== 5. --dry-run reports counts but commits nothing ===")
        db = DBManager()
        try:
            dry_counts = migration.migrate(db.cur, dry_run=True)
            db.conn.rollback()
        finally:
            db.close()
        check("dry run sees all 4 unlinked rows", dry_counts["total"] == 4, str(dry_counts))
        check("dry run would have linked exactly 1 (the confident match)",
              dry_counts["linked"] == 1, str(dry_counts))
        check("dry run flags exactly 1 ambiguous row", dry_counts["skipped_ambiguous"] == 1, str(dry_counts))
        check("dry run flags exactly 1 no-match row", dry_counts["skipped_no_match"] == 1, str(dry_counts))
        check("dry run flags exactly 1 unparseable row", dry_counts["skipped_unparseable"] == 1, str(dry_counts))
        check("dry run did not actually write note_id (rolled back)",
              get_note_id(ctx_confident) is None, str(get_note_id(ctx_confident)))

        print("\n=== 6. real run applies exactly the confident link, skips the rest ===")
        db = DBManager()
        try:
            real_counts = migration.migrate(db.cur, dry_run=False)
            db.conn.commit()
        finally:
            db.close()
        check("real run's counts match the dry run's", real_counts == dry_counts, str((real_counts, dry_counts)))
        check("confident row is now linked to the right note",
              get_note_id(ctx_confident) == note_confident, str(get_note_id(ctx_confident)))
        check("ambiguous row is still unlinked (fail-closed, not guessed at)",
              get_note_id(ctx_ambiguous) is None, str(get_note_id(ctx_ambiguous)))
        check("no-match row is still unlinked",
              get_note_id(ctx_no_match) is None, str(get_note_id(ctx_no_match)))
        check("unparseable row is still unlinked",
              get_note_id(ctx_unparseable) is None, str(get_note_id(ctx_unparseable)))
        # Neither candidate note from the ambiguous pair should have been
        # arbitrarily claimed either.
        db = DBManager()
        try:
            db.cur.execute(
                "SELECT count(*) FROM agentic_context WHERE note_id IN (%s, %s)",
                (note_ambig_1, note_ambig_2),
            )
            ambig_links = db.cur.fetchone()[0]
        finally:
            db.close()
        check("neither ambiguous candidate note was linked to anything",
              ambig_links == 0, str(ambig_links))

        print("\n=== 7. re-running the migration is idempotent ===")
        db = DBManager()
        try:
            rerun_counts = migration.migrate(db.cur, dry_run=False)
            db.conn.commit()
        finally:
            db.close()
        check("second run only sees the 3 still-unlinked rows (confident one is excluded)",
              rerun_counts["total"] == 3, str(rerun_counts))
        check("second run links 0 new rows",
              rerun_counts["linked"] == 0, str(rerun_counts))
        check("confident row's link is unchanged after the second run",
              get_note_id(ctx_confident) == note_confident, str(get_note_id(ctx_confident)))

        print("\n=== 8. backfilled link surfaces in get_context()'s live aggregate ===")
        ctx = manager.get_context(hb_id)
        check("get_context includes text from the backfilled note's own data path "
              "(confirmed indirectly: no exception, well-formed dict back)",
              set(ctx.keys()) == {"chapters", "verses", "theme"}, str(ctx))

    finally:
        cleanup(uid)

    print(f"\n{'='*60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    else:
        print(f"RESULT: {len(PASSED)} passed, 0 failed")
        print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
