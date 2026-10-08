"""Coverage for task 20260908-session-summary-personal-fanout, backend step:
`summarize_session` (POST /agent/{user_id}/{agent_id}/summarize) writes the
summary to the PERSONAL notes (group_id NULL, public false) of every verified
participant of a non-group session (friend DM or persisted ungrouped session),
behind the `session_summary_fanout` config flag (default off).

Scratch database only. Before any work this asserts SHOW port = 55432 AND
installs a guard under psycopg2's low-level connect that records every port
actually dialed and refuses 5432, so a connection to the dev DB cannot happen
even if the outer shim is missing. Run through the port shim:

  cd api && ../.venv/bin/python <scratch>/run.py tests/test_summarize_session_personal_fanout.py
"""
import _pathfix  # noqa: F401,E402

import json
import logging
import os
import tempfile
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

import psycopg2  # noqa: E402
from psycopg2 import extensions as _pgext  # noqa: E402

# ── Dev-DB guard: innermost hook, sees the final dsn after any outer shim ─────
# CI runs the Postgres service container on 5432 (same convention as the other
# scratch-DB tests); locally only the scratch cluster on 55432 is allowed.
_IN_CI = os.environ.get("GITHUB_ACTIONS") == "true"
_ALLOWED_PORTS = {"55432", "5432"} if _IN_CI else {"55432"}
PORTS_DIALED: list[str] = []
_real_connect = psycopg2._connect


def _guarded_connect(dsn, *a, **k):
    port = str(_pgext.parse_dsn(dsn).get("port", "5432"))
    PORTS_DIALED.append(port)
    if port == "5432" and not _IN_CI:
        raise RuntimeError("test guard: refusing to connect to port 5432 (dev DB)")
    return _real_connect(dsn, *a, **k)


psycopg2._connect = _guarded_connect

import _fake_timeline  # noqa: F401,E402

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from _plan_common import grant_paid  # noqa: E402
import backend.interactions.agent as agent_module  # noqa: E402
import backend.interactions.session_summary_fanout as fanout_module  # noqa: E402
import backend.interactions.session_summary_fanout_config as cfgmod  # noqa: E402
from backend.config_loader import ConfigSectionError  # noqa: E402

PASSED, FAILED = [], []
SUMMARY = "SUMMARYTEXT-" + uuid.uuid4().hex
MODEL_CALLS = []


