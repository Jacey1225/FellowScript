"""Tests for task 20261009-verse-reactions: emoji reactions on Bible verse highlights
(flag ``verse_reactions``). Scratch database only (port 55432).

Proves: highlights.emoji column exists and create_tables is idempotent; flag registered
and seeded off; flag off -> emoji 400 with no write while plain highlights still work;
flag on -> allowlist (all 10 accepted, lookalikes/skin-tone/multi/oversized/non-string
rejected 400); emoji without color stores the neutral color; GET default shape unchanged
({key: color}) and ?include_emoji=true shape; re-react upserts one row and refreshes
timestamp; plain re-highlight clears emoji; delete removes; authz; highlight search
returns emoji (own + friend) and null for plain.

Run:  cd api && ../.venv/bin/python tests/test_verse_reactions.py
"""
import _pathfix  # noqa: F401,E402

import os
import sys
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from fastapi.testclient import TestClient  # noqa: E402
from db import DBManager  # noqa: E402
import main as main_module  # noqa: E402
from backend.interactions import flags  # noqa: E402
from backend.interactions import verse_reactions as vr  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


_ctr = 0


def signup(client, prefix):
    global _ctr
    _ctr += 1
    username = f"{prefix}{uuid.uuid4().hex[:8]}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    }, headers={"cf-connecting-ip": f"198.51.101.{_ctr % 250 + 1}"})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def hdr(tok):
    return {"cookie": f"session={tok}"}


def q(sqlstr, params=(), fetch=False):
    db = DBManager()
    try:
        db.cur.execute(sqlstr, params)
        rows = db.cur.fetchall() if fetch else None
        db.conn.commit()
        return rows
    finally:
        db.close()


def set_flag(state):
    flags.set_flag(vr.FLAG_NAME, state, actor="test")
    flags.invalidate()


def post(client, uid, tok, **body):
    base = {"book": "John", "chapter": 3, "verse": 16}
    base.update(body)
    return client.post(f"/notes/highlight/{uid}", json=base, headers=hdr(tok))


