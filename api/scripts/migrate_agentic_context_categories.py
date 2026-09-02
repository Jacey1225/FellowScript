"""One-time backfill for the CHAPTERS/VERSES/THEME heartbeat-context
restructure (.claude/pipeline/20260902-heartbeat-context-restructure).

Background: AgentManager.get_context() used to read a free-text summary
straight out of agentic_context.context (a TEXT[] column). It now instead
recomputes CHAPTERS/VERSES/THEME live from notes + note_verses + the new
notes.theme column, joined through agentic_context.note_id -- see
get_context()'s docstring in backend/interactions/agent.py. CHAPTERS and
VERSES come purely from existing note_verses rows (no LLM cost); THEME
comes from notes.theme, which only heartbeat-generated notes created
*after* this restructure ships will ever have populated.

That live join only works for agentic_context rows that already have
note_id set. Most do -- note_id has been populated on every INSERT since
the column was added (see db.py's comment on the agentic_context table)
-- but any row written before that column existed has note_id = NULL and
only the old free-text `context` summary to go on. Those rows would
otherwise silently vanish from a heartbeat's context the moment
get_context() switched to the join-based read, even though the note
itself and its note_verses rows are all still sitting in the database.

This script finds every note_id-less agentic_context row and tries to
recover which note it was distilled from, by matching the legacy
"<title>: <text prefix>" summary format _generate_and_save_note used to
write (see the removed `note_summary` line in agent.py) against that same
user's own unlinked notes -- both the exact title AND the exact
(up to 300 char) text prefix must match. THEME is deliberately NOT
backfilled for these pre-existing notes: they predate the LLM being asked
to report one, and synthesizing one after the fact would require a
per-note LLM call this task's scope explicitly rules out (see
architecture.json step 3) -- notes.theme is simply left at its default
('') for them, same as any other pre-restructure note.

Anything that can't be confidently matched (zero or more than one
candidate note) is logged and left untouched rather than guessed at --
fail-closed, per this task's Security Posture Q14 preference ("fail
closed by default when a data-integrity-relevant check can't be
confidently resolved"). Safe to re-run: any row already carrying a
note_id (including one this script itself backfilled on a prior run) is
skipped outright, so a second run is a no-op over already-migrated rows.

Run manually from the ``api/`` directory:

    python scripts/migrate_agentic_context_categories.py             # apply
    python scripts/migrate_agentic_context_categories.py --dry-run   # report only, no writes

Per this task's scope, this script is deliberately NOT run against the
live production database as part of this change -- it is produced and
tested only here; live execution is a separate, manually-confirmed deploy
step (see project_fellowscript_deploy_process).
"""

import sys
import os
import logging

# Run as a plain script (`python scripts/migrate_agentic_context_categories.py`),
# not via pytest/a package -- Python only puts this file's own directory
# (scripts/) on sys.path, not api/ itself, which would break the `from db
# import ...` below. Mirrors migrate_json_to_postgres.py's identical fix.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from db import _connect

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


def _extract_title_and_prefix(context_entry: str) -> tuple[str, str] | None:
    """Split a legacy "<title>: <text prefix>" summary back into its two
    parts (the exact format `f"{title}: {text[:300]}"` used to produce).
    Returns None if the entry doesn't contain that separator or has an
    empty title -- both treated as "can't confidently map" by the caller.
    """
    if ": " not in context_entry:
        return None
    title, _, text_prefix = context_entry.partition(": ")
    if not title:
        return None
    return title, text_prefix


def find_unlinked_rows(cur) -> list[tuple]:
    """Every agentic_context row with no note_id yet, oldest first."""
    cur.execute(
        "SELECT _id, heartbeat_id, user_id, context FROM agentic_context "
        "WHERE note_id IS NULL ORDER BY ctid"
    )
    return cur.fetchall()


def find_candidate_notes(cur, user_id, title: str, text_prefix: str) -> list[str]:
    """note _id's belonging to user_id with an exact title AND text-prefix
    match, that aren't already linked from another agentic_context row --
    so a note already linked elsewhere (or two same-titled notes both
    trying to claim one legacy summary) is never (mis)claimed twice.
    """
    cur.execute(
        "SELECT n._id, n.text FROM notes n "
        "WHERE n.user_id = %s AND n.title = %s "
        "AND NOT EXISTS ("
        "  SELECT 1 FROM agentic_context ac2 WHERE ac2.note_id = n._id"
        ")",
        (user_id, title),
    )
    return [note_id for note_id, text in cur.fetchall() if (text or "").startswith(text_prefix)]


def migrate(cur, dry_run: bool = False) -> dict:
    """Backfills note_id on every unlinked agentic_context row it can
    confidently match. Returns row counts by outcome.
    """
    counts = {
        "total": 0, "linked": 0,
        "skipped_unparseable": 0, "skipped_no_match": 0, "skipped_ambiguous": 0,
    }
    rows = find_unlinked_rows(cur)
    counts["total"] = len(rows)
    for context_id, heartbeat_id, user_id, context_array in rows:
        entries = context_array or []
        if not entries:
            logger.warning(
                "SKIP agentic_context %s: no note_id and no context text to match against.",
                context_id,
            )
            counts["skipped_unparseable"] += 1
            continue
        parsed = _extract_title_and_prefix(entries[0])
        if not parsed:
            logger.warning(
                "SKIP agentic_context %s: could not parse a title/text-prefix out of "
                "context entry %r.", context_id, entries[0][:80],
            )
            counts["skipped_unparseable"] += 1
            continue
        title, text_prefix = parsed
        candidates = find_candidate_notes(cur, user_id, title, text_prefix)
        if len(candidates) == 0:
            logger.warning(
                "SKIP agentic_context %s: no matching unlinked note found for title %r "
                "(user %s).", context_id, title, user_id,
            )
            counts["skipped_no_match"] += 1
            continue
        if len(candidates) > 1:
            logger.warning(
                "SKIP agentic_context %s: %d ambiguous candidate notes found for title %r "
                "(user %s) -- refusing to guess.",
                context_id, len(candidates), title, user_id,
            )
            counts["skipped_ambiguous"] += 1
            continue
        note_id = candidates[0]
        logger.info(
            "LINK agentic_context %s -> note %s (heartbeat %s, title %r)",
            context_id, note_id, heartbeat_id, title,
        )
        if not dry_run:
            cur.execute(
                "UPDATE agentic_context SET note_id = %s WHERE _id = %s",
                (note_id, context_id),
            )
        counts["linked"] += 1
    return counts


def main():
    dry_run = "--dry-run" in sys.argv
    logger.info("Connecting to PostgreSQL%s...", " (dry run)" if dry_run else "")
    conn = _connect()
    cur = conn.cursor()
    try:
        counts = migrate(cur, dry_run=dry_run)
        if dry_run:
            conn.rollback()
            logger.info("Dry run complete (no changes committed): %s", counts)
        else:
            conn.commit()
            logger.info("Migration complete: %s", counts)
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()
        logger.info("Connection closed.")


if __name__ == "__main__":
    main()
