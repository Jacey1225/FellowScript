"""Coverage for task 20260929-free-note-char-cap: the per-note character cap
(FREE 30,000 / PAID 100,000 characters of `notes.text`; AI-generated notes
exempt; shrink-only grandfather rule for both plans).

Runs against the REAL Postgres DB and the REAL routes (main.app via
TestClient). Covers: exact boundaries for both plans, code-point counting
(emoji, CJK, combining marks, CRLF), title not counted, create/reply/update,
the update rule `new_len > limit AND new_len > stored_len`, racing autosaves
(real threads), group-note editor-plan selection, fail-closed plan lookup,
403 body shape, usage endpoint `note_chars`, AI-path exemption
(summarize_session, note_via_hb), and 413 for oversize /notes bodies.

Run:  cd api && ../.venv/bin/python tests/test_note_char_cap.py
"""
import _pathfix  # noqa: F401,E402

import os
import threading
import uuid

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("S3_BUCKET_NAME", "fellowscript-test-bucket-placeholder")
os.environ.setdefault("S3_REGION", "us-east-1")
os.environ.setdefault("GIF_PROVIDER", "giphy")
os.environ.setdefault("GIF_PROVIDER_API_KEY", "test-placeholder-key-not-a-real-secret")

import _fake_timeline  # noqa: F401,E402

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from db import DBManager  # noqa: E402
from backend.interactions.agent import AgentManager  # noqa: E402
from backend.subscription.limits import LimitsManager  # noqa: E402
from schemas.subscription import (  # noqa: E402
    FREE_NOTE_CHAR_LIMIT, PAID_NOTE_CHAR_LIMIT, NOTES_MAX_BODY_BYTES,
)

FREE, PAID = 30000, 100000
PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def cookie(token):
    return {"cookie": f"session={token}"}


def signup(client, prefix):
    username = f"{prefix}_{uuid.uuid4().hex[:8]}"
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com",
        "plain_pass": "TestPass123!", "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def set_paid(uid):
    sub_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("subscriptions", {
            "_id": sub_id, "user_id": uid, "plan_type": "group",
            "provider": "stripe", "status": "active",
        })
        db.update("users", {"subscription_id": sub_id}, {"_id": uid})
    finally:
        db.close()


def set_free(uid):
    db = DBManager()
    try:
        db.update("users", {"subscription_id": None}, {"_id": uid})
        db.delete("subscriptions", {"user_id": uid})
    finally:
        db.close()


def seed_note(uid, text, *, group_id=None, public=False, title="T"):
    nid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("notes", {
            "_id": nid, "user_id": uid, "title": title, "text": text,
            "public": public, "group_id": group_id, "is_reply": False,
            "parent_note_id": None,
        })
    finally:
        db.close()
    return nid


def stored_len(nid):
    db = DBManager()
    try:
        db.cur.execute("SELECT length(text) FROM notes WHERE _id = %s", (nid,))
        row = db.cur.fetchone()
        return row[0] if row else None
    finally:
        db.close()


def note_count(uid):
    db = DBManager()
    try:
        db.cur.execute("SELECT COUNT(*) FROM notes WHERE user_id = %s", (uid,))
        return db.cur.fetchone()[0]
    finally:
        db.close()


def put(client, uid, token, nid, text, **extra):
    body = {"title": "T", "text": text, "user": uid}
    body.update(extra)
    return client.put(f"/notes/{uid}?note_id={nid}", json=body, headers=cookie(token))


def post(client, uid, token, text, title="T", **extra):
    body = {"title": title, "text": text, "user": uid}
    body.update(extra)
    return client.post(f"/notes/{uid}", json=body, headers=cookie(token))