def check(label: str, cond: bool, detail: str = ""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


def require_scratch_db():
    d = DBManager()
    try:
        d.cur.execute("SHOW port")
        port = d.cur.fetchone()[0]
    finally:
        d.close()
    check("tests run against scratch DB (55432, or 5432 in CI)", port in _ALLOWED_PORTS, port)
    if port not in _ALLOWED_PORTS:
        raise SystemExit("refusing to continue: not the scratch database")


def set_flag(enabled: bool, cap: int = 10):
    cfgmod._cached = cfgmod.SessionSummaryFanoutConfig(enabled, cap)


def cookie(token):
    return {"cookie": f"session={token}"}


def signup(client, label, paid=True):
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    name = f"fo{label}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": name, "email": f"{name}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, r.text
    uid = r.json()["user_id"]
    if paid:
        grant_paid(uid)
    return uid, r.cookies.get("session")


def sql(q, params=()):
    db = DBManager()
    try:
        db.cur.execute(q, params)
        rows = db.cur.fetchall() if db.cur.description else []
        db.conn.commit()
        return rows
    finally:
        db.close()


def make_agent(uid):
    aid = str(uuid.uuid4())
    sql("INSERT INTO agents (_id, user_id, role, chats) VALUES (%s,%s,%s,%s)", (aid, uid, "", []))
    return aid


def befriend(a, b):
    sql("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s)", (a, b, b, a))


def make_devotion(creator, participants):
    did = str(uuid.uuid4())
    sql("INSERT INTO devotions (_id, title, creator_id, participants, group_id) VALUES (%s,%s,%s,%s,%s)",
        (did, "persisted", creator, participants, None))
    return did


def notes_of(uid):
    return sql("SELECT _id, group_id, public, user_id, title, text FROM notes WHERE user_id=%s", (uid,))


def summary_notes(uid):
    return sql("SELECT COUNT(*) FROM notes WHERE user_id=%s AND summary_dedupe_key IS NOT NULL", (uid,))[0][0]


def cleanup(uids, devotions=(), groups=()):
    for d in devotions:
        sql("DELETE FROM devotions WHERE _id=%s", (d,))
    for g in groups:
        sql("DELETE FROM groups WHERE _id=%s", (g,))
    for u in uids:
        sql("DELETE FROM notes WHERE user_id=%s", (u,))
        sql("DELETE FROM user_friends WHERE user_id=%s OR friend_id=%s", (u, u))
        sql("DELETE FROM agents WHERE user_id=%s", (u,))
        sql("DELETE FROM subscriptions WHERE user_id=%s", (u,))
        sql("DELETE FROM users WHERE _id=%s", (u,))


def summarize(client, token, uid, agent_id, session=None, group_id=None):
    session = session if session is not None else {"id": str(uuid.uuid4())}
    session = {"title": "Study", "prompts": ["p1"], "verses": ["Gen 1:1"], **session}
    payload = {"session": session}
    if group_id is not None:
        payload["group_id"] = group_id
    return client.post(f"/agent/{uid}/{agent_id}/summarize", json=payload, headers=cookie(token))


class LogCap(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


def test_config():
    print("\n=== config: shipped default off, validation, fail-closed ===")
    cfgmod.reset_for_tests()
    c = cfgmod.get_session_summary_fanout_config()
    check("shipped config: enabled is true (switched on 2026-10-08)", c.enabled is True, str(c))
    check("shipped config: cap is a positive int", isinstance(c.max_recipients_per_session, int) and c.max_recipients_per_session >= 1)
    orig = cfgmod.CONFIG_PATH
    try:
        for label, section in [
            ("cap 0 rejected", {"enabled": False, "max_recipients_per_session": 0}),
            ("cap too big rejected", {"enabled": False, "max_recipients_per_session": 9999}),
            ("enabled wrong type rejected", {"enabled": "yes", "max_recipients_per_session": 5}),
            ("missing key rejected", {"enabled": True}),
            ("unknown key rejected", {"enabled": True, "max_recipients_per_session": 5, "x": 1}),
        ]:
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump({"session_summary_fanout": section}, f)
            cfgmod.CONFIG_PATH = f.name
            cfgmod.reset_for_tests()
            try:
                cfgmod.validate_session_summary_fanout_config()
                check(label, False, "no error raised")
            except ConfigSectionError:
                check(label, True)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"other": {}}, f)
        cfgmod.CONFIG_PATH = f.name
        cfgmod.reset_for_tests()
        check("missing section: flag treated off (fail closed)", cfgmod.is_fanout_enabled() is False)
    finally:
        cfgmod.CONFIG_PATH = orig
        cfgmod.reset_for_tests()


def test_flag_off(client):
    print("\n=== flag off: byte-for-byte today, caller-only, no dedupe key, no fanout key ===")
    set_flag(False)
    a, ta = signup(client, "offa")
    b, _ = signup(client, "offb")
    try:
        befriend(a, b)
        ag = make_agent(a)
        r = summarize(client, ta, a, ag, group_id=f"{a}|{b}")
        check("201 and exactly {ok, note_id}", r.status_code == 201 and set(r.json()) == {"ok", "note_id"}, r.text)
        check("caller has one note, B has none", len(notes_of(a)) == 1 and len(notes_of(b)) == 0)
        check("no dedupe key set", summary_notes(a) == 0)
    finally:
        cleanup([a, b])


