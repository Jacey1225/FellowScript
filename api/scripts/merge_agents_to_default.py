"""Merge every user's agents onto one canonical "Ask AI" agent
(task 20261106-remove-agents-ask-ai, step 2).

NOT a boot/DDL module: an operator-run script. Never run it against production
from the pipeline; the flag ``ask_ai_default_agent`` must stay off until it has
run. Run from ``api/``:

    ../.venv/bin/python scripts/merge_agents_to_default.py --dry-run
    ../.venv/bin/python scripts/merge_agents_to_default.py --apply            # scratch DB only
    ../.venv/bin/python scripts/merge_agents_to_default.py --apply --backup-confirmed "<label>"

Per user, in one savepointed transaction:
  1. Pick the canonical agent: the row already marked ``is_default``; else the
     same ordering as ``AgentManager.ensure_default_agent`` (enabled first, then
     earliest message, then lowest id). Users with no agent are skipped (the
     server creates one lazily). ``is_default`` is set on it.
  2. Copy every agent row (all columns) into ``agents_archive``.
  3. For each non-canonical agent: adopt its legacy ``chat_id IS NULL`` messages
     into its deterministic default chat first (so unrelated threads are not
     mushed into one), then prefix the title of each of its chats with the old
     agent name (titles are sealed, so via content_store open_/seal).
  4. Re-point ``agent_chats``, ``agent_messages``, ``agent_heartbeats`` onto the
     canonical id. Heartbeat idempotency-key collisions on
     (user_id, canonical, key) are resolved by nulling the later row's key;
     no heartbeat is ever deleted. Schedule columns and ``last_fired`` are
     untouched, so firing times and the once-per-day claim are preserved.
  5. Verify: per-table counts before == after, zero rows left on a non-canonical
     agent. Any failure rolls that user back and is reported; others continue.

Old agent rows are left in ``agents`` (unreferenced), never deleted: ON DELETE
CASCADE would destroy dependents. ``--dry-run`` (default) runs the full logic and
rolls every user back, printing counts. The audit log is JSON lines with ids and
counts only, never content, titles, names or roles.

``--apply`` requires the scratch database (server port 55432, or 5432 on CI)
unless ``--backup-confirmed <label>`` is given, as for the other operator scripts.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import psycopg2  # noqa: E402

from backend import content_store  # noqa: E402
from backend.interactions.agent_chats import default_chat_id  # noqa: E402
from backend.interactions.agent_chats_config import get_agent_chats_config  # noqa: E402
from db import DBManager  # noqa: E402
from schemas.agent import _DEFAULT_ROLE  # noqa: E402

TITLE_COLUMN_MAX = 80  # agent_chats.title is VARCHAR(80)

ARCHIVE_DDL = (
    "CREATE TABLE IF NOT EXISTS agents_archive("
    "_id UUID PRIMARY KEY,"
    "user_id UUID NOT NULL,"
    "role TEXT,"
    "chats TEXT[],"
    "name VARCHAR(255),"
    "enabled BOOLEAN,"
    "was_default BOOLEAN NOT NULL DEFAULT FALSE,"
    "merged_into UUID,"
    "archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
)

# agents rows in canonical-selection order (mirrors ensure_default_agent).
_AGENTS_SQL = (
    "SELECT a._id, a.role, a.chats, a.name, a.enabled, a.is_default FROM agents a "
    "WHERE a.user_id = %s ORDER BY a.is_default DESC, a.enabled DESC, "
    "(SELECT MIN(m.timestamp) FROM agent_messages m WHERE m.agent_id = a._id) ASC NULLS LAST, "
    "a._id ASC FOR UPDATE OF a"
)

_TABLES = ("agent_chats", "agent_messages", "agent_heartbeats")


class UserFailure(Exception):
    pass


def _counts(cur, user_id: str) -> dict:
    out = {}
    for t in _TABLES:
        cur.execute(f"SELECT COUNT(*) FROM {t} WHERE user_id = %s", (user_id,))
        out[t] = cur.fetchone()[0]
    return out


def _adopt_legacy_chat(cur, user_id: str, agent_id: str) -> tuple[bool, int]:
    """Same effect as AgentChatStore.ensure_default_chat, minus the commit.
    Returns (adopted, chat_rows_inserted)."""
    cid = default_chat_id(user_id, agent_id)
    cur.execute(
        "SELECT MIN(timestamp), MAX(timestamp) FROM agent_messages "
        "WHERE user_id = %s AND agent_id = %s AND chat_id IS NULL", (user_id, agent_id))
    first_ts, last_ts = cur.fetchone()
    if last_ts is None:
        return False, 0
    cur.execute(
        "SELECT _id, content FROM agent_messages WHERE user_id = %s AND agent_id = %s "
        "AND chat_id IS NULL AND title = 'user' ORDER BY timestamp LIMIT 1", (user_id, agent_id))
    first_user = cur.fetchone()
    auto_title = ""
    if first_user is not None:
        text = content_store.open_(first_user[0], content_store.F_AGENT_CONTENT, first_user[1]) or ""
        auto_title = text[: get_agent_chats_config().auto_title_length]
    cur.execute(
        "INSERT INTO agent_chats (_id, user_id, agent_id, title, created_at, last_message_at) "
        "VALUES (%s, %s, %s, %s, COALESCE(%s, NOW()), COALESCE(%s, NOW())) ON CONFLICT (_id) DO NOTHING",
        (cid, user_id, agent_id, content_store.seal(cid, content_store.F_AGENT_CHAT_TITLE, auto_title),
         first_ts, last_ts))
    inserted = cur.rowcount
    cur.execute(
        "UPDATE agent_messages SET chat_id = %s WHERE user_id = %s AND agent_id = %s AND chat_id IS NULL",
        (cid, user_id, agent_id))
    cur.execute(
        "UPDATE agent_chats SET last_message_at = GREATEST(last_message_at, %s) "
        "WHERE _id = %s AND user_id = %s AND agent_id = %s", (last_ts, cid, user_id, agent_id))
    return True, inserted


def _prefix_titles(cur, user_id: str, agent_id: str, agent_name: str) -> int:
    name = (agent_name or "").strip()
    if not name:
        return 0
    cur.execute("SELECT _id, title FROM agent_chats WHERE user_id = %s AND agent_id = %s", (user_id, agent_id))
    n = 0
    for cid, stored in cur.fetchall():
        title = content_store.open_(cid, content_store.F_AGENT_CHAT_TITLE, stored) or ""
        new = (f"{name}: {title}" if title else name)[:TITLE_COLUMN_MAX]
        cur.execute("UPDATE agent_chats SET title = %s WHERE _id = %s AND user_id = %s",
                    (content_store.seal(cid, content_store.F_AGENT_CHAT_TITLE, new), cid, user_id))
        n += 1
    return n


def _resolve_hb_collisions(cur, user_id: str, canonical: str, others: list[str]) -> int:
    """Null the idempotency_key of later rows that would collide on
    (user_id, canonical, key). Never deletes."""
    cur.execute("SELECT idempotency_key FROM agent_heartbeats WHERE user_id = %s AND agent_id = %s "
                "AND idempotency_key IS NOT NULL", (user_id, canonical))
    seen = {r[0] for r in cur.fetchall()}
    cur.execute("SELECT _id, idempotency_key FROM agent_heartbeats WHERE user_id = %s AND agent_id = ANY(%s::uuid[]) "
                "AND idempotency_key IS NOT NULL ORDER BY agent_id, _id", (user_id, others))
    nulled = 0
    for hb_id, key in cur.fetchall():
        if key in seen:
            cur.execute("UPDATE agent_heartbeats SET idempotency_key = NULL WHERE _id = %s AND user_id = %s",
                        (hb_id, user_id))
            nulled += 1
        else:
            seen.add(key)
    return nulled


def merge_user(cur, user_id: str) -> dict:
    cur.execute(_AGENTS_SQL, (user_id,))
    agents = cur.fetchall()
    rec = {"user_id": user_id, "agents": len(agents)}
    if not agents:
        rec["status"] = "no_agents"
        return rec
    canonical = str(agents[0][0])
    was_default = bool(agents[0][5])
    others = [a for a in agents[1:]]
    other_ids = [str(a[0]) for a in others]
    rec.update(canonical=canonical, non_canonical=len(others),
               custom_roles=sum(1 for a in agents if (a[1] or "").strip() not in ("", _DEFAULT_ROLE)),
               disabled=sum(1 for a in agents if not a[4]))

    before = _counts(cur, user_id)
    if not was_default:
        cur.execute("UPDATE agents SET is_default = TRUE WHERE _id = %s AND user_id = %s", (canonical, user_id))

    # Archive every row (idempotent). The canonical row's role/name are kept
    # in the archive too so nothing is lost when the prompt moves to the file.
    for a in agents:
        cur.execute(
            "INSERT INTO agents_archive (_id, user_id, role, chats, name, enabled, was_default, merged_into) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT (_id) DO NOTHING",
            (a[0], user_id, a[1], a[2], a[3], a[4], bool(a[5]), canonical))

    adopted = titled = chats_inserted = 0
    for a in others:
        aid = str(a[0])
        did, ins = _adopt_legacy_chat(cur, user_id, aid)
        if did:
            adopted += 1
        chats_inserted += ins
        titled += _prefix_titles(cur, user_id, aid, a[3])

    nulled = moved = 0
    if other_ids:
        nulled = _resolve_hb_collisions(cur, user_id, canonical, other_ids)
        for t in _TABLES:
            cur.execute(f"UPDATE {t} SET agent_id = %s WHERE user_id = %s AND agent_id = ANY(%s::uuid[])",
                        (canonical, user_id, other_ids))
            moved += cur.rowcount

    after = _counts(cur, user_id)
    # Adoption legitimately creates agent_chats rows; messages and heartbeats
    # must match exactly.
    expected = dict(before, agent_chats=before["agent_chats"] + chats_inserted)
    if expected != after:
        raise UserFailure(f"row counts changed {before} -> {after} (expected {expected})")
    for t in _TABLES:
        cur.execute(f"SELECT COUNT(*) FROM {t} WHERE user_id = %s AND agent_id <> %s", (user_id, canonical))
        if cur.fetchone()[0]:
            raise UserFailure(f"{t} still has rows on a non-canonical agent")
    rec.update(status="merged" if (moved or adopted or not was_default) else "already_merged",
               legacy_chats_adopted=adopted, chats_retitled=titled, rows_repointed=moved,
               hb_keys_nulled=nulled, heartbeats=after["agent_heartbeats"])
    return rec


def _server_port(cur) -> str:
    cur.execute("SHOW port")
    return cur.fetchone()[0]


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="default: run everything, roll back, print counts")
    mode.add_argument("--apply", action="store_true")
    p.add_argument("--backup-confirmed", metavar="LABEL", help="permit --apply on a non-scratch database")
    p.add_argument("--user", help="only this user id")
    p.add_argument("--audit-log", help="JSONL path (default api/scripts/merge_agents_audit_<ts>.jsonl)")
    args = p.parse_args(argv)
    apply = args.apply

    d = DBManager()
    conn, cur = d.conn, d.cur
    try:
        port = _server_port(cur)
        scratch = port == "55432" or (port == "5432" and os.environ.get("GITHUB_ACTIONS") == "true")
        if apply and not scratch and not args.backup_confirmed:
            print(f"refusing --apply: database port {port} is not the scratch DB; "
                  "pass --backup-confirmed <label> after taking a backup", file=sys.stderr)
            return 2
        ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        log_path = args.audit_log or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  f"merge_agents_audit_{ts}.jsonl")
        cur.execute(ARCHIVE_DDL)
        if apply:
            conn.commit()
        if args.user:
            users = [args.user]
        else:
            cur.execute("SELECT DISTINCT user_id FROM agents ORDER BY user_id")
            users = [str(r[0]) for r in cur.fetchall()]

        totals = {"users": 0, "merged": 0, "already_merged": 0, "no_agents": 0, "failed": 0,
                  "multi_agent_users": 0, "custom_roles": 0, "disabled_agents": 0,
                  "hb_keys_nulled": 0, "rows_repointed": 0}
        with open(log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps({"event": "start", "ts": ts, "mode": "apply" if apply else "dry-run",
                                  "port": port, "backup_label": args.backup_confirmed}) + "\n")
            for uid in users:
                sp = "sp_" + uuid.uuid4().hex[:8]
                cur.execute(f"SAVEPOINT {sp}")
                try:
                    rec = merge_user(cur, uid)
                    if apply:
                        cur.execute(f"RELEASE SAVEPOINT {sp}")
                        conn.commit()
                    else:
                        cur.execute(f"ROLLBACK TO SAVEPOINT {sp}")
                except (UserFailure, psycopg2.Error, ValueError, content_store.ContentDecryptError) as e:
                    cur.connection.rollback() if apply else cur.execute(f"ROLLBACK TO SAVEPOINT {sp}")
                    rec = {"user_id": uid, "status": "failed", "error": type(e).__name__}
                    if isinstance(e, UserFailure):
                        rec["detail"] = str(e)
                log.write(json.dumps(rec) + "\n")
                totals["users"] += 1
                totals[rec["status"]] = totals.get(rec["status"], 0) + 1
                if rec.get("agents", 0) > 1:
                    totals["multi_agent_users"] += 1
                totals["custom_roles"] += rec.get("custom_roles", 0)
                totals["disabled_agents"] += rec.get("disabled", 0)
                totals["hb_keys_nulled"] += rec.get("hb_keys_nulled", 0)
                totals["rows_repointed"] += rec.get("rows_repointed", 0)
            log.write(json.dumps({"event": "summary", **totals, "applied": apply}) + "\n")
        if not apply:
            conn.rollback()
        print(("APPLIED" if apply else "DRY RUN (rolled back)") + " " + json.dumps(totals))
        print(f"audit log: {log_path}")
        return 1 if totals["failed"] else 0
    finally:
        d.close()


if __name__ == "__main__":
    sys.exit(main())
