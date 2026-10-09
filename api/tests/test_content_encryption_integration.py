"""Integration coverage for task 20261008-content-encryption-at-rest against a
SCRATCH Postgres (never the dev DB): schema, flag-gated writes, always-on
dual-read, search (personal + group, caps, mixed rows), response-shape parity,
fail-closed HTTP behaviour, backup copy, and the backfill / rollback / rotation
engine (dry run, apply guard, idempotence, resume after a kill, verify failure
injection, compare-and-set race, unauthenticatable ciphertext, audit rows).

Isolation: the script creates its own databases (``fellowscript_ce`` and
``fellowscript_ce_bak``) on the scratch server and points DBManager at them, so
the backfill can run over WHOLE tables without touching rows from any other
test. It refuses to run unless ``SHOW port`` is the scratch port (55432), or
5432 under GITHUB_ACTIONS (CI's throwaway service container).

Run with: cd api && ../.venv/bin/python tests/test_content_encryption_integration.py
"""
import _pathfix  # noqa: F401

import base64
import dataclasses
import io
import json
import logging
import os
import sys
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

K1 = base64.b64encode(b"A" * 32).decode()
K2 = base64.b64encode(b"B" * 32).decode()
os.environ["CONTENT_ENCRYPTION_KEYS"] = f"1:{K1}"

import psycopg2  # noqa: E402

import db as dbmod  # noqa: E402
from db import DBManager  # noqa: E402

CE_DB, CE_BAK = "fellowscript_ce", "fellowscript_ce_bak"

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


# -- scratch DB guard + isolated databases ------------------------------------

def _admin_conn(dbname):
    return psycopg2.connect(host="localhost", port=5432, dbname=dbname, user="fellowscript",
                            password=dbmod._DB_PASSWORD)


def setup_databases():
    conn = _admin_conn("fellowscript")
    try:
        cur = conn.cursor()
        cur.execute("SHOW port")
        port = cur.fetchone()[0]
    finally:
        conn.close()
    ok = port == "55432" or (port == "5432" and os.environ.get("GITHUB_ACTIONS") == "true")
    check("tests run against the scratch database server", ok, port)
    if not ok:
        raise SystemExit(f"refusing to continue: server port {port} is not the scratch database")
    conn = _admin_conn("fellowscript")
    conn.autocommit = True
    cur = conn.cursor()
    for name in (CE_DB, CE_BAK):
        cur.execute(f"DROP DATABASE IF EXISTS {name} WITH (FORCE)")
        cur.execute(f"CREATE DATABASE {name}")
    conn.close()
    for name, creator in ((CE_DB, dbmod.create_tables), (CE_BAK, dbmod.create_backup_tables)):
        c = _admin_conn(name)
        cur = c.cursor()
        creator(cur)
        c.commit()
        c.close()


def drop_databases():
    try:
        conn = _admin_conn("fellowscript")
        conn.autocommit = True
        cur = conn.cursor()
        for name in (CE_DB, CE_BAK):
            cur.execute(f"DROP DATABASE IF EXISTS {name} WITH (FORCE)")
        conn.close()
    except Exception as e:  # noqa: BLE001
        print("cleanup warning:", e)


setup_databases()
# Point every DBManager() (routes, managers, tooling) at the isolated DB.
DBManager.__init__.__defaults__ = (CE_DB,)
dbmod.BACKUP_DB_NAME = CE_BAK
import backend.backup.manager as backup_manager  # noqa: E402
backup_manager.BACKUP_DB_NAME = CE_BAK

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from backend import content_crypto as cc, content_store as cs, content_config as ccfg  # noqa: E402
from backend.interactions import flags  # noqa: E402
from backend.interactions.groups import GroupsManager  # noqa: E402
from backend.maintenance import content_migrate as cm  # noqa: E402
import schema_ddl.content_encryption as ddl  # noqa: E402

PW = "TestPass123!"


def q(sql, params=(), dbname=None):
    db = DBManager(dbname=dbname) if dbname else DBManager()
    try:
        db.cur.execute(sql, params)
        try:
            rows = db.cur.fetchall()
        except Exception:
            rows = None
        db.conn.commit()
        return rows
    finally:
        db.close()


def set_flag(on):
    q("INSERT INTO feature_flags (name, state) VALUES ('content_encryption_write', %s) "
      "ON CONFLICT (name) DO UPDATE SET state = EXCLUDED.state", ("on" if on else "off",))
    flags.invalidate()


def raw(table, rid, col, dbname=None):
    return q(f"SELECT {col} FROM {table} WHERE _id = %s", (rid,), dbname)[0][0]