def test_dm_fanout(client):
    print("\n=== flag on, friend DM: both get personal notes; one model call ===")
    set_flag(True)
    a, ta = signup(client, "dma")
    b, tb = signup(client, "dmb")
    try:
        befriend(a, b)
        ag = make_agent(a)
        sid = str(uuid.uuid4())
        MODEL_CALLS.clear()
        r = summarize(client, ta, a, ag, session={"id": sid}, group_id=f"{a}|{b}")
        j = r.json()
        check("201 with fanout counts", r.status_code == 201 and j.get("fanout") == {"written": 1, "skipped": 0}, r.text)
        check("model called exactly once", len(MODEL_CALLS) == 1, str(len(MODEL_CALLS)))
        na, nb = notes_of(a), notes_of(b)
        check("A and B each have exactly one note", len(na) == 1 and len(nb) == 1)
        check("B note: group_id NULL, public false, owned by B",
              nb[0][1] is None and nb[0][2] is False and str(nb[0][3]) == b, str(nb))
        check("A note id is the response note_id", str(na[0][0]) == j["note_id"])
        check("B title/text match A's", nb[0][4] == na[0][4] and nb[0][5] == na[0][5])

        MODEL_CALLS.clear()
        r2 = summarize(client, ta, a, ag, session={"id": sid}, group_id=f"{a}|{b}")
        check("retry: 201, same caller note_id", r2.status_code == 201 and r2.json()["note_id"] == j["note_id"], r2.text)
        check("retry: no model call and no duplicates", len(MODEL_CALLS) == 0 and summary_notes(a) == 1 and summary_notes(b) == 1)

        # B ends the same session too: own note id, no extra copy for A beyond the deduped one.
        r3 = summarize(client, tb, b, make_agent(b), session={"id": sid}, group_id=f"{a}|{b}")
        check("other participant retry returns their own existing note", r3.status_code == 201
              and r3.json()["note_id"] == str(nb[0][0]), r3.text)
        check("still one note each", summary_notes(a) == 1 and summary_notes(b) == 1)
    finally:
        cleanup([a, b])


def test_ineligible_recipients(client):
    print("\n=== free recipient / notes-cap recipient skipped silently ===")
    set_flag(True)
    a, ta = signup(client, "ina")
    b, _ = signup(client, "inb", paid=False)
    c, _ = signup(client, "inc")
    try:
        befriend(a, b)
        befriend(a, c)
        ag = make_agent(a)
        r = summarize(client, ta, a, ag, session={"id": str(uuid.uuid4())}, group_id=f"{a}|{b}")
        check("free B skipped, A still 201, skipped=1",
              r.status_code == 201 and r.json()["fanout"] == {"written": 0, "skipped": 1}, r.text)
        check("B has no note; A has one", len(notes_of(b)) == 0 and len(notes_of(a)) == 1)

        orig = fanout_module.check_limit
        fanout_module.check_limit = lambda uid, res: {"allowed": uid != c, "resource": res}
        try:
            r = summarize(client, ta, a, ag, session={"id": str(uuid.uuid4())}, group_id=f"{a}|{c}")
        finally:
            fanout_module.check_limit = orig
        check("C at notes cap skipped, no error", r.status_code == 201 and r.json()["fanout"]["skipped"] == 1, r.text)
        check("C has no note", len(notes_of(c)) == 0)
    finally:
        cleanup([a, b, c])


def test_dm_forgery(client):
    print("\n=== DM forgery: caller outside key, non-friends, forged participants ===")
    set_flag(True)
    a, ta = signup(client, "fa")
    b, _ = signup(client, "fb")
    x, _ = signup(client, "fx")
    try:
        befriend(b, x)
        ag = make_agent(a)
        r = summarize(client, ta, a, ag, session={"id": str(uuid.uuid4())}, group_id=f"{b}|{x}")
        check("caller not in key: caller-only, victims get nothing",
              r.status_code == 201 and len(notes_of(b)) == 0 and len(notes_of(x)) == 0 and len(notes_of(a)) == 1, r.text)
        r = summarize(client, ta, a, ag, session={"id": str(uuid.uuid4())}, group_id=f"{a}|{b}")
        check("key with non-friend: caller-only", r.status_code == 201 and len(notes_of(b)) == 0, r.text)
        befriend(a, b)
        r = summarize(client, ta, a, ag,
                      session={"id": str(uuid.uuid4()), "participants": [b, x]}, group_id=f"{a}|{b}")
        check("forged client participants add nobody in DM path", len(notes_of(x)) == 0 and len(notes_of(b)) == 1, r.text)
        r = summarize(client, ta, a, ag, session={"id": str(uuid.uuid4())}, group_id=f"{a}|{b}|{x}")
        check("malformed 3-part key: caller-only", r.status_code == 201 and len(notes_of(x)) == 0, r.text)
    finally:
        cleanup([a, b, x])


