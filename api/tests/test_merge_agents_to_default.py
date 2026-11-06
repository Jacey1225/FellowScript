"""Task 20261106-remove-agents-ask-ai: scripts/merge_agents_to_default.py.

Covers: dry-run default (full logic, everything rolled back), --apply on the
scratch DB, per-table counts preserved (heartbeats never lost), idempotency-key
collisions nulled not deleted, legacy NULL-chat messages adopted per old agent,
chat titles prefixed with old agent name, archive table, schedule/last_fired
untouched, old agents rows kept (no cascade), is_default set once, second run
reports already_merged, --apply refused off-scratch, a failing user rolls back
without blocking others, audit log holds no content/names/roles.

Run (scratch DB only):  cd api && ../.venv/bin/python tests/test_merge_agents_to_default.py
"""
import _thr_common as T  # noqa: E402
from _thr_common import check, sql, make_user  # noqa: E402

import json  # noqa: E402
import os  # noqa: E402
import sys  # noqa: E402
import tempfile  # noqa: E402
import uuid  # noqa: E402

sys.path.insert(0, os.path.join(T.API_DIR, "scripts"))
import merge_agents_to_default as M  # noqa: E402
from backend import content_store  # noqa: E402

AGENTS = []
SECRET_NAME = "ZZSecretAgentName"
SECRET_ROLE = "ZZSecretRoleText"
SECRET_MSG = "ZZSecretMessageBody"


def agent(uid, name, enabled=True, role="r"):
    aid = str(uuid.uuid4())
    sql("INSERT INTO agents (_id, user_id, role, name, enabled) VALUES (%s,%s,%s,%s,%s)", (aid, uid, role, name, enabled))
    AGENTS.append(aid)
    return aid


def msg(uid, aid, ts, chat=None, title="user", content=SECRET_MSG):
    sql("INSERT INTO agent_messages (title, agent_id, user_id, timestamp, content, chat_id) VALUES (%s,%s,%s,%s,%s,%s)",
        (title, aid, uid, ts, content, chat))


def chat(uid, aid, title):
    cid = str(uuid.uuid4())
    sql("INSERT INTO agent_chats (_id, user_id, agent_id, title) VALUES (%s,%s,%s,%s)",
        (cid, uid, aid, content_store.seal(cid, content_store.F_AGENT_CHAT_TITLE, title)))
    return cid


def hb(uid, aid, key=None, last_fired=None, ts='["08:00"]'):
    hid = str(uuid.uuid4())
    sql("INSERT INTO agent_heartbeats (_id, agent_id, user_id, timestamps, prompt, idempotency_key, last_fired) "
        "VALUES (%s,%s,%s,%s,'p',%s,%s)", (hid, aid, uid, ts, key, last_fired))
    return hid


def counts(uid):
    return {t: sql(f"SELECT COUNT(*) FROM {t} WHERE user_id=%s", (uid,))[0][0]
            for t in ("agent_chats", "agent_messages", "agent_heartbeats")}


def run(uid, *flags):
    log = os.path.join(TMP, f"audit_{uuid.uuid4().hex[:6]}.jsonl")
    rc = M.main(["--user", uid, "--audit-log", log, *flags])
    recs = [json.loads(l) for l in open(log)] if os.path.exists(log) else []
    return rc, recs, log


def title_of(cid):
    row = sql("SELECT title FROM agent_chats WHERE _id=%s", (cid,))[0][0]
    return content_store.open_(cid, content_store.F_AGENT_CHAT_TITLE, row)


TMP = tempfile.mkdtemp()