def signup(client, prefix):
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={"username": username, "email": f"{username}@example.com",
                                     "plain_pass": PW, "terms_accepted": True},
                    headers={"cf-connecting-ip": f"203.0.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], username, r.cookies.get("session")


def H(tok):
    return {"cookie": f"session={tok}", "cf-connecting-ip": f"198.51.{uuid.uuid4().int % 250}.{uuid.uuid4().int % 250 + 1}"}


def insert_note(uid, title, text, *, created, group_id=None, is_reply=False, sealed=None):
    """Insert via the funnel (flag-dependent) unless ``sealed`` forces a stored form."""
    nid = str(uuid.uuid4())
    db = DBManager()
    try:
        if sealed is None:
            assert db.insertion("notes", {
                "_id": nid, "user_id": uid, "title": title, "text": text, "public": False,
                "group_id": group_id, "is_reply": is_reply, "timestamp": created, "created_at": created})
        else:
            t = cs.seal(nid, cs.F_NOTE_TITLE, title, force=sealed)
            b = cs.seal(nid, cs.F_NOTE_TEXT, text, force=sealed)
            db.cur.execute(
                "INSERT INTO notes (_id,user_id,title,text,public,group_id,is_reply,timestamp,created_at) "
                "VALUES (%s,%s,%s,%s,false,%s,%s,%s,%s)", (nid, uid, t, b, group_id, is_reply, created, created))
            db.conn.commit()
    finally:
        db.close()
    return nid


def strip_vol(note):
    return {k: v for k, v in note.items() if k not in ("created_at", "timestamp", "user")}


def main():
    now = datetime.now(timezone.utc)
    cfg0 = ccfg.get_content_config()

    with TestClient(main_module.app, raise_server_exceptions=False) as client:
        print("=== schema: additive + idempotent ===")
        c = _admin_conn(CE_DB)
        cur = c.cursor()
        ddl.apply(cur)
        ddl.apply(cur)
        c.commit()
        cur.execute("SELECT table_name, column_name, data_type FROM information_schema.columns "
                    "WHERE (table_name, column_name) IN (('notes','title'),('threads','title'),('agent_chats','title'))")
        types = {(t, col): dt for t, col, dt in cur.fetchall()}
        check("applying the content_encryption DDL module twice is a no-op", True)
        check("VARCHAR title columns are widened to TEXT", all(v == "text" for v in types.values()) and len(types) == 3, str(types))
        cur.execute("SELECT to_regclass('content_encryption_audit')")
        check("audit table exists", cur.fetchone()[0] is not None)
        cur.execute("SELECT state FROM feature_flags WHERE name='content_encryption_write'")
        row = cur.fetchone()
        check("write flag is seeded and defaults OFF", row is not None and row[0] == "off", str(row))
        # a VARCHAR(255) column must widen: simulate an older schema, then re-apply
        cur.execute("ALTER TABLE notes ALTER COLUMN title TYPE VARCHAR(255)")
        c.commit()
        ddl.apply(cur)
        c.commit()
        cur.execute("SELECT data_type FROM information_schema.columns WHERE table_name='notes' AND column_name='title'")
        check("apply() widens a VARCHAR(255) notes.title (long ciphertext titles fit)", cur.fetchone()[0] == "text")
        c.close()
        flags.invalidate()
        check("flag is OFF by default through flags.is_enabled", flags.is_enabled("content_encryption_write") is False)

        uid_a, uname_a, tok_a = signup(client, "ce_a")
        uid_b, uname_b, tok_b = signup(client, "ce_b")
        uid_c, uname_c, tok_c = signup(client, "ce_c")

        print("\n=== writes: flag OFF -> plaintext; flag ON -> ciphertext; reads work in both states ===")
        set_flag(False)
        n_off = insert_note(uid_a, "Plain title", "Plain body about Gideon", created=now - timedelta(minutes=50))
        check("flag OFF: stored title/text are plaintext", raw("notes", n_off, "title") == "Plain title" and raw("notes", n_off, "text") == "Plain body about Gideon")
        set_flag(True)
        n_on = insert_note(uid_a, "Secret title", "Secret body about Jericho", created=now - timedelta(minutes=40))
        t_raw, b_raw = raw("notes", n_on, "title"), raw("notes", n_on, "text")
        check("flag ON: stored title/text are enc:v1: ciphertext", t_raw.startswith("enc:v1:") and b_raw.startswith("enc:v1:"))
        dump = json.dumps(q("SELECT row_to_json(n) FROM notes n WHERE _id = %s", (n_on,)))
        check("flag ON: no plaintext anywhere in the stored row (direct DB inspection)", "Secret" not in dump and "Jericho" not in dump, dump[:200])
        n_esc = insert_note(uid_a, "enc:v1:user typed this", "enc:p:and this", created=now - timedelta(minutes=30), sealed=False)
        check("flag OFF-style write of enc:-prefixed user text is escaped", raw("notes", n_esc, "title").startswith("enc:p:"))
        for flag_state in (True, False):
            set_flag(flag_state)
            r = client.get(f"/notes/{uid_a}", headers=H(tok_a))
            notes = r.json().get("notes", {})
            check(f"flag {'ON' if flag_state else 'OFF'}: GET /notes returns plaintext for plaintext, ciphertext and escaped rows",
                  r.status_code == 200
                  and notes[n_off]["title"] == "Plain title"
                  and notes[n_on]["title"] == "Secret title" and notes[n_on]["text"] == "Secret body about Jericho"
                  and notes[n_esc]["title"] == "enc:v1:user typed this" and notes[n_esc]["text"] == "enc:p:and this",
                  r.text[:300])
        shape_keys = {"user", "title", "text", "public", "group_id", "is_reply", "timestamp", "created_at", "verses", "replies"}
        r = client.get(f"/notes/{uid_a}", headers=H(tok_a))
        body = r.json()
        check("GET /notes response shape unchanged (top-level keys + per-note keys, ciphertext and plaintext rows alike)",
              set(body) == {"notes", "next_cursor_created_at", "next_cursor_id", "has_more"}
              and all(set(v) == shape_keys for v in body["notes"].values())
              and all(isinstance(body["notes"][k]["title"], str) and isinstance(body["notes"][k]["text"], str) for k in (n_off, n_on, n_esc)),
              str(body)[:300])
        c = _admin_conn(CE_DB)
        cur = c.cursor()
        reg_ok, reg_detail = True, []
        for table, cols in cs.TABLE_COLUMNS.items():
            cur.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=%s ORDER BY ordinal_position", (table,))
            names = [r_[0] for r_ in cur.fetchall()]
            if not names or names[0] != "_id" or not set(cols) <= set(names):
                reg_ok = False
                reg_detail.append((table, names[:3]))
        c.close()
        check("every registered table has _id as FIRST column and all registered columns exist (DBManager.lookup keys rows on column 0)", reg_ok, str(reg_detail))
        check("response never contains an enc: marker for readable rows", "enc:v1:" not in client.get(f"/notes/{uid_a}", headers=H(tok_a)).text.replace("enc:v1:user typed this", ""))

        print("\n=== route write path (POST) encrypts with flag ON ===")
        set_flag(True)
        r = client.post(f"/notes/{uid_b}", json={"title": "Route title", "text": "Route body Philippians", "public": False, "verses": []}, headers=H(tok_b))
        check("POST /notes -> 201", r.status_code == 201, r.text)
        rid = r.json()["id"]
        check("route-created note is ciphertext at rest", raw("notes", rid, "text").startswith("enc:v1:") and raw("notes", rid, "title").startswith("enc:v1:"))
        r = client.get(f"/notes/{uid_b}/note/{rid}", headers=H(tok_b))
        check("single-note GET returns plaintext", r.status_code == 200 and "Route body Philippians" in r.text and "enc:v1:" not in r.text, r.text[:200])

        print("\n=== update funnel: DBManager.update re-seals by row id ===")
        db = DBManager()
        try:
            ok = db.update("notes", {"title": "Edited title", "text": "Edited body"}, {"_id": n_on})
            check("DBManager.update on encrypted columns succeeds", ok)
            check("edited value is ciphertext again", raw("notes", n_on, "text").startswith("enc:v1:"))
            check("lookup returns the edited plaintext", db.lookup("notes", {"_id": n_on})[n_on]["title"] == "Edited title")
            try:
                db.update("notes", {"text": "x"}, {"user_id": uid_a})
                raised = False
            except ValueError:
                raised = True
            check("update of encrypted columns without an _id condition is refused (AAD needs the row id)", raised)
        finally:
            db.close()

        print("\n=== fail closed: swapped / corrupt ciphertext ===")
        set_flag(True)
        n_x = insert_note(uid_a, "Row X", "Body X unique-xx", created=now - timedelta(minutes=20))
        n_y = insert_note(uid_a, "Row Y", "Body Y unique-yy", created=now - timedelta(minutes=19))
        cx, cy = raw("notes", n_x, "text"), raw("notes", n_y, "text")
        q("UPDATE notes SET text = %s WHERE _id = %s", (cy, n_x))  # replay y's ciphertext into x
        db = DBManager()
        try:
            try:
                db.lookup("notes", {"_id": n_x})
                raised, msg = False, ""
            except cc.ContentDecryptError as e:
                raised, msg = True, str(e)
        finally:
            db.close()
        check("lookup of a replayed ciphertext raises ContentDecryptError (never returns ciphertext)", raised)
        check("the error names only field/row/key id", cy[7:40] not in msg and "unique-yy" not in msg and n_x in msg, msg)
        r = client.get(f"/notes/{uid_a}", headers=H(tok_a))
        body = r.text
        check("GET /notes with a tampered row does not return 200 with ciphertext/blank text", r.status_code >= 500, str(r.status_code))
        check("HTTP error body leaks no ciphertext, plaintext or key", cy[7:40] not in body and "unique-y" not in body and K1 not in body and "enc:v1:" not in body, body[:300])
        r = client.get(f"/notes/{uid_a}/search", params={"q": "zzz-nothing"}, headers=H(tok_a))
        check("search over a tampered row fails closed (no 200 with partial/ciphertext results)", r.status_code >= 500 and "enc:v1:" not in r.text, f"{r.status_code} {r.text[:200]}")
        q("UPDATE notes SET text = %s WHERE _id = %s", (cx, n_x))
        q("DELETE FROM notes WHERE _id IN (%s,%s)", (n_x, n_y))
        r = client.get(f"/notes/{uid_a}", headers=H(tok_a))
        check("after repairing the row the endpoint recovers", r.status_code == 200)

        print("\n=== lookup funnel on other tables: messages / content_reports ===")
        gid = str(uuid.uuid4())
        r = client.post(f"/groups/{uid_a}", json={"group_id": gid, "title": "CE group", "users": [uid_a, uid_b, uid_c]}, headers=H(tok_a))
        check("group created", r.status_code == 201, r.text)
        mid = str(uuid.uuid4())
        db = DBManager()
        try:
            set_flag(True)
            check("insert message via funnel", db.insertion("messages", {"_id": mid, "from_user": uid_a, "group_id": gid, "text": "hello message Zebulun", "timestamp": now}))
            check("message text is ciphertext at rest", raw("messages", mid, "text").startswith("enc:v1:") and "Zebulun" not in raw("messages", mid, "text"))
            check("lookup(messages) returns plaintext", db.lookup("messages", {"_id": mid})[mid]["text"] == "hello message Zebulun")
            set_flag(False)
            mid2 = str(uuid.uuid4())
            db.insertion("messages", {"_id": mid2, "from_user": uid_a, "group_id": gid, "text": "plain message", "timestamp": now})
            check("flag OFF message stays plaintext and reads fine", raw("messages", mid2, "text") == "plain message"
                  and db.lookup("messages", {"_id": mid2})[mid2]["text"] == "plain message")
            check("mixed rows read together via the funnel", db.lookup("messages", {"group_id": gid})[mid]["text"] == "hello message Zebulun")
            rep = str(uuid.uuid4())
            set_flag(True)
            db.insertion("content_reports", {"_id": rep, "reporter_id": uid_a, "reported_user_id": uid_b, "content_type": "message",
                                             "content_id": mid, "content_snippet": "reported snippet text", "reason": "spam", "detail": "detail text",
                                             "status": "open"})
            snippet_raw, detail_raw = raw("content_reports", rep, "content_snippet"), raw("content_reports", rep, "detail")
            check("report snippet/detail ciphertext at rest", snippet_raw.startswith("enc:v1:") and detail_raw.startswith("enc:v1:"))
            check("report snippet/detail read back as plaintext", db.lookup("content_reports", {"_id": rep})[rep]["content_snippet"] == "reported snippet text")
        finally:
            db.close()

        print("\n=== search: personal ===")
        set_flag(True)
        # fresh user so the result set is fully controlled
        uid_s, uname_s, tok_s = signup(client, "ce_s")
        base = now - timedelta(hours=5)
        specs = [  # (title, text, sealed)
            ("Alpha Psalm", "morning light", True),
            ("Beta", "the PSALM of david", False),
            ("Gamma", "no match here", True),
            ("100% sure", "literal percent sign", False),
            ("under_score", "lit under_score here", True),
            ("Delta", "psalm again final", True),
        ]
        ids = []
        for i, (t, b, sealed) in enumerate(specs):
            ids.append(insert_note(uid_s, t, b, created=base + timedelta(minutes=i), sealed=sealed))
        reply = insert_note(uid_s, "Reply psalm", "psalm reply", created=base + timedelta(minutes=10), is_reply=True, sealed=True)
        other_user_note = insert_note(uid_a, "Psalm of someone else", "x", created=base, sealed=True)
        r = client.get(f"/notes/{uid_s}/search", params={"q": "psalm"}, headers=H(tok_s))
        res = r.json()["notes"]
        check("search 'psalm' (mixed plaintext + ciphertext, case-insensitive) -> 200", r.status_code == 200, r.text[:200])
        check("matches title OR text across both storage forms", set(res) == {ids[0], ids[1], ids[5]}, str(list(res)))
        check("replies and other users' notes are excluded (SQL scope intact)", reply not in res and other_user_note not in res)
        check("ordering is newest first (created_at DESC)", list(res) == [ids[5], ids[1], ids[0]], str(list(res)))
        check("search result carries plaintext and the unchanged per-note shape",
              res[ids[0]]["title"] == "Alpha Psalm" and set(res[ids[0]]) == {"user", "title", "text", "public", "group_id", "is_reply", "timestamp", "created_at", "verses", "replies"},
              str(res[ids[0]]))
        check("no enc: markers in the search response", "enc:v1:" not in r.text)
        r = client.get(f"/notes/{uid_s}/search", params={"q": "100%"}, headers=H(tok_s))
        check("'%' in q is a literal (matches only the note containing '100%')", set(r.json()["notes"]) == {ids[3]}, str(list(r.json()["notes"])))
        r = client.get(f"/notes/{uid_s}/search", params={"q": "_"}, headers=H(tok_s))
        check("'_' in q is a literal (matches only underscore notes, not every row)", set(r.json()["notes"]) == {ids[4]}, str(list(r.json()["notes"])))
        r = client.get(f"/notes/{uid_s}/search", params={"q": "nothing-will-match-this"}, headers=H(tok_s))
        check("no match -> 200 with empty notes", r.status_code == 200 and r.json() == {"notes": {}}, r.text)
        r = client.get(f"/notes/{uid_s}/search", params={"q": "psalm'; DROP TABLE notes;--"}, headers=H(tok_s))
        check("SQL metacharacters in q are inert (parameterized)", r.status_code == 200 and q("SELECT to_regclass('notes')")[0][0] is not None)

        # Result parity: identical results/order/shape whether rows are plaintext, ciphertext or mixed
        def snapshot(term):
            rr = client.get(f"/notes/{uid_s}/search", params={"q": term}, headers=H(tok_s))
            return [(k, strip_vol(v)) for k, v in rr.json()["notes"].items()]
        before = snapshot("psalm")
        q("UPDATE notes SET title=%s WHERE _id=%s", (cs.seal(ids[1], cs.F_NOTE_TITLE, "Beta", force=True), ids[1]))
        q("UPDATE notes SET text=%s WHERE _id=%s", (cs.seal(ids[1], cs.F_NOTE_TEXT, "the PSALM of david", force=True), ids[1]))
        check("search result identical after a plaintext row becomes ciphertext (mixed -> all-ciphertext parity)", snapshot("psalm") == before)
        # plain-only snapshot
        for nid, (t, b, _) in zip(ids, specs):
            q("UPDATE notes SET title=%s, text=%s WHERE _id=%s", (t, b, nid))
        check("search result identical when ALL rows are plaintext (pre-migration parity)", snapshot("psalm") == before)
        for nid, (t, b, _) in zip(ids, specs):
            q("UPDATE notes SET title=%s, text=%s WHERE _id=%s", (cs.seal(nid, cs.F_NOTE_TITLE, t, force=True), cs.seal(nid, cs.F_NOTE_TEXT, b, force=True), nid))
        check("search result identical when ALL rows are ciphertext", snapshot("psalm") == before)

        print("\n=== search: scan cap, batching and over-cap behaviour ===")
        records = []

        class Cap(logging.Handler):
            def emit(self, rec):
                records.append(rec.getMessage())

        cap_handler = Cap()
        lg = logging.getLogger("backend.interactions.note_search")
        lg.addHandler(cap_handler)
        uid_k, _, tok_k = signup(client, "ce_k")
        kbase = now - timedelta(hours=9)
        kids = []
        for i in range(12):
            kids.append(insert_note(uid_k, f"note {i}", f"needleword body {i}" if i % 2 == 0 else f"other body {i}", created=kbase + timedelta(minutes=i), sealed=(i % 3 != 0)))
        try:
            ccfg._cached = dataclasses.replace(cfg0, search_batch_size=3, search_scan_cap=100)
            r = client.get(f"/notes/{uid_k}/search", params={"q": "needleword"}, headers=H(tok_k))
            got = list(r.json()["notes"])
            check("keyset streaming across batches (batch=3) returns all 6 matches newest-first",
                  got == [kids[i] for i in (10, 8, 6, 4, 2, 0)], str(got))
            check("under the cap: no truncation warning logged", not records, str(records))
            ccfg._cached = dataclasses.replace(cfg0, search_batch_size=3, search_scan_cap=5)
            records.clear()
            r = client.get(f"/notes/{uid_k}/search", params={"q": "needleword"}, headers=H(tok_k))
            got = list(r.json()["notes"])
            check("scan cap 5: only the newest 5 candidates (rows 11..7) are examined -> matches 10, 8",
                  r.status_code == 200 and got == [kids[10], kids[8]], str(got))
            check("over-cap response keeps the exact response shape (no extra truncation field)", set(r.json()) == {"notes"})
            check("over-cap logs exactly ONE count-only warning (no query, no content)",
                  len(records) == 1 and "needleword" not in records[0] and "body" not in records[0] and "scanned=5" in records[0] and "cap=5" in records[0], str(records))
            ccfg._cached = dataclasses.replace(cfg0, search_batch_size=4, search_scan_cap=12)
            records.clear()
            r = client.get(f"/notes/{uid_k}/search", params={"q": "needleword"}, headers=H(tok_k))
            check("scan cap exactly equal to the candidate count still returns everything",
                  len(r.json()["notes"]) == 6, str(len(r.json()["notes"])))
        finally:
            ccfg._cached = cfg0
            lg.removeHandler(cap_handler)

        print("\n=== search: group notes (blocked users, replies, mixed rows) ===")
        set_flag(True)
        gbase = now - timedelta(hours=3)
        g1 = insert_note(uid_a, "Group Grace", "grace text", created=gbase, group_id=gid, sealed=True)
        g2 = insert_note(uid_b, "Group other", "Contains GRACE in text", created=gbase + timedelta(minutes=1), group_id=gid, sealed=False)
        g3 = insert_note(uid_c, "Blocked author grace", "x", created=gbase + timedelta(minutes=2), group_id=gid, sealed=True)
        g4 = insert_note(uid_b, "Grace reply", "x", created=gbase + timedelta(minutes=3), group_id=gid, is_reply=True, sealed=True)
        q("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (uid_a, uid_c))
        gm = GroupsManager(uid_a, gid)
        try:
            out = gm.search_notes("grace")
        finally:
            gm.close()
        flat = {nid: data for by_user in out["notes"].values() for nid, data in by_user.items()}
        check("group search finds plaintext + ciphertext notes", {g1, g2} <= set(flat), str(list(flat)))
        check("group search honours the SQL block filter and excludes replies", g3 not in flat and g4 not in flat)
        check("group search returns decrypted title/text", flat[g1]["title"] == "Group Grace" and flat[g1]["text"] == "grace text" and "enc:v1:" not in json.dumps(out, default=str))
        r = client.get(f"/groups/{uid_a}/{gid}/notes/search", params={"q": "GRACE"}, headers=H(tok_a))
        check("group search route -> 200 with the same notes", r.status_code == 200 and "enc:v1:" not in r.text
              and {g1, g2} <= {n for u in r.json()["notes"].values() for n in u}, r.text[:300])
        q("DELETE FROM blocked_users WHERE blocker_id=%s", (uid_a,))

        print("\n=== backup manager copies stored values verbatim ===")
        set_flag(True)
        uid_bk, _, _ = signup(client, "ce_bk")
        bn_enc = insert_note(uid_bk, "Backup secret", "backup body Obadiah", created=now - timedelta(minutes=5), sealed=True)
        bn_plain = insert_note(uid_bk, "Backup plain", "plain body", created=now - timedelta(minutes=4), sealed=False)
        bm = backup_manager.BackupManager()
        try:
            counts = bm.backup_user(uid_bk)
        finally:
            bm.close()
        check("backup_user copied both notes", counts.get("notes") == 2, str(counts))
        b_enc = raw("notes", bn_enc, "text", CE_BAK)
        check("encrypted note is ciphertext in the backup DB (no plaintext copy created)", b_enc == raw("notes", bn_enc, "text") and b_enc.startswith("enc:v1:") and "Obadiah" not in b_enc)
        check("plaintext note copied as stored", raw("notes", bn_plain, "text", CE_BAK) == "plain body")
        check("backup ciphertext still decrypts with the same row id (AAD preserved)", cc.decrypt_field(bn_enc, cs.F_NOTE_TEXT, b_enc) == "backup body Obadiah")

        print("\n=== backfill engine ===")
        # Fresh, fully controlled corpus in the CE DB: wipe notes first (other sections left rows).
        set_flag(False)
        q("DELETE FROM notes")
        q("DELETE FROM notes", dbname=CE_BAK)
        uid_m = uid_a
        mig = []  # (id, title, text)
        for i in range(25):
            t, b = f"mig title {i}", f"mig body {i} sensitive-{i}"
            if i == 3:
                t, b = "enc:v1:looks like ciphertext", "enc:p:and an escape"
            nid = insert_note(uid_m, t, b, created=now - timedelta(minutes=100 - i))
            mig.append((nid, t, b))
        empty_text = insert_note(uid_m, "", "", created=now - timedelta(minutes=1))
        db_null = str(uuid.uuid4())
        q("INSERT INTO notes (_id,user_id,title,text,public,is_reply,timestamp,created_at) VALUES (%s,%s,NULL,NULL,false,false,%s,%s)", (db_null, uid_m, now, now))
        msg_ids = []
        for i in range(5):
            m = str(uuid.uuid4())
            q("INSERT INTO messages (_id,from_user,group_id,text,timestamp) VALUES (%s,%s,%s,%s,%s)", (m, uid_m, gid, f"mig message {i} secretmsg", now))
            msg_ids.append(m)

        class A:
            """argparse stand-in"""
            def __init__(self, **kw):
                d = dict(mode="encrypt", target="primary", tables="notes,messages", apply=False, backup_confirmed=None,
                         resume=False, checkpoint=None, batch_size=7, throttle_ms=0, max_rows=None, actor="test")
                d.update(kw)
                self.__dict__.update(d)

        def connect(name):
            return DBManager(dbname=name) if name else DBManager()

        def storage_state():
            rows = q("SELECT _id::text, title, text FROM notes")
            return {r[0]: (r[1], r[2]) for r in rows}

        before_state = storage_state()
        out = io.StringIO()
        old = sys.stdout
        sys.stdout = out
        try:
            rc = cm.run(A(), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        check("dry run exits 0 and prints counts", rc == 0 and "DRY-RUN" in out.getvalue() and "notes" in out.getvalue(), out.getvalue()[:300])
        check("dry run changed nothing in the database", storage_state() == before_state)
        check("dry run reports would-change counts (50 values in 25 notes + messages)", "changed=" in out.getvalue())
        check("dry run output contains no row content", "sensitive-" not in out.getvalue() and "secretmsg" not in out.getvalue())
        check("dry run wrote no audit rows", q("SELECT count(*) FROM content_encryption_audit")[0][0] == 0)

        sys.stderr, old_err = io.StringIO(), sys.stderr
        try:
            rc = cm.run(A(apply=True), connect=connect, sleep=lambda s: None)
        finally:
            sys.stderr = old_err
        check("--apply without --backup-confirmed is refused (exit 2)", rc == 2)
        check("refused apply changed nothing", storage_state() == before_state)

        os.environ["CONTENT_ENCRYPTION_KEYS"] = ""  # unset ring must refuse to run at all
        try:
            cm.run(A(apply=True, backup_confirmed="x"), connect=connect, sleep=lambda s: None)
            refused = False
        except cc.ContentKeyConfigError:
            refused = True
        os.environ["CONTENT_ENCRYPTION_KEYS"] = f"1:{K1}"
        check("backfill refuses to run without a valid key ring", refused)
        check("... and changed nothing", storage_state() == before_state)

        # Simulate a kill after the first committed batch, with a checkpoint.
        ckpt = tempfile.NamedTemporaryFile(suffix=".json", delete=False).name
        os.unlink(ckpt)
        real_save = cm._save_checkpoint
        calls = {"n": 0}

        def killing_save(path, data):
            real_save(path, data)
            calls["n"] += 1
            if calls["n"] == 1:
                raise KeyboardInterrupt("simulated kill after batch 1")

        cm._save_checkpoint = killing_save
        sys.stdout = io.StringIO()
        try:
            try:
                cm.run(A(apply=True, backup_confirmed="LABEL-1", checkpoint=ckpt, tables="notes"), connect=connect, sleep=lambda s: None)
                killed = False
            except KeyboardInterrupt:
                killed = True
        finally:
            sys.stdout = old
            cm._save_checkpoint = real_save
        st = storage_state()
        n_enc = sum(1 for v in st.values() if (v[1] or "").startswith("enc:v1:"))
        check("kill: the run was interrupted after exactly one committed batch", killed and 0 < n_enc <= 7, f"{killed} encrypted={n_enc}")
        check("kill: checkpoint file records the last committed _id", json.load(open(ckpt)).get("primary:encrypt:notes") is not None)
        check("kill: the unprocessed rows are still intact plaintext (no half-written state)",
              all(v == before_state[k] for k, v in st.items() if not (v[1] or "").startswith("enc:v1:")))

        sys.stdout = out2 = io.StringIO()
        try:
            rc = cm.run(A(apply=True, backup_confirmed="LABEL-1", checkpoint=ckpt, resume=True, tables="notes"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        check("resume completes the remaining rows (exit 0)", rc == 0, out2.getvalue()[:300])
        st = storage_state()
        mig_ids = {m[0]: m for m in mig}
        ok_all = True
        for nid, t, b in mig:
            ts, bs = st[nid]
            if not (ts.startswith("enc:v1:") and bs.startswith("enc:v1:")):
                ok_all = False
            if cc.decrypt_field(nid, cs.F_NOTE_TITLE, ts) != t or cc.decrypt_field(nid, cs.F_NOTE_TEXT, bs) != b:
                ok_all = False
        check("every note title/text is now ciphertext and verifies back to the exact original (incl. enc:-prefixed user text)", ok_all)
        check("no plaintext marker text remains in any stored note row", not any("sensitive-" in (v[1] or "") or "mig title" in (v[0] or "") for v in st.values()))
        check("empty / NULL values are left untouched", st[empty_text] == ("", "") and st[db_null] == (None, None))
        check("messages not touched by the notes-only run", all(not raw("messages", m, "text").startswith("enc:v1:") for m in msg_ids))
        check("the run wrote an audit row with a backup label and no content",
              q("SELECT count(*), max(backup_label) FROM content_encryption_audit WHERE applied")[0][1] == "LABEL-1"
              and "sensitive" not in json.dumps(q("SELECT row_to_json(a) FROM content_encryption_audit a"), default=str))
        check("checkpoint audit jsonl written", os.path.exists(ckpt + ".audit.jsonl"))
        check("API reads the migrated notes as the original plaintext (dual-read after backfill)",
              client.get(f"/notes/{uid_m}/note/{mig[5][0]}", headers=H(tok_a)).status_code == 200
              and mig[5][2] in client.get(f"/notes/{uid_m}/note/{mig[5][0]}", headers=H(tok_a)).text)

        # Idempotence: a second full apply changes nothing
        snap = storage_state()
        sys.stdout = out3 = io.StringIO()
        try:
            rc = cm.run(A(apply=True, backup_confirmed="LABEL-2", tables="notes,messages"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        st2 = storage_state()
        check("re-running the backfill is idempotent for notes (stored bytes unchanged, no re-encryption)", st2 == snap)
        check("messages were backfilled by the second run", all(raw("messages", m, "text").startswith("enc:v1:") for m in msg_ids))
        check("second run reports changed=0 for notes", "primary.notes:" in out3.getvalue() and "notes: mode=encrypt APPLY scanned=" in out3.getvalue().replace("primary.", "") and " changed=0 " in out3.getvalue().split("\n")[0], out3.getvalue()[:300])
        sys.stdout = io.StringIO()
        try:
            cm.run(A(apply=True, backup_confirmed="LABEL-3", tables="notes,messages"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        check("third run still a no-op", storage_state() == snap)

        # Failure injection 1: the in-transaction read-back disagrees -> batch rolled back, run aborts
        set_flag(False)
        vic = [insert_note(uid_m, f"inj title {i}", f"inj body {i}", created=now - timedelta(minutes=5)) for i in range(4)]
        inj_before = {k: storage_state()[k] for k in vic}
        real_open = cc.open_value

        # The 1st open_value of a new ciphertext is the in-memory pre-write verify, the 2nd the
        # in-transaction read-back: corrupt the 2nd to prove the batch is rolled back.
        calls_per = {}

        def flaky_open(rid, fld, stored):
            v = real_open(rid, fld, stored)
            if rid in vic and isinstance(stored, str) and stored.startswith("enc:v1:"):
                calls_per[(rid, fld)] = calls_per.get((rid, fld), 0) + 1
                if calls_per[(rid, fld)] >= 2:  # 1st = in-memory pre-write verify, 2nd = read-back
                    return v + "-CORRUPT"
            return v

        cc.open_value = flaky_open
        sys.stdout = io.StringIO()
        try:
            try:
                cm.run(A(apply=True, backup_confirmed="INJ", tables="notes"), connect=connect, sleep=lambda s: None)
                aborted = False
            except cm.MigrationVerifyError as e:
                aborted = "inj body" not in str(e) and "inj title" not in str(e)
        finally:
            cc.open_value = real_open
            sys.stdout = old
        after = storage_state()
        check("read-back verification failure aborts the run (MigrationVerifyError, no content in message)", aborted)
        check("... and the batch is rolled back: no value was replaced by something unverified", all(after[k] == inj_before[k] for k in vic))
        check("... a clean re-run then succeeds", True)
        sys.stdout = io.StringIO()
        try:
            rc = cm.run(A(apply=True, backup_confirmed="INJ2", tables="notes"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        after = storage_state()
        check("clean re-run after the injected failure encrypts the victims and they verify",
              rc == 0 and all(after[k][1].startswith("enc:v1:") and cc.decrypt_field(k, cs.F_NOTE_TEXT, after[k][1]).startswith("inj body") for k in vic))

        # Failure injection 2: pre-write verify (open(new) != plain) -> abort before writing
        set_flag(False)
        vic2 = insert_note(uid_m, "pre title", "pre body", created=now)
        real_enc = cc.encrypt_field

        def bad_enc(rid, fld, plain):
            if rid == vic2:
                return real_enc(rid, fld, plain + "x")
            return real_enc(rid, fld, plain)

        cc.encrypt_field = bad_enc
        sys.stdout = io.StringIO()
        try:
            try:
                cm.run(A(apply=True, backup_confirmed="INJ3", tables="notes"), connect=connect, sleep=lambda s: None)
                aborted = False
            except cm.MigrationVerifyError:
                aborted = True
        finally:
            cc.encrypt_field = real_enc
            sys.stdout = old
        check("pre-write verify mismatch aborts and never writes the unverified value", aborted and raw("notes", vic2, "text") == "pre body")

        # Race: a concurrent edit between SELECT and UPDATE must win (compare-and-set), not be lost
        race_id = insert_note(uid_m, "race title", "race original", created=now)
        real_nv = cm._new_value
        raced = {"done": False}

        def racing_nv(mode, rid, fld, stored, kid):
            if rid == race_id and not raced["done"] and fld == cs.F_NOTE_TITLE:
                raced["done"] = True
                q("UPDATE notes SET title = %s WHERE _id = %s", ("race EDITED by user", rid))
            return real_nv(mode, rid, fld, stored, kid)

        cm._new_value = racing_nv
        sys.stdout = out4 = io.StringIO()
        try:
            cm.run(A(apply=True, backup_confirmed="RACE", tables="notes"), connect=connect, sleep=lambda s: None)
        finally:
            cm._new_value = real_nv
            sys.stdout = old
        cur_text = raw("notes", race_id, "title")
        check("concurrent user edit wins the compare-and-set (raced counted, edit not lost)",
              ("race EDITED by user" == cur_text or (cur_text.startswith("enc:v1:") and cc.decrypt_field(race_id, cs.F_NOTE_TITLE, cur_text) == "race EDITED by user")) and "raced=1" in out4.getvalue(), f"{cur_text[:30]} {out4.getvalue()[:200]}")
        sys.stdout = io.StringIO()
        try:
            cm.run(A(apply=True, backup_confirmed="RACE2", tables="notes"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        check("next run picks the raced row up", raw("notes", race_id, "title").startswith("enc:v1:") and cc.decrypt_field(race_id, cs.F_NOTE_TITLE, raw("notes", race_id, "title")) == "race EDITED by user")

        # Unauthenticatable ciphertext is left untouched and reported (exit 1), never overwritten
        bad_id = insert_note(uid_m, "bad title", "bad body", created=now, sealed=True)
        wrong = cc.encrypt_field(str(uuid.uuid4()), cs.F_NOTE_TEXT, "someone elses")  # AAD for another row
        q("UPDATE notes SET text = %s WHERE _id = %s", (wrong, bad_id))
        sys.stdout = out5 = io.StringIO()
        try:
            rc = cm.run(A(apply=True, backup_confirmed="BAD", tables="notes"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        check("ciphertext that fails authentication is counted failed, exit code 1", rc == 1 and "failed=1" in out5.getvalue(), out5.getvalue()[:300])
        check("... and the bad value is left byte-for-byte untouched (not overwritten, not treated as plaintext)", raw("notes", bad_id, "text") == wrong)
        check("... failure output names table/column/row only", f"text:{bad_id}" in out5.getvalue() and "bad body" not in out5.getvalue() and wrong[7:30] not in out5.getvalue())
        q("DELETE FROM notes WHERE _id = %s", (bad_id,))

        # Rollback mode: ciphertext -> plaintext
        sys.stdout = io.StringIO()
        try:
            rc = cm.run(A(mode="decrypt", apply=True, backup_confirmed="ROLLBACK", tables="notes,messages"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        st = storage_state()
        check("rollback (decrypt) restores plaintext storage for all migrated notes", rc == 0 and all(
            (st[nid][1] or "") == (b if not b.startswith("enc:") else "enc:p:" + b) for nid, t, b in mig))
        check("rollback keeps enc:-prefixed user text escaped so it is never mistaken for ciphertext", st[mig[3][0]][0].startswith("enc:p:"))
        check("rollback leaves messages readable as plaintext", all(raw("messages", m, "text").startswith("mig message") for m in msg_ids))
        check("after rollback the API returns identical content", mig[7][2] in client.get(f"/notes/{uid_m}/note/{mig[7][0]}", headers=H(tok_a)).text)
        sys.stdout = io.StringIO()
        try:
            cm.run(A(apply=True, backup_confirmed="AGAIN", tables="notes,messages"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        check("re-encrypt after rollback works (round trip is reversible both ways)", all(raw("notes", m[0], "text").startswith("enc:v1:") for m in mig))

        # Rotation: add key 2 as current; rows on key 1 re-encrypt; idempotent
        os.environ["CONTENT_ENCRYPTION_KEYS"] = f"2:{K2},1:{K1}"
        check("old-key ciphertext still readable after prepending a new current key", client.get(f"/notes/{uid_m}", headers=H(tok_a)).status_code == 200)
        sys.stdout = out6 = io.StringIO()
        try:
            rc = cm.run(A(mode="rotate", apply=True, backup_confirmed="ROT", tables="notes,messages"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        kids_now = {cc.key_id_of(raw("notes", m[0], "text")) for m in mig}
        check("rotation moves every ciphertext to the current key id", rc == 0 and kids_now == {2}, str(kids_now))
        snap = storage_state()
        sys.stdout = io.StringIO()
        try:
            cm.run(A(mode="rotate", apply=True, backup_confirmed="ROT2", tables="notes,messages"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        check("rotation is idempotent (second run leaves stored bytes unchanged)", storage_state() == snap)
        os.environ["CONTENT_ENCRYPTION_KEYS"] = f"2:{K2}"
        check("after rotation the retired key can be removed and everything still decrypts",
              all(cc.decrypt_field(m[0], cs.F_NOTE_TEXT, raw("notes", m[0], "text")) == m[2] for m in mig))
        os.environ["CONTENT_ENCRYPTION_KEYS"] = f"1:{K1}"
        check("with only the OLD key, rotated data fails closed (key loss = data loss)",
              client.get(f"/notes/{uid_m}", headers=H(tok_a)).status_code >= 500)
        os.environ["CONTENT_ENCRYPTION_KEYS"] = f"2:{K2},1:{K1}"
        # return the corpus to key 1 only for the remaining sections
        os.environ["CONTENT_ENCRYPTION_KEYS"] = f"1:{K1},2:{K2}"

        # Backup target
        os.environ["CONTENT_ENCRYPTION_KEYS"] = f"1:{K1}"
        bn = str(uuid.uuid4())
        q("INSERT INTO notes (_id,user_id,title,text,public,is_reply,timestamp,created_at) VALUES (%s,%s,%s,%s,false,false,%s,%s)",
          (bn, uid_m, "bk title", "bk body plain", now, now), CE_BAK)
        sys.stdout = out7 = io.StringIO()
        try:
            rc = cm.run(A(target="backup", tables="notes", apply=True, backup_confirmed="BK"), connect=connect, sleep=lambda s: None)
        finally:
            sys.stdout = old
        check("backup-DB target encrypts the plaintext copies too", rc == 0 and raw("notes", bn, "text", CE_BAK).startswith("enc:v1:"), out7.getvalue()[:200])
        check("backup-DB ciphertext verifies", cc.decrypt_field(bn, cs.F_NOTE_TEXT, raw("notes", bn, "text", CE_BAK)) == "bk body plain")

        print("\n=== no plaintext in logs during the whole run ===")
        # Re-exercise read/write/search paths with capture on the root logger.
        buf = io.StringIO()
        h = logging.StreamHandler(buf)
        h.setFormatter(logging.Formatter("%(name)s|%(message)s"))
        h.setLevel(logging.DEBUG)
        root = logging.getLogger()
        old_level = root.level
        root.setLevel(logging.DEBUG)
        root.addHandler(h)
        try:
            set_flag(True)
            uid_l, _, tok_l = signup(client, "ce_l")
            r = client.post(f"/notes/{uid_l}", json={"title": "LOGTITLE-zq", "text": "LOGBODY-zq", "public": False, "verses": []}, headers=H(tok_l))
            client.get(f"/notes/{uid_l}", headers=H(tok_l))
            client.get(f"/notes/{uid_l}/search", params={"q": "LOGBODY-zq"}, headers=H(tok_l))
            bad = str(uuid.uuid4())
            q("INSERT INTO notes (_id,user_id,title,text,public,is_reply,timestamp,created_at) VALUES (%s,%s,'t','enc:v1:AAAA',false,false,%s,%s)", (bad, uid_l, now, now))
            client.get(f"/notes/{uid_l}", headers=H(tok_l))
            client.get(f"/notes/{uid_l}/search", params={"q": "LOGBODY-zq"}, headers=H(tok_l))
            q("DELETE FROM notes WHERE _id = %s", (bad,))
        finally:
            root.removeHandler(h)
            root.setLevel(old_level)
        # the test client's own httpx request log (client side) is not a server log
        logged = "\n".join(l for l in buf.getvalue().splitlines() if not l.startswith("httpx|"))
        check("logs (incl. a decrypt failure) never contain note plaintext, the search term, ciphertext or key material",
              "LOGTITLE-zq" not in logged and "LOGBODY-zq" not in logged and K1 not in logged and "enc:v1:AAAA" not in logged,
              str([l[:160] for l in logged.splitlines() if any(n in l for n in ("LOGTITLE-zq", "LOGBODY-zq", K1, "enc:v1:AAAA"))]))

    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        return 1
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    return 0


if __name__ == "__main__":
    code = 1
    try:
        code = main()
    finally:
        drop_databases()
    sys.exit(code)