def test_all(client):
    me, tme = signup(client, "vrme")
    fr, tfr = signup(client, "vrfr")
    stranger, tst = signup(client, "vrst")
    uids = [me, fr, stranger]
    try:
        print("=== schema + flag ===")
        cols = q("SELECT data_type, is_nullable FROM information_schema.columns "
                 "WHERE table_name='highlights' AND column_name='emoji'", fetch=True)
        check("highlights.emoji exists, text, nullable", cols == [("text", "YES")], cols)
        import db as db_module
        ran_twice = True
        try:
            for _ in range(2):
                d = DBManager()
                try:
                    db_module.create_tables(d.cur)
                    d.conn.commit()
                finally:
                    d.close()
        except Exception as e:
            ran_twice = repr(e)
        check("emoji DDL idempotent (twice)", ran_twice is True, ran_twice)
        check("flag registered", vr.FLAG_NAME in flags._REGISTRY)
        check("flag off for user by default", flags.is_enabled(vr.FLAG_NAME, me) is False)
        check("flag exposed in capabilities", flags._REGISTRY[vr.FLAG_NAME].exposed_in_capabilities is True)
        check("allowlist has 10 distinct emoji", len(set(vr.VERSE_REACTION_EMOJI)) == 10)

        print("=== flag off ===")
        set_flag("off")
        r = post(client, me, tme, emoji="\U0001F525")
        check("emoji with flag off -> 400", r.status_code == 400, r.text)
        check("no row written on flag-off emoji",
              q("SELECT 1 FROM highlights WHERE user_id=%s", (me,), fetch=True) == [])
        r = post(client, me, tme, color="#FFD60A")
        check("plain highlight with flag off still 200", r.status_code == 200, r.text)
        check("plain response emoji null", r.json().get("emoji") is None, r.text)
        r = client.get(f"/notes/highlight/{me}", headers=hdr(tme))
        check("GET default shape {key: color}", r.json() == {"John-3-16": "#FFD60A"}, r.text)
        r = client.get(f"/notes/highlight/{me}", params={"include_emoji": "true"}, headers=hdr(tme))
        check("include_emoji shape, emoji null", r.json() == {"John-3-16": {"color": "#FFD60A", "emoji": None}}, r.text)

        print("=== flag on: validation ===")
        set_flag("on")
        for e in vr.VERSE_REACTION_EMOJI:
            r = post(client, me, tme, verse=17, emoji=e)
            if r.status_code != 200:
                check(f"allowlisted {e!r} accepted", False, r.text)
                break
        else:
            check("all 10 allowlisted emoji accepted", True)
        bad = ["\U0001F44D\U0001F3FD", "\U0001F600", "❤", "<b>x</b>", "ab", "\U0001F525\U0001F525",
               "x" * 100, "\U0001F4A9", " \U0001F525", "‍"]
        for e in bad:
            r = post(client, me, tme, verse=18, emoji=e)
            check(f"rejected {repr(e)[:20]}", r.status_code == 400, f"{r.status_code} {r.text}")
        for e in (5, ["\U0001F525"], {"a": 1}, True):
            r = post(client, me, tme, verse=18, emoji=e)
            check(f"non-string {e!r} rejected", r.status_code == 400, f"{r.status_code}")
        check("no row written for rejected emoji",
              q("SELECT 1 FROM highlights WHERE user_id=%s AND key='John-3-18'", (me,), fetch=True) == [])
        r = post(client, me, tme, verse=19, emoji="")
        check("empty emoji + no color -> 400 (nothing to store)", r.status_code == 400, r.text)

        print("=== neutral color, upsert, clear ===")
        r = post(client, me, tme, verse=20, emoji="\U0001F525")
        check("emoji without color 200", r.status_code == 200, r.text)
        check("neutral color default", r.json()["color"] == vr.NEUTRAL_COLOR == "#8E8E93", r.text)
        r = post(client, me, tme, verse=20, emoji="\U0001F525", color="#FF453A")
        check("emoji with color keeps color", r.json()["color"] == "#FF453A", r.text)
        t1 = q("SELECT timestamp FROM highlights WHERE user_id=%s AND key='John-3-20'", (me,), fetch=True)[0][0]
        r = post(client, me, tme, verse=20, emoji="\U0001F64F", color="#FF453A")
        rows = q("SELECT emoji, timestamp FROM highlights WHERE user_id=%s AND key='John-3-20'", (me,), fetch=True)
        check("re-react upserts one row", len(rows) == 1 and rows[0][0] == "\U0001F64F", rows)
        check("timestamp refreshed", rows[0][1] > t1, (t1, rows[0][1]))
        r = client.get(f"/notes/highlight/{me}", params={"include_emoji": "true"}, headers=hdr(tme))
        check("GET include_emoji returns emoji", r.json()["John-3-20"] == {"color": "#FF453A", "emoji": "\U0001F64F"}, r.text)
        r = client.get(f"/notes/highlight/{me}", headers=hdr(tme))
        check("GET default still plain color string", r.json()["John-3-20"] == "#FF453A", r.text)
        r = post(client, me, tme, verse=20, color="#30D158")
        check("plain re-highlight clears emoji",
              q("SELECT emoji FROM highlights WHERE user_id=%s AND key='John-3-20'", (me,), fetch=True) == [(None,)])
        post(client, me, tme, verse=20, emoji="\U0001F525")
        r = client.delete(f"/notes/highlight/{me}/John-3-20", headers=hdr(tme))
        check("delete removes reaction", r.status_code == 200 and
              q("SELECT 1 FROM highlights WHERE user_id=%s AND key='John-3-20'", (me,), fetch=True) == [])

        print("=== authz ===")
        r = post(client, fr, tme, emoji="\U0001F525")
        check("cannot react as another user (403)", r.status_code == 403, r.status_code)
        r = client.post(f"/notes/highlight/{me}", json={"book": "John", "chapter": 3, "verse": 16, "emoji": "\U0001F525"})
        check("unauthenticated (401)", r.status_code == 401, r.status_code)
        r = client.get(f"/notes/highlight/{me}", params={"include_emoji": "true"}, headers=hdr(tfr))
        check("cannot read another user's reactions (403)", r.status_code == 403, r.status_code)
        r = post(client, me, tme, book="Notabook", emoji="\U0001F525")
        check("invalid reference still 400", r.status_code == 400, r.text)

        print("=== search returns emoji ===")
        q("INSERT INTO user_friends (user_id, friend_id) VALUES (%s,%s),(%s,%s)", (me, fr, fr, me))
        post(client, fr, tfr, book="Psalms", chapter=23, verse=1, emoji="❤️")
        post(client, fr, tfr, book="Psalms", chapter=23, verse=2, color="#FFD60A")
        post(client, stranger, tst, book="Psalms", chapter=23, verse=3, emoji="\U0001F525")
        r = client.get(f"/notes/highlight/{me}/search", params={"q": "Psalms"}, headers=hdr(tme))
        check("search 200", r.status_code == 200, r.text)
        items = {h["key"]: h for h in r.json()["highlights"]}
        check("friend emoji returned", items.get("Psalms-23-1", {}).get("emoji") == "❤️", items)
        check("plain highlight emoji null", "emoji" in items.get("Psalms-23-2", {}) and items["Psalms-23-2"]["emoji"] is None, items)
        check("non-friend reaction still hidden", "Psalms-23-3" not in items, list(items))
        r = client.get(f"/notes/highlight/{me}/search", params={"q": "John"}, headers=hdr(tme))
        own = {h["key"]: h for h in r.json()["highlights"]}
        check("own reaction in search", own.get("John-3-17", {}).get("emoji") is not None, own)
    finally:
        set_flag("off")
        for u in uids:
            q("DELETE FROM highlights WHERE user_id=%s", (u,))
            q("DELETE FROM user_friends WHERE user_id=%s OR friend_id=%s", (u, u))
            q("DELETE FROM notes WHERE user_id=%s", (u,))
            q("DELETE FROM users WHERE _id=%s", (u,))


def require_scratch_db():
    db = DBManager()
    try:
        db.cur.execute("SHOW port")
        port = db.cur.fetchone()[0]
    finally:
        db.close()
    if not (port == "55432" or (port == "5432" and os.environ.get("GITHUB_ACTIONS") == "true")):
        raise SystemExit(f"refusing to run: not the scratch database (port {port}); set FS_SCRATCH_PG_PORT=55432")


def main():
    require_scratch_db()
    with TestClient(main_module.app) as client:
        test_all(client)
    print(f"\nRESULT: {len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        for l, d in FAILED:
            print(f"  X {l} -- {d}")
        sys.exit(1)
    print("STATUS: ALL PASS")


if __name__ == "__main__":
    main()