def cleanup(users, groups):
    db = DBManager()
    try:
        for g in groups:
            db.cur.execute("DELETE FROM notes WHERE group_id = %s", (g,))
        for u in users:
            db.cur.execute("DELETE FROM notes WHERE user_id = %s", (u,))
            db.cur.execute("DELETE FROM agents WHERE user_id = %s", (u,))
        for g in groups:
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (g,))
        db.conn.commit()
        for u in users:
            db.cur.execute("UPDATE users SET subscription_id = NULL WHERE _id = %s", (u,))
            db.cur.execute("DELETE FROM subscriptions WHERE user_id = %s", (u,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (u,))
        db.conn.commit()
    finally:
        db.close()


def main():
    users, groups = [], []
    with TestClient(main_module.app, raise_server_exceptions=False) as client:
        try:
            run(client, users, groups)
        finally:
            cleanup(users, groups)
    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    for label, detail in FAILED:
        print(f"  FAILED: {label} -- {detail}")
    raise SystemExit(1 if FAILED else 0)


def run(client, users, groups):
    check("constants: free 30000 / paid 100000",
          (FREE_NOTE_CHAR_LIMIT, PAID_NOTE_CHAR_LIMIT) == (FREE, PAID))

    # ── 1. FREE create boundary + 403 body shape + title not counted ────────
    print("\n=== 1. FREE create boundary, body shape, title ===")
    fu, ft = signup(client, "ncc_free"); users.append(fu)
    r = post(client, fu, ft, "a" * FREE, title="t" * 150)
    check("free create exactly 30000 chars (150-char title, not counted) -> 201", r.status_code == 201, r.text[:200])
    r = post(client, fu, ft, "a" * (FREE + 1))
    check("free create 30001 -> 403", r.status_code == 403, str(r.status_code))
    detail = r.json().get("detail", {})
    check("403 body identical to check_limit shape, resource note_chars",
          detail == {"resource": "note_chars", "allowed": False, "unlimited": False,
                     "used": FREE + 1, "limit": FREE, "remaining": 0}, str(detail))
    check("keys match check_limit's key set",
          set(detail) == {"resource", "allowed", "unlimited", "used", "limit", "remaining"})
    check("rejected create persisted nothing (count still 1)", note_count(fu) == 1, str(note_count(fu)))

    # ── 2. Unicode code-point counting ───────────────────────────────────────
    print("\n=== 2. Unicode / emoji / CRLF counted as code points ===")
    # 4-byte emoji: 30000 code points = 120000 UTF-8 bytes / 60000 UTF-16 units.
    r = post(client, fu, ft, "\U0001F600" * FREE)
    check("30000 emoji (code points) accepted", r.status_code == 201, str(r.status_code))
    r = post(client, fu, ft, "\U0001F600" * (FREE + 1))
    check("30001 emoji rejected", r.status_code == 403, str(r.status_code))
    r = post(client, fu, ft, "中" * FREE)
    check("30000 CJK accepted", r.status_code == 201, str(r.status_code))
    # e + combining acute = 2 code points; 15000 pairs = 30000 ok, +1 char rejected.
    combo = "é" * 15000
    r = post(client, fu, ft, combo)
    check("15000 x (e + combining mark) = 30000 code points accepted", r.status_code == 201, str(r.status_code))
    r = post(client, fu, ft, combo + "x")
    check("combining text 30001 code points rejected (graphemes would be 15001)", r.status_code == 403, str(r.status_code))
    # CRLF counted as 2, no normalization.
    r = post(client, fu, ft, "\r\n" * 15000)
    check("15000 CRLF = 30000 chars accepted", r.status_code == 201, str(r.status_code))
    r = post(client, fu, ft, "\r\n" * 15000 + "x")
    check("CRLF 30001 rejected (CRLF counted as 2, not normalized)", r.status_code == 403, str(r.status_code))
    # A ZWJ family emoji sequence is 7 code points: 4285 * 7 = 29995 ok, 4286*7 = 30002 rejected
    fam = "\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466"
    check("fixture: ZWJ family is 7 code points", len(fam) == 7)
    # Stored length in Postgres equals Python len for emoji text.
    nid = seed_note(fu, "\U0001F600" * 10 + "é")
    check("postgres length() == python len() for multi-codepoint text", stored_len(nid) == 12, str(stored_len(nid)))

    # ── 3. FREE update rule ──────────────────────────────────────────────────
    print("\n=== 3. FREE update rule (new_len > limit AND new_len > stored_len) ===")
    fu2, ft2 = signup(client, "ncc_free2"); users.append(fu2)
    n = seed_note(fu2, "a" * 100)
    check("update to exactly 30000 -> 200", put(client, fu2, ft2, n, "a" * FREE).status_code == 200)
    check("stored is 30000", stored_len(n) == FREE)
    r = put(client, fu2, ft2, n, "a" * (FREE + 1))
    check("update 30000 -> 30001 rejected 403", r.status_code == 403, str(r.status_code))
    check("403 detail resource note_chars / limit 30000", r.json()["detail"].get("resource") == "note_chars" and r.json()["detail"].get("limit") == FREE)
    check("DB row unchanged after rejected update", stored_len(n) == FREE)
    check("same-length update at limit allowed", put(client, fu2, ft2, n, "b" * FREE).status_code == 200)
    check("shrink allowed", put(client, fu2, ft2, n, "b" * 29000).status_code == 200)
    r = put(client, fu2, ft2, n, "b" * (FREE + 1))
    check("grow 29000 -> 30001 rejected", r.status_code == 403)
    check("update title-only change (text unchanged length) allowed", put(client, fu2, ft2, n, "b" * 29000, title="new title").status_code == 200)

    print("\n=== 3b. FREE grandfathered over-limit note ===")
    over = seed_note(fu2, "x" * 40000)
    check("grow 40000 -> 40001 rejected", put(client, fu2, ft2, over, "x" * 40001).status_code == 403)
    check("same length 40000 allowed", put(client, fu2, ft2, over, "y" * 40000).status_code == 200)
    check("shrink 40000 -> 35000 (still over cap) allowed", put(client, fu2, ft2, over, "y" * 35000).status_code == 200)
    check("stored is 35000", stored_len(over) == 35000)
    check("grow 35000 -> 35001 rejected (shrink-only)", put(client, fu2, ft2, over, "y" * 35001).status_code == 403)
    check("grow 35000 -> 39999 rejected", put(client, fu2, ft2, over, "y" * 39999).status_code == 403)
    check("shrink to <= cap allowed", put(client, fu2, ft2, over, "y" * 30000).status_code == 200)
    check("then growing past cap rejected again", put(client, fu2, ft2, over, "y" * 30001).status_code == 403)
    over2 = seed_note(fu2, "x" * 40000)
    r = client.delete(f"/notes/{fu2}?note_id={over2}", headers=cookie(ft2))
    check("delete of over-limit note allowed", r.status_code == 200, str(r.status_code))
    check("note gone", stored_len(over2) is None)

    # ── 4. PAID boundary + grandfather ───────────────────────────────────────
    print("\n=== 4. PAID 100,000 boundary and shrink-only ===")
    pu, pt = signup(client, "ncc_paid"); users.append(pu)
    set_paid(pu)
    r = post(client, pu, pt, "a" * PAID)
    check("paid create exactly 100000 -> 201", r.status_code == 201, r.text[:200])
    r = post(client, pu, pt, "a" * (PAID + 1))
    check("paid create 100001 -> 403", r.status_code == 403)
    d = r.json().get("detail", {})
    check("paid 403 body: resource note_chars, limit 100000, unlimited False, used 100001, remaining 0",
          d == {"resource": "note_chars", "allowed": False, "unlimited": False,
                "used": PAID + 1, "limit": PAID, "remaining": 0}, str(d))
    check("paid may exceed free cap (50000 create)", post(client, pu, pt, "a" * 50000).status_code == 201)
    pn = seed_note(pu, "a" * 100)
    check("paid update to 100000 ok", put(client, pu, pt, pn, "a" * PAID).status_code == 200)
    check("paid update 100000 -> 100001 rejected", put(client, pu, pt, pn, "a" * (PAID + 1)).status_code == 403)
    check("paid DB row unchanged", stored_len(pn) == PAID)
    check("paid same-length ok", put(client, pu, pt, pn, "z" * PAID).status_code == 200)
    pover = seed_note(pu, "q" * 120000)
    check("paid over-limit grow rejected", put(client, pu, pt, pover, "q" * 120001).status_code == 403)
    check("paid over-limit same length allowed", put(client, pu, pt, pover, "r" * 120000).status_code == 200)
    check("paid over-limit shrink (still over) allowed", put(client, pu, pt, pover, "r" * 110000).status_code == 200)
    check("paid over-limit regrow rejected", put(client, pu, pt, pover, "r" * 110001).status_code == 403)
    check("paid multi-byte 100000 emoji ok", post(client, pu, pt, "\U0001F600" * PAID).status_code == 201)
    check("paid multi-byte 100001 emoji rejected", post(client, pu, pt, "\U0001F600" * (PAID + 1)).status_code == 403)

    # ── 5. Downgrade / upgrade ───────────────────────────────────────────────
    print("\n=== 5. Downgrade paid -> free applies free rule immediately with grandfathering ===")
    dn = seed_note(pu, "d" * 80000)
    check("paid: grow 80000 -> 90000 ok", put(client, pu, pt, dn, "d" * 90000).status_code == 200)
    set_free(pu)
    check("after downgrade: grow 90000 -> 90001 rejected", put(client, pu, pt, dn, "d" * 90001).status_code == 403)
    check("after downgrade: shrink 90000 -> 85000 allowed", put(client, pu, pt, dn, "d" * 85000).status_code == 200)
    check("after downgrade: new 30001-char create rejected", post(client, pu, pt, "a" * (FREE + 1)).status_code == 403)
    set_paid(pu)
    check("re-upgrade: grow to 95000 allowed", put(client, pu, pt, dn, "d" * 95000).status_code == 200)
    set_free(pu)

    # ── 6. Reply path ────────────────────────────────────────────────────────
    print("\n=== 6. Reply path ===")
    ru, rt = signup(client, "ncc_reply"); users.append(ru)
    parent = seed_note(ru, "parent")
    r = client.post(f"/notes/reply/{parent}", json={"user": ru, "title": "r", "text": "a" * FREE}, headers=cookie(rt))
    check("free reply exactly 30000 -> 201", r.status_code == 201, r.text[:200])
    r = client.post(f"/notes/reply/{parent}", json={"user": ru, "title": "r", "text": "a" * (FREE + 1)}, headers=cookie(rt))
    check("free reply 30001 -> 403 note_chars", r.status_code == 403 and r.json()["detail"].get("resource") == "note_chars", r.text[:200])
    check("rejected reply persisted nothing", note_count(ru) == 2, str(note_count(ru)))
    set_paid(ru)
    r = client.post(f"/notes/reply/{parent}", json={"user": ru, "title": "r", "text": "a" * PAID}, headers=cookie(rt))
    check("paid reply 100000 -> 201", r.status_code == 201, r.text[:200])
    r = client.post(f"/notes/reply/{parent}", json={"user": ru, "title": "r", "text": "a" * (PAID + 1)}, headers=cookie(rt))
    check("paid reply 100001 -> 403", r.status_code == 403)
    set_free(ru)

    # ── 7. Group notes use the EDITOR's plan ─────────────────────────────────
    print("\n=== 7. Group note editor plan ===")
    ou, ot = signup(client, "ncc_owner"); users.append(ou)
    eu, et = signup(client, "ncc_editor"); users.append(eu)
    gid = str(uuid.uuid4()); groups.append(gid)
    r = client.post(f"/groups/{ou}", json={"group_id": gid, "title": "cap grp", "users": [ou, eu]}, headers=cookie(ot))
    check("group created", r.status_code == 201, r.text[:200])
    # Owner PAID, editor FREE.
    set_paid(ou)
    gn = seed_note(ou, "g" * 20000, group_id=gid, public=True)
    r = put(client, eu, et, gn, "g" * 30001, group_id=gid, public=True)
    check("free editor on paid owner's note: grow to 30001 rejected (editor's plan)", r.status_code == 403, r.text[:200])
    r = put(client, eu, et, gn, "g" * 30000, group_id=gid, public=True)
    check("free editor: grow to 30000 allowed", r.status_code == 200, r.text[:200])
    r = put(client, ou, ot, gn, "g" * 60000, group_id=gid, public=True)
    check("paid owner on same note: grow to 60000 allowed", r.status_code == 200, r.text[:200])
    r = put(client, eu, et, gn, "g" * 60001, group_id=gid, public=True)
    check("free editor: grow of grandfathered 60000 note rejected", r.status_code == 403)
    r = put(client, eu, et, gn, "g" * 50000, group_id=gid, public=True)
    check("free editor: shrink 60000 -> 50000 allowed", r.status_code == 200, r.text[:200])
    # Owner FREE, editor PAID.
    set_free(ou); set_paid(eu)
    gn2 = seed_note(ou, "h" * 20000, group_id=gid, public=True)
    r = put(client, eu, et, gn2, "h" * 90000, group_id=gid, public=True)
    check("paid editor on free owner's note: grow to 90000 allowed (editor's plan)", r.status_code == 200, r.text[:200])
    r = put(client, eu, et, gn2, "h" * (PAID + 1), group_id=gid, public=True)
    check("paid editor: 100001 rejected", r.status_code == 403)
    # Authorization unchanged: non-public note, non-owner editor still 403 Not authorized (string detail).
    gn3 = seed_note(ou, "i" * 10, group_id=gid, public=False)
    r = put(client, eu, et, gn3, "i" * 11, group_id=gid)
    check("non-public group note: member edit still 403 'Not authorized' (authz unchanged)",
          r.status_code == 403 and r.json().get("detail") == "Not authorized", r.text[:200])
    set_free(eu)

    # ── 8. Fail closed on plan lookup failure ────────────────────────────────
    print("\n=== 8. Plan lookup failure fails closed ===")
    xu, xt = signup(client, "ncc_fail"); users.append(xu)
    xn = seed_note(xu, "a" * 100)
    orig = LimitsManager.is_subscribed

    def boom(self, user_id):
        raise RuntimeError("simulated plan lookup failure")
    LimitsManager.is_subscribed = boom
    try:
        before = note_count(xu)
        r = post(client, xu, xt, "short")
        check("create with failing plan lookup does not succeed (non-2xx)", r.status_code >= 400, str(r.status_code))
    finally:
        LimitsManager.is_subscribed = orig
    check("...and persisted no note", note_count(xu) == before, f"{before} -> {note_count(xu)}")
    LimitsManager.is_subscribed = boom
    try:
        r = put(client, xu, xt, xn, "b" * 50)
        check("update with failing plan lookup does not succeed (non-2xx)", r.status_code >= 400, str(r.status_code))
    finally:
        LimitsManager.is_subscribed = orig
    db = DBManager()
    try:
        db.cur.execute("SELECT text FROM notes WHERE _id = %s", (xn,))
        check("...and row unchanged", db.cur.fetchone()[0] == "a" * 100)
    finally:
        db.close()

    # ── 9. Usage endpoint ────────────────────────────────────────────────────
    print("\n=== 9. Usage endpoint note_chars ===")
    r = client.get(f"/subscriptions/user/{xu}/usage", headers=cookie(xt))
    u = r.json()
    check("free usage note_chars == {unlimited False, limit 30000}", u.get("note_chars") == {"unlimited": False, "limit": FREE}, str(u.get("note_chars")))
    check("no legacy 'ceiling' key", "ceiling" not in u.get("note_chars", {}))
    set_paid(xu)
    u = client.get(f"/subscriptions/user/{xu}/usage", headers=cookie(xt)).json()
    check("paid usage note_chars == {unlimited False, limit 100000}", u.get("note_chars") == {"unlimited": False, "limit": PAID}, str(u.get("note_chars")))
    check("paid usage still reports notes count unlimited", u["resources"]["notes"]["unlimited"] is True)
    set_free(xu)

    # ── 10. AI paths exempt ──────────────────────────────────────────────────
    print("\n=== 10. AI-generated notes exempt ===")
    au, at = signup(client, "ncc_ai"); users.append(au)
    agent_id = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute("INSERT INTO agents (_id, user_id, role, chats) VALUES (%s,%s,%s,%s)", (agent_id, au, "", []))
        db.conn.commit()
    finally:
        db.close()
    big = "s" * 45000
    orig_call = AgentManager._call_api
    AgentManager._call_api = lambda self, role, msgs: big
    try:
        r = client.post(f"/agent/{au}/{agent_id}/summarize",
                        json={"session": {"title": "t", "prompts": ["p"], "verses": ["John 3:16"]}},
                        headers=cookie(at))
    finally:
        AgentManager._call_api = orig_call
    check("free summarize_session with 45000-char AI output -> 200 (exempt)", r.status_code in (200, 201), r.text[:200])
    if r.status_code in (200, 201):
        check("summary stored untruncated", stored_len(r.json()["note_id"]) == 45000)
        # the user then editing it: shrink-only
        sn = r.json()["note_id"]
        check("user grow of AI note rejected", put(client, au, at, sn, "s" * 45001).status_code == 403)
        check("user shrink of AI note allowed", put(client, au, at, sn, "s" * 44000).status_code == 200)
    am = AgentManager(au)
    try:
        hb_id = am.note_via_hb({"title": "hb", "text": "h" * 50000, "verses": []})
    finally:
        am.close()
    check("free heartbeat note_via_hb with 50000 chars persists (exempt)", stored_len(hb_id) == 50000, str(stored_len(hb_id)))

    # ── 11. 413 for over-size /notes bodies ──────────────────────────────────
    print("\n=== 11. Oversize body -> 413 ===")
    big_body = '{"title":"T","text":"' + "a" * (NOTES_MAX_BODY_BYTES + 10) + '"}'
    hdrs = {**cookie(ft), "content-type": "application/json"}
    r = client.post(f"/notes/{fu}", content=big_body, headers=hdrs)
    check("POST /notes oversize -> 413", r.status_code == 413, str(r.status_code))
    r = client.put(f"/notes/{fu}?note_id={n}", content=big_body, headers=hdrs)
    check("PUT /notes oversize -> 413", r.status_code == 413, str(r.status_code))
    pbody = '{"title":"T","text":"' + "a" * PAID + '"}'
    check("worst-case 100000 ASCII chars body is under the 413 limit", len(pbody) < NOTES_MAX_BODY_BYTES)
    pbody4 = '{"title":"T","text":"' + "\U0001F600" * PAID + '"}'
    check("100000 emoji as raw UTF-8 (400KB) under limit", len(pbody4.encode()) < NOTES_MAX_BODY_BYTES)
    # JSON-escaped worst case: \uXXXX\uXXXX surrogate pair per emoji = 12 bytes
    check("100000 emoji as escaped surrogate pairs (1.2MB) under limit", 100000 * 12 < NOTES_MAX_BODY_BYTES)

    # ── 12. Racing concurrent autosaves (real threads) ───────────────────────
    print("\n=== 12. Concurrent autosaves ===")
    cu, ct = signup(client, "ncc_race"); users.append(cu)
    # (a) many growing writes past the cap from a note at the cap: all rejected.
    rn = seed_note(cu, "a" * FREE)
    codes = []
    lock = threading.Lock()

    def worker_put(nid, text):
        c2 = TestClient(main_module.app, raise_server_exceptions=False)
        rr = put(c2, cu, ct, nid, text)
        with lock:
            codes.append(rr.status_code)

    ths = [threading.Thread(target=worker_put, args=(rn, "b" * (FREE + 1 + i))) for i in range(8)]
    [t.start() for t in ths]; [t.join() for t in ths]
    check("8 racing grows past cap all 403", codes == [403] * 8, str(sorted(codes)))
    check("stored length still 30000", stored_len(rn) == FREE)

    # (b) shrink vs grow race from a grandfathered 35000 note. Correct
    # serialization forbids: both succeed AND final == the grow length
    # (grow only passes if it ran BEFORE the shrink, so final must be the shrink).
    bad = 0
    ok_both = 0
    for _ in range(12):
        gnr = seed_note(cu, "a" * 35000)
        res = {}
        barrier = threading.Barrier(2)

        def w(name, length):
            c2 = TestClient(main_module.app, raise_server_exceptions=False)
            barrier.wait()
            res[name] = put(c2, cu, ct, gnr, "c" * length).status_code

        t1 = threading.Thread(target=w, args=("shrink", 31000))
        t2 = threading.Thread(target=w, args=("grow", 34000))
        t1.start(); t2.start(); t1.join(); t2.join()
        final = stored_len(gnr)
        if res["shrink"] == 200 and res["grow"] == 200:
            ok_both += 1
            if final != 31000:
                bad += 1
        if res["shrink"] == 200 and res["grow"] != 200 and final != 31000:
            bad += 1
        if final > 35000:
            bad += 1
        if res["shrink"] not in (200,) or res["grow"] not in (200, 403):
            bad += 1
    check("12 shrink-vs-grow races: final state always consistent with a serial order", bad == 0, f"bad={bad} ok_both={ok_both}")

    # (c) multiple threads racing valid shrinks: all end consistent (200 each) and never grows
    rc = seed_note(cu, "a" * 36000)
    codes.clear()
    lens = [35000, 34000, 33000, 32000, 31000, 30500]
    ths = [threading.Thread(target=worker_put, args=(rc, "d" * L)) for L in lens]
    [t.start() for t in ths]; [t.join() for t in ths]
    final = stored_len(rc)
    check("racing shrinks: no 5xx and final <= 36000",
          all(c in (200, 403) for c in codes) and final <= 36000, f"{sorted(codes)} final={final}")
    # A 403 in racing shrinks is only legit if that write would have grown past the then-stored length.
    check("racing shrinks: final equals some attempted length", final in lens, str(final))


if __name__ == "__main__":
    main()