def main():
    T.require_scratch_db()
    um, us, un, uf = make_user("mg1"), make_user("mg2"), make_user("mg3"), make_user("mg4")

    # Multi-agent user. canon = enabled with earliest message.
    canon = agent(um, "Primary", role=SECRET_ROLE)
    second = agent(um, SECRET_NAME, role="custom prompt")
    third = agent(um, "Off", enabled=False, role=SECRET_ROLE)
    msg(um, canon, "2026-01-01 10:00:00+00")
    msg(um, canon, "2026-01-01 10:00:05+00", title="assistant")
    # Legacy NULL-chat rows on non-canonical agents (the production shape).
    # MERGE_TEST_NO_LEGACY=1 omits them to isolate the re-point/collision logic.
    legacy = os.environ.get("MERGE_TEST_NO_LEGACY") != "1"
    if legacy:
        msg(um, second, "2026-02-01 09:00:00+00")
        msg(um, second, "2026-02-01 09:00:05+00", title="assistant")
        msg(um, third, "2026-03-01 09:00:00+00")
    c_canon = chat(um, canon, "canon chat")
    msg(um, canon, "2026-01-02 10:00:00+00", chat=c_canon)
    c_second = chat(um, second, "second chat")
    msg(um, second, "2026-02-02 10:00:00+00", chat=c_second)
    fired = "2026-05-05 08:00:00+00"
    h1 = hb(um, canon, key="k1", last_fired=fired)
    h2 = hb(um, second, key="k1", last_fired=fired, ts='["09:30"]')   # collides with h1
    h3 = hb(um, second, key="k2")
    h4 = hb(um, third, key="k1")                                      # collides too
    h5 = hb(um, third, key=None)
    before = counts(um)
    sched_before = sql("SELECT _id, timestamps, last_fired FROM agent_heartbeats WHERE user_id=%s ORDER BY _id", (um,))

    # Single-agent user and no-agent user.
    sa = agent(us, "Solo")
    hb(us, sa, key="s1")
    msg(us, sa, "2026-01-01 10:00:00+00")
    # un has no agents.

    print("== dry run (default)")
    rc, recs, log = run(um)
    summ = recs[-1]
    check("dry run rc 0", rc == 0)
    check("dry run reports mode", recs[0]["mode"] == "dry-run", str(recs[0]))
    check("dry run saw 1 multi-agent user, 2 collisions nulled in-sim, rows re-pointed > 0",
          summ["multi_agent_users"] == 1 and summ["hb_keys_nulled"] == 2 and summ["rows_repointed"] > 0, str(summ))
    check("dry run reports custom roles and disabled agents", summ["custom_roles"] >= 2 and summ["disabled_agents"] == 1, str(summ))
    check("dry run changed nothing: counts equal", counts(um) == before)
    check("dry run: heartbeats still on their original agents",
          sql("SELECT COUNT(*) FROM agent_heartbeats WHERE user_id=%s AND agent_id=%s", (um, second))[0][0] == 2)
    check("dry run: no is_default set", sql("SELECT COUNT(*) FROM agents WHERE user_id=%s AND is_default", (um,))[0][0] == 0)
    check("dry run: no archive rows persisted", sql("SELECT to_regclass('agents_archive')")[0][0] is None
          or sql("SELECT COUNT(*) FROM agents_archive WHERE user_id=%s", (um,))[0][0] == 0)
    check("dry run: legacy NULL-chat messages untouched",
          sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND chat_id IS NULL AND agent_id=%s", (um, second))[0][0] == (2 if legacy else 0))
    check("dry run: keys untouched", sql("SELECT COUNT(*) FROM agent_heartbeats WHERE user_id=%s AND idempotency_key='k1'", (um,))[0][0] == 3)

    print("== apply refused off-scratch")
    orig = M._server_port
    M._server_port = lambda cur: "5432"
    rc, recs, _ = run(um, "--apply")
    M._server_port = orig
    check("apply on non-scratch port without --backup-confirmed returns 2", rc == 2, str(rc))
    check("refusal changed nothing", counts(um) == before and sql(
        "SELECT COUNT(*) FROM agents WHERE user_id=%s AND is_default", (um,))[0][0] == 0)

    print("== apply on scratch")
    rc, recs, log = run(um, "--apply")
    rec = [r for r in recs if r.get("user_id") == um][0]
    check("apply rc 0, status merged", rc == 0 and rec["status"] == "merged", str(rec))
    check("canonical chosen = enabled+earliest message", rec["canonical"] == canon, str(rec))
    after = counts(um)
    check("heartbeat count preserved (5)", after["agent_heartbeats"] == before["agent_heartbeats"] == 5, str(after))
    check("chat/message totals preserved except adopted default chats",
          after["agent_messages"] == before["agent_messages"] and after["agent_chats"] == before["agent_chats"] + (2 if legacy else 0), f"{before} {after}")
    check("every heartbeat/chat/message on canonical", all(
        sql(f"SELECT COUNT(*) FROM {t} WHERE user_id=%s AND agent_id<>%s", (um, canon))[0][0] == 0
        for t in ("agent_chats", "agent_messages", "agent_heartbeats")))
    check("is_default set on canonical only",
          [str(r[0]) for r in sql("SELECT _id FROM agents WHERE user_id=%s AND is_default", (um,))] == [canon])
    check("old agents rows kept (no deletes)", sql("SELECT COUNT(*) FROM agents WHERE user_id=%s", (um,))[0][0] == 3)
    check("archive has all 3 rows incl. roles", sql("SELECT COUNT(*) FROM agents_archive WHERE user_id=%s", (um,))[0][0] == 3
          and sql("SELECT role FROM agents_archive WHERE _id=%s", (third,))[0][0] == SECRET_ROLE)
    check("archive merged_into = canonical", sql("SELECT COUNT(*) FROM agents_archive WHERE user_id=%s AND merged_into=%s", (um, canon))[0][0] == 3)
    keys = {str(r[0]): r[1] for r in sql("SELECT _id, idempotency_key FROM agent_heartbeats WHERE user_id=%s", (um,))}
    check("collision: earlier/canonical's k1 kept, later k1s nulled (not deleted)",
          keys[h1] == "k1" and keys[h2] is None and keys[h4] is None and keys[h3] == "k2" and keys[h5] is None, str(keys))
    check("hb_keys_nulled == 2", rec["hb_keys_nulled"] == 2, str(rec))
    check("no idempotency collisions remain", sql(
        "SELECT COUNT(*) FROM (SELECT 1 FROM agent_heartbeats WHERE user_id=%s AND idempotency_key IS NOT NULL "
        "GROUP BY user_id, agent_id, idempotency_key HAVING COUNT(*)>1) x", (um,))[0][0] == 0)
    check("schedule columns and last_fired untouched",
          sql("SELECT _id, timestamps, last_fired FROM agent_heartbeats WHERE user_id=%s ORDER BY _id", (um,)) == sched_before)
    check("legacy NULL messages of non-canonical adopted into a chat", sql(
        "SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND chat_id IS NULL AND agent_id<>%s", (um, canon))[0][0] == 0
          and sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND chat_id IS NULL", (um,))[0][0] == 2)  # canon's own legacy rows stay (route adopts lazily)
    if legacy:
        check("adopted legacy rows live in the deterministic default chat of the old agent (re-pointed to canonical)",
              sql("SELECT COUNT(*) FROM agent_messages WHERE user_id=%s AND chat_id IS NOT NULL AND agent_id=%s", (um, canon))[0][0] >= 5)
    check("non-canonical chat title prefixed with old agent name", title_of(c_second) == f"{SECRET_NAME}: second chat", title_of(c_second))
    check("canonical's own chat title unchanged", title_of(c_canon) == "canon chat", title_of(c_canon))
    check("all chat titles within 80 chars", all(
        len(content_store.open_(str(r[0]), content_store.F_AGENT_CHAT_TITLE, r[1]) or "") <= 80
        for r in sql("SELECT _id, title FROM agent_chats WHERE user_id=%s", (um,))))
    raw = open(log).read()
    check("audit log has no names/roles/content",
          SECRET_NAME not in raw and SECRET_ROLE not in raw and SECRET_MSG not in raw and "second chat" not in raw)

    print("== idempotency")
    snap = (counts(um), sql("SELECT _id, agent_id, idempotency_key FROM agent_heartbeats WHERE user_id=%s ORDER BY _id", (um,)),
            sql("SELECT _id, title FROM agent_chats WHERE user_id=%s ORDER BY _id", (um,)))
    rc, recs, _ = run(um, "--apply")
    rec2 = [r for r in recs if r.get("user_id") == um][0]
    check("second apply reports already_merged, 0 repointed", rc == 0 and rec2["status"] == "already_merged" and rec2["rows_repointed"] == 0, str(rec2))
    snap2 = (counts(um), sql("SELECT _id, agent_id, idempotency_key FROM agent_heartbeats WHERE user_id=%s ORDER BY _id", (um,)),
             sql("SELECT _id, title FROM agent_chats WHERE user_id=%s ORDER BY _id", (um,)))
    check("second apply changed nothing (titles not double-prefixed)", snap == snap2)
    check("archive not duplicated", sql("SELECT COUNT(*) FROM agents_archive WHERE user_id=%s", (um,))[0][0] == 3)
    rc, recs, _ = run(um)
    check("dry run after apply is also already_merged",
          [r for r in recs if r.get("user_id") == um][0]["status"] == "already_merged")

    print("== single-agent and no-agent users")
    rc, recs, _ = run(us, "--apply")
    r = [x for x in recs if x.get("user_id") == us][0]
    check("single-agent user: is_default set, nothing moved", r["status"] == "merged" and r["rows_repointed"] == 0
          and sql("SELECT is_default FROM agents WHERE _id=%s", (sa,))[0][0] is True, str(r))
    rc, recs, _ = run(us, "--apply")
    check("single-agent user rerun already_merged", [x for x in recs if x.get("user_id") == us][0]["status"] == "already_merged")
    rc, recs, _ = run(un, "--apply")
    check("no-agent user -> no_agents, no row created", [x for x in recs if x.get("user_id") == un][0]["status"] == "no_agents"
          and sql("SELECT COUNT(*) FROM agents WHERE user_id=%s", (un,))[0][0] == 0)

    print("== per-user failure rolls back that user only")
    fa, fb = agent(uf, "F1"), agent(uf, "F2")
    msg(uf, fa, "2026-01-01 10:00:00+00")
    hb(uf, fa, key="x"); hb(uf, fb, key="x")
    fbefore = counts(uf)
    orig_res = M._resolve_hb_collisions
    M._resolve_hb_collisions = lambda cur, u, c, o: 0   # sabotage: unique violation on re-point
    try:
        rc, recs, _ = run(uf, "--apply")
    finally:
        M._resolve_hb_collisions = orig_res
    r = [x for x in recs if x.get("user_id") == uf][0]
    check("failure reported, rc 1", rc == 1 and r["status"] == "failed", str(r))
    check("failed user fully rolled back (counts, agent_ids, no is_default, no archive)",
          counts(uf) == fbefore and sql("SELECT COUNT(*) FROM agent_heartbeats WHERE user_id=%s AND agent_id=%s", (uf, fb))[0][0] == 1
          and sql("SELECT COUNT(*) FROM agents WHERE user_id=%s AND is_default", (uf,))[0][0] == 0
          and sql("SELECT COUNT(*) FROM agents_archive WHERE user_id=%s", (uf,))[0][0] == 0)
    rc, recs, _ = run(uf, "--apply")
    check("retry without sabotage succeeds", rc == 0 and [x for x in recs if x.get("user_id") == uf][0]["status"] == "merged")
    check("retry: both heartbeats kept, one key nulled", counts(uf)["agent_heartbeats"] == 2 and sql(
        "SELECT COUNT(*) FROM agent_heartbeats WHERE user_id=%s AND idempotency_key IS NULL", (uf,))[0][0] == 1)

    print("== cleanup")
    for u in (um, us, un, uf):
        sql("DELETE FROM agents_archive WHERE user_id=%s", (u,))
    sql("DELETE FROM agents WHERE _id = ANY(%s::uuid[])", (AGENTS,))
    T.finish(())


if __name__ == "__main__":
    main()