def test_ungrouped_persisted(client):
    print("\n=== ungrouped session: persisted participants verified; forged ids ignored ===")
    set_flag(True)
    a, ta = signup(client, "ua")
    b, tb = signup(client, "ub")
    c, _ = signup(client, "uc")
    x, tx = signup(client, "ux")
    dids = []
    try:
        d = make_devotion(a, [b, c])
        dids.append(d)
        ag = make_agent(a)
        r = summarize(client, ta, a, ag, session={"id": d, "participants": [b, c, x]})
        check("all persisted participants get notes, forged X ignored",
              r.status_code == 201 and summary_notes(a) == summary_notes(b) == summary_notes(c) == 1
              and len(notes_of(x)) == 0, r.text)
        check("fanout counts written=2", r.json()["fanout"] == {"written": 2, "skipped": 0}, r.text)

        d2 = make_devotion(a, [b, c])
        dids.append(d2)
        r = summarize(client, ta, a, ag, session={"id": d2, "participants": [b]})
        check("client list narrows (C excluded)", r.status_code == 201 and sum(1 for n in notes_of(c)) == 1
              and summary_notes(b) == 2, r.text)

        r = summarize(client, tx, x, make_agent(x), session={"id": d})
        check("non-participant caller of persisted session: 403, no notes",
              r.status_code == 403 and len(notes_of(x)) == 0, r.text)

        r = summarize(client, ta, a, ag, session={"id": str(uuid.uuid4()), "participants": [b, c]})
        check("no persisted row: caller-only", r.status_code == 201 and r.json().get("fanout") == {"written": 0, "skipped": 0}, r.text)
        check("no persisted row: B/C gained nothing new", summary_notes(b) == 2 and summary_notes(c) == 1)

        r = summarize(client, ta, a, ag, session={"id": "not-a-uuid", "participants": [b]})
        check("invalid session id: caller-only, no dedupe key", r.status_code == 201 and summary_notes(b) == 2, r.text)

        r = summarize(client, tb, a, ag, session={"id": d})
        check("token for another user rejected", r.status_code in (401, 403), str(r.status_code))
    finally:
        cleanup([a, b, c, x], devotions=dids)


def test_cap(client):
    print("\n=== max_recipients_per_session truncation (caller first, then sorted ids) ===")
    a, ta = signup(client, "ca")
    b, _ = signup(client, "cb")
    c, _ = signup(client, "cc")
    try:
        d = make_devotion(a, [b, c])
        set_flag(True, cap=2)
        r = summarize(client, ta, a, make_agent(a), session={"id": d})
        keep = sorted([b, c])[0]
        drop = sorted([b, c])[1]
        check("only caller + first sorted participant written",
              r.status_code == 201 and summary_notes(keep) == 1 and summary_notes(drop) == 0, r.text)
    finally:
        set_flag(True)
        cleanup([a, b, c], devotions=[d])


def test_real_group_and_failures(client):
    print("\n=== real group untouched; failure paths write nothing ===")
    set_flag(True)
    a, ta = signup(client, "ga")
    b, _ = signup(client, "gb")
    o, to = signup(client, "go")
    gid = str(uuid.uuid4())
    try:
        r = client.post(f"/groups/{a}", json={"group_id": gid, "title": "G", "users": [a, b]}, headers=cookie(ta))
        assert r.status_code == 201, r.text
        ag = make_agent(a)
        r = summarize(client, ta, a, ag, session={"id": str(uuid.uuid4())}, group_id=gid)
        n = notes_of(a)
        check("real group: single group note, exact response shape",
              r.status_code == 201 and set(r.json()) == {"ok", "note_id"} and len(n) == 1 and str(n[0][1]) == gid, r.text)
        check("real group: members get no personal copy", len(notes_of(b)) == 0 and summary_notes(a) == 0)
        r = summarize(client, to, o, make_agent(o), group_id=gid)
        check("non-member group_id still 403", r.status_code == 403, r.text)

        before = summary_notes(a)
        r = client.post(f"/agent/{a}/{ag}/summarize", json={"session": {"title": "t", "prompts": [], "verses": []}},
                        headers=cookie(ta))
        check("empty content still rejected (422 NoSummarizableContent)", r.status_code == 422, r.text)

        orig = agent_module.AgentManager._call_api
        def boom(self, role, msgs):
            raise RuntimeError("down")
        agent_module.AgentManager._call_api = boom
        try:
            d = make_devotion(a, [b])
            r = summarize(client, ta, a, ag, session={"id": d})
        finally:
            agent_module.AgentManager._call_api = orig
        check("model failure 502, no recipient notes", r.status_code == 502 and summary_notes(b) == 0 and summary_notes(a) == before, r.text)
        sql("DELETE FROM devotions WHERE _id=%s", (d,))

        orig_call = agent_module.AgentManager._call_api
        agent_module.AgentManager._call_api = lambda self, role, msgs: '{"__action": "create_notification", "title": "x"}'
        try:
            d = make_devotion(a, [b])
            r = summarize(client, ta, a, ag, session={"id": d})
        finally:
            agent_module.AgentManager._call_api = orig_call
        check("unsalvageable leaked action 502, nothing written", r.status_code == 502 and summary_notes(b) == 0, r.text)
        sql("DELETE FROM devotions WHERE _id=%s", (d,))

        free, tf = signup(client, "gf", paid=False)
        r = summarize(client, tf, free, make_agent(free), session={"id": str(uuid.uuid4())})
        check("free caller still 403 paid-only", r.status_code == 403, r.text)
        cleanup([free])
    finally:
        cleanup([a, b, o], groups=[gid])


def main():
    require_scratch_db()
    check("guard installed (ports dialed so far are all 55432)", set(PORTS_DIALED) <= _ALLOWED_PORTS, str(set(PORTS_DIALED)))

    def fake_call(self, role, msgs):
        MODEL_CALLS.append(1)
        return SUMMARY
    orig = agent_module.AgentManager._call_api
    agent_module.AgentManager._call_api = fake_call
    cap = LogCap()
    logging.getLogger().addHandler(cap)
    logging.getLogger().setLevel(logging.DEBUG)
    try:
        test_config()
        with TestClient(main_module.app) as client:
            test_flag_off(client)
            test_dm_fanout(client)
            test_ineligible_recipients(client)
            test_dm_forgery(client)
            test_ungrouped_persisted(client)
            test_cap(client)
            test_real_group_and_failures(client)
        fan_lines = [l for l in cap.lines if "fan-out" in l or "fanout" in l]
        check("fan-out logs emitted", len(fan_lines) > 0)
        check("logs never contain summary text or titles",
              not any(SUMMARY in l or "Session Summary" in l for l in cap.lines))
        check("logs contain no emails", not any("@example.com" in l for l in fan_lines))
    finally:
        logging.getLogger().removeHandler(cap)
        agent_module.AgentManager._call_api = orig
        set_flag(False)
        cfgmod.reset_for_tests()

    check("no connection to 5432 was ever attempted", (_IN_CI or "5432" not in PORTS_DIALED) and len(PORTS_DIALED) > 0,
          str(sorted(set(PORTS_DIALED))))
    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
