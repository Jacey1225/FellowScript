"""Backend coverage for task 20260929-group-announcements (testing step 3).

Real routes + dev Postgres (same harness as test_group_info_panel.py):
  A. Authz: every route is member-only (403 non-member, 401 unauthenticated,
     403 spoofed user_id), nothing persisted by denied calls.
  B. Migration: create_tables() twice is a no-op (idempotent), table + indexes exist.
  C. CRUD + permissions: create/list/get/update/delete; only announcement
     creator or group creator may edit/delete/restore; other members 403.
  D. Visibility: scheduled hidden from other members, visible to author;
     published becomes visible; publish_at validation (naive/garbage/horizon).
  E. Banner: upload-url scoped to group-announcements/{group}/; create/update
     reject foreign / other-group / group-photo / traversal keys (403).
     Replacing a banner still referenced by a peer does not delete the object.
  F. Free-limit gate: free user 2nd create -> 403 with notes-shaped body;
     scheduled counts; delete-and-recreate does not bypass; rolling window
     expiry re-allows; paid user unlimited; edits are not gated; usage
     summary and list 'gate' surface the resource.
  G. Undo: restore within grace works, after grace 404.
  H. Content filter and validation (blank/overlong title -> 422).

Run with: cd api && ../.venv/bin/python tests/test_group_announcements.py
"""
import _pathfix  # noqa: F401

import os
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

from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
import backend.interactions.announcements as ann_module  # noqa: E402
from db import DBManager, create_tables  # noqa: E402

PASSED, FAILED = [], []


def check(label, cond, detail=""):
    if cond:
        PASSED.append(label)
        print(f"  OK   {label}")
    else:
        FAILED.append((label, detail))
        print(f"  FAIL {label}  -- {detail}")


def ck(token):
    return {"cookie": f"session={token}"} if token else {}


def signup(client, username):
    fake_ip = f"203.0.113.{uuid.uuid4().int % 250 + 1}"
    r = client.post("/signup", json={
        "username": username, "email": f"{username}@example.com", "plain_pass": "TestPass123!",
        "terms_accepted": True,
    }, headers={"cf-connecting-ip": fake_ip})
    assert r.status_code == 201, f"signup failed: {r.status_code} {r.text}"
    return r.json()["user_id"], r.cookies.get("session")


def sql(query, params=(), fetch=False):
    db = DBManager()
    try:
        db.cur.execute(query, params)
        out = db.cur.fetchall() if fetch else None
        db.conn.commit()
        return out
    finally:
        db.close()


def cleanup(user_ids, group_ids, sub_ids=()):
    db = DBManager()
    try:
        for gid in group_ids:
            db.cur.execute("DELETE FROM group_announcements WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM messages WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM group_announcements WHERE creator_id = %s", (uid,))
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        for sid in sub_ids:
            db.cur.execute("DELETE FROM subscriptions WHERE _id = %s", (sid,))
        db.conn.commit()
    finally:
        db.close()


def create_group(client, token, owner, members):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner}", json={"group_id": gid, "title": "Ann group", "users": [owner, *members]},
                    headers=ck(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def make_paid(uid):
    sid = str(uuid.uuid4())
    sql("INSERT INTO subscriptions (_id, user_id, plan_type, status, current_period_end) "
        "VALUES (%s,%s,'group','active', now() + interval '20 days')", (sid, uid))
    sql("UPDATE users SET subscription_id = %s WHERE _id = %s", (sid, uid))
    return sid


def base(u, g):
    return f"/groups/{u}/{g}/announcements"


def past(minutes=5):
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat()


def future(days=2):
    return (datetime.now(timezone.utc) + timedelta(days=days)).isoformat()


def count_rows(gid):
    return sql("SELECT count(*) FROM group_announcements WHERE group_id=%s", (gid,), fetch=True)[0][0]


# ── A ────────────────────────────────────────────────────────────────────────
def test_authz(client):
    print("\n== A. every route is member-only ==")
    a, ta = signup(client, f"an_a_{uuid.uuid4().hex[:8]}")
    o, to = signup(client, f"an_o_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, ta, a, [])
        r = client.post(base(a, gid), json={"title": "real"}, headers=ck(ta))
        assert r.status_code == 201, r.text
        aid = r.json()["id"]
        routes = [
            ("GET", base(o, gid), None),
            ("POST", base(o, gid), {"title": "hijack"}),
            ("GET", f"{base(o, gid)}/{aid}", None),
            ("PUT", f"{base(o, gid)}/{aid}", {"title": "hijack"}),
            ("DELETE", f"{base(o, gid)}/{aid}", None),
            ("POST", f"{base(o, gid)}/{aid}/restore", None),
            ("POST", f"{base(o, gid)}/banner/upload-url", {"content_type": "image/png"}),
        ]
        for method, url, body in routes:
            tag = f"{method} {url.split(gid)[1]}"
            r = client.request(method, url, json=body, headers=ck(to))
            check(f"non-member {tag} -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
            r = client.request(method, url.replace(o, a), json=body, headers=ck(to))
            check(f"spoofed user_id {tag} -> 403", r.status_code == 403, f"{r.status_code}")
            r = client.request(method, url.replace(o, a), json=body)
            check(f"unauthenticated {tag} -> 401", r.status_code == 401, f"{r.status_code}")
        row = sql("SELECT title, deleted_at FROM group_announcements WHERE group_id=%s", (gid,), fetch=True)
        check("denied calls changed nothing", row == [("real", None)], str(row))
    finally:
        cleanup([a, o], [gid] if gid else [])


# ── B ────────────────────────────────────────────────────────────────────────
def test_migration(client):
    print("\n== B. migration idempotence ==")
    db = DBManager()
    try:
        create_tables(db.cur)
        create_tables(db.cur)
        db.conn.commit()
    except Exception as e:
        db.conn.rollback()
        check("create_tables() run twice without error", False, repr(e))
        return
    finally:
        db.close()
    check("create_tables() run twice without error", True)
    cols = {r[0] for r in sql(
        "SELECT column_name FROM information_schema.columns WHERE table_name='group_announcements'", fetch=True)}
    want = {"_id", "group_id", "creator_id", "title", "description", "banner_key",
            "publish_at", "created_at", "updated_at", "deleted_at"}
    check("table has expected columns", want <= cols, str(want - cols))
    idx = {r[0] for r in sql("SELECT indexname FROM pg_indexes WHERE tablename='group_announcements'", fetch=True)}
    check("both indexes exist", {"idx_group_announcements_group_publish",
                                 "idx_group_announcements_creator_created"} <= idx, str(idx))


# ── C / D / G / H ────────────────────────────────────────────────────────────
def test_crud_permissions(client):
    print("\n== C. CRUD + edit/delete permissions ==")
    owner, to = signup(client, f"an_ow_{uuid.uuid4().hex[:8]}")   # group creator (moderator)
    m1, t1 = signup(client, f"an_m1_{uuid.uuid4().hex[:8]}")      # author
    m2, t2 = signup(client, f"an_m2_{uuid.uuid4().hex[:8]}")      # bystander member
    sids = [make_paid(m1), make_paid(m2), make_paid(owner)]       # paid so limits don't interfere
    gid = None
    try:
        gid = create_group(client, to, owner, [m1, m2])
        r = client.post(base(m1, gid), json={"title": "  Hello  ", "description": " Body "}, headers=ck(t1))
        check("member create -> 201 stripped", r.status_code == 201 and r.json()["title"] == "Hello"
              and r.json()["description"] == "Body", f"{r.status_code} {r.text}")
        a = r.json()
        aid = a["id"]
        check("author can_edit true", a["can_edit"] is True)
        check("no banner -> banner_url None", a["banner_url"] is None)

        r = client.get(base(m2, gid), headers=ck(t2))
        check("other member sees it in list, can_edit false",
              r.status_code == 200 and [x["id"] for x in r.json()["announcements"]] == [aid]
              and r.json()["announcements"][0]["can_edit"] is False, f"{r.status_code} {r.text}")
        r = client.get(f"{base(m2, gid)}/{aid}", headers=ck(t2))
        check("other member get -> 200", r.status_code == 200 and r.json()["id"] == aid)

        r = client.put(f"{base(m2, gid)}/{aid}", json={"title": "x"}, headers=ck(t2))
        check("bystander edit -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = client.delete(f"{base(m2, gid)}/{aid}", headers=ck(t2))
        check("bystander delete -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        check("bystander changed nothing", sql("SELECT title, deleted_at FROM group_announcements WHERE _id=%s",
                                               (aid,), fetch=True) == [("Hello", None)])

        r = client.put(f"{base(m1, gid)}/{aid}", json={"title": "Edited"}, headers=ck(t1))
        check("author edit -> 200", r.status_code == 200 and r.json()["title"] == "Edited"
              and r.json()["description"] == "Body", f"{r.status_code} {r.text}")
        r = client.put(f"{base(owner, gid)}/{aid}", json={"description": "Mod edit"}, headers=ck(to))
        check("group creator (moderator) edit -> 200", r.status_code == 200 and r.json()["description"] == "Mod edit",
              f"{r.status_code} {r.text}")
        r = client.put(f"{base(m1, gid)}/{aid}", json={}, headers=ck(t1))
        check("empty update -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
        r = client.put(f"{base(m1, gid)}/{aid}", json={"publish_at": future()}, headers=ck(t1))
        check("publish_at change after publishing -> 422", r.status_code == 422, f"{r.status_code} {r.text}")

        r = client.delete(f"{base(owner, gid)}/{aid}", headers=ck(to))
        check("group creator delete -> 200", r.status_code == 200 and r.json()["deleted"] is True, f"{r.status_code} {r.text}")
        check("deleted hidden from list", client.get(base(m2, gid), headers=ck(t2)).json()["announcements"] == [])
        check("deleted get -> 404", client.get(f"{base(m2, gid)}/{aid}", headers=ck(t2)).status_code == 404)
        check("deleted row is a tombstone, not removed",
              sql("SELECT deleted_at IS NOT NULL FROM group_announcements WHERE _id=%s", (aid,), fetch=True) == [(True,)])
        check("edit of deleted -> 404", client.put(f"{base(m1, gid)}/{aid}", json={"title": "z"}, headers=ck(t1)).status_code == 404)

        print("\n== G. undo grace ==")
        r = client.post(f"{base(m2, gid)}/{aid}/restore", headers=ck(t2))
        check("bystander restore -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        r = client.post(f"{base(m1, gid)}/{aid}/restore", headers=ck(t1))
        check("author restore within grace -> 200", r.status_code == 200 and r.json()["id"] == aid, f"{r.status_code} {r.text}")
        check("restored visible again", len(client.get(base(m2, gid), headers=ck(t2)).json()["announcements"]) == 1)
        r = client.post(f"{base(m1, gid)}/{aid}/restore", headers=ck(t1))
        check("restore of non-deleted -> 404", r.status_code == 404, f"{r.status_code}")
        client.delete(f"{base(m1, gid)}/{aid}", headers=ck(t1))
        sql("UPDATE group_announcements SET deleted_at = now() - interval '%s seconds' WHERE _id=%%s"
            % (ann_module.ANNOUNCEMENT_UNDO_GRACE_SECONDS + 30), (aid,))
        r = client.post(f"{base(m1, gid)}/{aid}/restore", headers=ck(t1))
        check("restore after grace lapsed -> 404", r.status_code == 404, f"{r.status_code} {r.text}")
        check("still hidden after failed restore", client.get(f"{base(m1, gid)}/{aid}", headers=ck(t1)).status_code == 404)

        print("\n== H. validation + content filter ==")
        for label, body in (("blank title", {"title": "   "}), ("overlong title", {"title": "x" * 256}),
                            ("overlong description", {"title": "t", "description": "d" * 5001}),
                            ("missing title", {"description": "d"})):
            before = count_rows(gid)
            r = client.post(base(m1, gid), json=body, headers=ck(t1))
            check(f"{label} -> 422 and nothing stored", r.status_code == 422 and count_rows(gid) == before,
                  f"{r.status_code} {r.text}")
        r = client.post(base(m1, gid), json={"title": "x" * 255}, headers=ck(t1))
        check("255-char title accepted", r.status_code == 201, f"{r.status_code} {r.text}")
        from backend.moderation.content_filter import ContentRejected, check_clean
        bad = None
        for cand in ("fuck", "shit", "nigger", "cunt"):
            try:
                check_clean(title=cand)
            except ContentRejected:
                bad = cand
                break
        if bad:
            before = count_rows(gid)
            r = client.post(base(m1, gid), json={"title": bad}, headers=ck(t1))
            check("content-filtered title -> 422", r.status_code == 422 and count_rows(gid) == before, f"{r.status_code}")
            r = client.post(base(m1, gid), json={"title": "ok", "description": bad}, headers=ck(t1))
            check("content-filtered description -> 422", r.status_code == 422, f"{r.status_code}")
        else:
            check("content filter has a rejectable word", False, "none rejected")
    finally:
        cleanup([owner, m1, m2], [gid] if gid else [], sids)


def test_visibility(client):
    print("\n== D. scheduling / visibility ==")
    a, ta = signup(client, f"an_va_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"an_vb_{uuid.uuid4().hex[:8]}")
    sids = [make_paid(a)]
    gid = None
    try:
        gid = create_group(client, ta, a, [b])
        r = client.post(base(a, gid), json={"title": "later", "publish_at": future()}, headers=ck(ta))
        check("scheduled create -> 201, published false", r.status_code == 201 and r.json()["published"] is False,
              f"{r.status_code} {r.text}")
        sid = r.json()["id"]
        check("author sees own scheduled in list", [x["id"] for x in client.get(base(a, gid), headers=ck(ta)).json()["announcements"]] == [sid])
        check("other member does NOT see scheduled in list", client.get(base(b, gid), headers=ck(tb)).json()["announcements"] == [])
        check("other member get scheduled -> 404", client.get(f"{base(b, gid)}/{sid}", headers=ck(tb)).status_code == 404)
        check("other member cannot edit hidden scheduled -> 404",
              client.put(f"{base(b, gid)}/{sid}", json={"title": "x"}, headers=ck(tb)).status_code == 404)
        check("other member cannot delete hidden scheduled -> 404",
              client.delete(f"{base(b, gid)}/{sid}", headers=ck(tb)).status_code == 404)
        r = client.put(f"{base(a, gid)}/{sid}", json={"publish_at": future(3)}, headers=ck(ta))
        check("author can reschedule unpublished", r.status_code == 200, f"{r.status_code} {r.text}")
        # Time passes: publish moment reached.
        sql("UPDATE group_announcements SET publish_at = now() - interval '1 minute' WHERE _id=%s", (sid,))
        check("after publish_at passes, member sees it",
              [x["id"] for x in client.get(base(b, gid), headers=ck(tb)).json()["announcements"]] == [sid])

        r = client.post(base(a, gid), json={"title": "past", "publish_at": past()}, headers=ck(ta))
        check("past publish_at -> published now", r.status_code == 201 and r.json()["published"] is True, f"{r.status_code} {r.text}")
        r = client.post(base(a, gid), json={"title": "none"}, headers=ck(ta))
        check("null publish_at -> published now", r.status_code == 201 and r.json()["published"] is True)
        for label, val in (("naive timestamp", "2030-01-01T10:00:00"), ("garbage", "tomorrow-ish"),
                           ("beyond 365d horizon", future(400))):
            before = count_rows(gid)
            r = client.post(base(a, gid), json={"title": "t", "publish_at": val}, headers=ck(ta))
            check(f"publish_at {label} -> 422 nothing stored", r.status_code == 422 and count_rows(gid) == before,
                  f"{r.status_code} {r.text}")
        r = client.put(f"{base(a, gid)}/{sid}", json={"publish_at": None}, headers=ck(ta))
        check("clearing publish_at -> 422", r.status_code == 422, f"{r.status_code}")

        ids = [x["id"] for x in client.get(base(b, gid), headers=ck(tb)).json()["announcements"]]
        pubs = sql("SELECT _id::text FROM group_announcements WHERE group_id=%s ORDER BY publish_at DESC, _id DESC",
                   (gid,), fetch=True)
        check("list ordered newest publish first", ids == [p[0] for p in pubs], f"{ids} vs {pubs}")
    finally:
        cleanup([a, b], [gid] if gid else [], sids)


# ── E ────────────────────────────────────────────────────────────────────────
def test_banner(client):
    print("\n== E. banner key ownership ==")
    a, ta = signup(client, f"an_ba_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"an_bb_{uuid.uuid4().hex[:8]}")
    sids = [make_paid(a), make_paid(b)]
    gid = other = None
    deleted = []
    orig = ann_module.delete_object
    ann_module.delete_object = lambda k: deleted.append(k)
    try:
        gid = create_group(client, ta, a, [b])
        other = create_group(client, tb, b, [])
        r = client.post(f"{base(a, gid)}/banner/upload-url", json={"content_type": "image/png"}, headers=ck(ta))
        check("upload-url -> 200 presigned POST", r.status_code == 200 and "fields" in r.json(), f"{r.status_code} {r.text}")
        key = r.json().get("object_key", "")
        check("key scoped to group-announcements/{group}/", key.startswith(f"group-announcements/{gid}/"), key)
        r = client.post(f"{base(a, gid)}/banner/upload-url", json={"content_type": "application/pdf"}, headers=ck(ta))
        check("non-image content_type -> 400", r.status_code == 400, f"{r.status_code} {r.text}")

        bad = {
            "another group's announcement key": f"group-announcements/{other}/{b}/{uuid.uuid4()}.png",
            "group-photo key": f"group-photos/{gid}/{a}/{uuid.uuid4()}.png",
            "profile-photo key": f"profile-photos/{a}/{uuid.uuid4()}.png",
            "attachment key": f"attachments/{a}/{uuid.uuid4()}.png",
            "traversal": f"group-announcements/{gid}/../{other}/x.png",
            "prefix lookalike": f"group-announcements/{gid}x/y.png",
            "blank": "",
        }
        for label, bk in bad.items():
            before = count_rows(gid)
            r = client.post(base(a, gid), json={"title": "t", "banner_key": bk}, headers=ck(ta))
            check(f"create rejects {label} -> 403, nothing stored", r.status_code == 403 and count_rows(gid) == before,
                  f"{r.status_code} {r.text}")

        r = client.post(base(a, gid), json={"title": "with banner", "banner_key": key}, headers=ck(ta))
        check("create with own-group key -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        aid = r.json()["id"]
        check("banner_key persisted, never exposed",
              sql("SELECT banner_key FROM group_announcements WHERE _id=%s", (aid,), fetch=True) == [(key,)]
              and "banner_key" not in r.json())
        for label, bk in bad.items():
            r = client.put(f"{base(a, gid)}/{aid}", json={"banner_key": bk}, headers=ck(ta))
            check(f"update rejects {label} -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        check("key unchanged after rejected updates",
              sql("SELECT banner_key FROM group_announcements WHERE _id=%s", (aid,), fetch=True) == [(key,)])

        key2 = f"group-announcements/{gid}/{a}/{uuid.uuid4()}.png"
        r = client.put(f"{base(a, gid)}/{aid}", json={"banner_key": key2}, headers=ck(ta))
        check("replace banner deletes old object", r.status_code == 200 and deleted == [key], f"{r.status_code} deleted={deleted}")
        deleted.clear()

        # Peer-banner destruction: b attaches a's key2 to own announcement, then replaces it.
        r = client.post(base(b, gid), json={"title": "peer", "banner_key": key2}, headers=ck(tb))
        check("peer create referencing same group key -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        pid = r.json()["id"]
        key3 = f"group-announcements/{gid}/{b}/{uuid.uuid4()}.png"
        r = client.put(f"{base(b, gid)}/{pid}", json={"banner_key": key3}, headers=ck(tb))
        check("replacing a banner still used by another announcement does not delete the object",
              r.status_code == 200 and deleted == [], f"{r.status_code} deleted={deleted}")
        r = client.put(f"{base(a, gid)}/{aid}", json={"banner_key": None}, headers=ck(ta))
        check("null clears banner (unreferenced old object swept)", r.status_code == 200 and r.json()["banner_url"] is None
              and deleted == [key2], f"{r.status_code} {deleted}")
    finally:
        ann_module.delete_object = orig
        cleanup([a, b], [g for g in (gid, other) if g], sids)


# ── F ────────────────────────────────────────────────────────────────────────
def test_gate(client):
    print("\n== F. free-plan limit (1 / rolling 7 days, per author, all groups) ==")
    f, tf = signup(client, f"an_f_{uuid.uuid4().hex[:8]}")
    p, tp = signup(client, f"an_p_{uuid.uuid4().hex[:8]}")
    sids = []
    g1 = g2 = gp = None
    try:
        g1 = create_group(client, tf, f, [])
        g2 = create_group(client, tf, f, [])
        r = client.get(base(f, g1), headers=ck(tf))
        check("list surfaces gate (allowed, 0/1)", r.status_code == 200 and r.json()["gate"]["allowed"] is True
              and r.json()["gate"]["limit"] == 1 and r.json()["gate"]["used"] == 0, f"{r.status_code} {r.text}")
        r = client.post(base(f, g1), json={"title": "first"}, headers=ck(tf))
        check("free user 1st create -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        first = r.json()["id"]
        r = client.post(base(f, g1), json={"title": "second"}, headers=ck(tf))
        check("free user 2nd create -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        d = r.json().get("detail", {})
        check("403 detail shape matches notes (resource/used/limit/allowed)",
              d.get("resource") == "announcements" and d.get("used") == 1 and d.get("limit") == 1
              and d.get("allowed") is False, str(d))
        check("blocked create stored nothing", count_rows(g1) == 1)
        r = client.post(base(f, g2), json={"title": "other group"}, headers=ck(tf))
        check("cap is per author across groups (2nd group also 403)", r.status_code == 403, f"{r.status_code}")
        r = client.get(base(f, g1), headers=ck(tf))
        check("list gate now not allowed", r.json()["gate"]["allowed"] is False and r.json()["gate"]["remaining"] == 0)
        u = client.get(f"/subscriptions/user/{f}/usage", headers=ck(tf)).json()
        check("usage_summary exposes announcements resource",
              u["resources"].get("announcements", {}).get("used") == 1 and u["resources"]["announcements"]["limit"] == 1, str(u))

        r = client.put(f"{base(f, g1)}/{first}", json={"title": "still editable"}, headers=ck(tf))
        check("editing at cap is not gated", r.status_code == 200, f"{r.status_code} {r.text}")

        # delete-and-recreate bypass
        r = client.delete(f"{base(f, g1)}/{first}", headers=ck(tf))
        check("delete ok", r.status_code == 200)
        r = client.post(base(f, g1), json={"title": "bypass"}, headers=ck(tf))
        check("delete-and-recreate does NOT bypass cap (tombstone counts)", r.status_code == 403, f"{r.status_code} {r.text}")

        # rolling window expiry
        sql("UPDATE group_announcements SET created_at = now() - interval '8 days' WHERE creator_id=%s", (f,))
        r = client.post(base(f, g1), json={"title": "after window"}, headers=ck(tf))
        check("row older than 7 days no longer counts -> 201", r.status_code == 201, f"{r.status_code} {r.text}")
        # boundary: 6 days still counts
        sql("UPDATE group_announcements SET created_at = now() - interval '6 days' WHERE creator_id=%s", (f,))
        r = client.post(base(f, g1), json={"title": "inside window"}, headers=ck(tf))
        check("rows at 6 days still count -> 403", r.status_code == 403, f"{r.status_code}")

        # scheduling cannot bypass: scheduled counts by created_at
        sql("DELETE FROM group_announcements WHERE creator_id=%s", (f,))
        r = client.post(base(f, g1), json={"title": "sched", "publish_at": future(30)}, headers=ck(tf))
        check("free user scheduled create -> 201", r.status_code == 201)
        r = client.post(base(f, g1), json={"title": "now"}, headers=ck(tf))
        check("scheduled announcement counts toward cap -> 403", r.status_code == 403, f"{r.status_code}")

        # paid: unlimited
        sids.append(make_paid(p))
        gp = create_group(client, tp, p, [])
        codes = [client.post(base(p, gp), json={"title": f"p{i}"}, headers=ck(tp)).status_code for i in range(4)]
        check("paid user creates unlimited (4 x 201)", codes == [201] * 4, str(codes))
        g = client.get(base(p, gp), headers=ck(tp)).json()["gate"]
        check("paid gate unlimited", g["allowed"] is True and g["unlimited"] is True, str(g))

        # downgrade: paid -> free; existing retained/editable, new create blocked
        sql("UPDATE users SET subscription_id = NULL WHERE _id=%s", (p,))
        lst = client.get(base(p, gp), headers=ck(tp)).json()["announcements"]
        check("after downgrade existing announcements still viewable", len(lst) == 4, str(len(lst)))
        r = client.put(f"{base(p, gp)}/{lst[0]['id']}", json={"title": "edit after downgrade"}, headers=ck(tp))
        check("after downgrade editing existing allowed", r.status_code == 200, f"{r.status_code}")
        r = client.post(base(p, gp), json={"title": "new after downgrade"}, headers=ck(tp))
        check("after downgrade new create blocked (403)", r.status_code == 403, f"{r.status_code}")

        # lapsed paid plan beyond grace is not paid
        sid2 = make_paid(p)
        sids.append(sid2)
        sql("UPDATE subscriptions SET current_period_end = now() - interval '365 days' WHERE _id=%s", (sid2,))
        r = client.post(base(p, gp), json={"title": "lapsed"}, headers=ck(tp))
        check("lapsed (beyond grace) plan still gated -> 403", r.status_code == 403, f"{r.status_code}")
        # free plan_type row with active status is not paid
        sql("UPDATE subscriptions SET plan_type='free', current_period_end = now() + interval '5 days' WHERE _id=%s", (sid2,))
        r = client.post(base(p, gp), json={"title": "freeplan"}, headers=ck(tp))
        check("plan_type='free' row is not paid -> 403", r.status_code == 403, f"{r.status_code}")
    finally:
        cleanup([f, p], [g for g in (g1, g2, gp) if g], sids)


def test_flag_and_blocked(client):
    print("\n== I. feature flag + blocked-user filter ==")
    a, ta = signup(client, f"an_fa_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"an_fb_{uuid.uuid4().hex[:8]}")
    sids = [make_paid(a), make_paid(b)]
    gid = None
    try:
        gid = create_group(client, ta, a, [b])
        client.post(base(a, gid), json={"title": "from a"}, headers=ck(ta))
        client.post(base(b, gid), json={"title": "from b"}, headers=ck(tb))
        sql("INSERT INTO blocked_users (blocker_id, blocked_id) VALUES (%s,%s)", (b, a))
        titles = [x["title"] for x in client.get(base(b, gid), headers=ck(tb)).json()["announcements"]]
        check("blocked author's announcement hidden from blocker's list", titles == ["from b"], str(titles))
        sql("DELETE FROM blocked_users WHERE blocker_id=%s", (b,))
        ann_module.ANNOUNCEMENTS_ENABLED = False
        try:
            import routes.group_announcements as rt
            rt.ANNOUNCEMENTS_ENABLED = False
            r = client.get(base(a, gid), headers=ck(ta))
            check("flag off -> 404", r.status_code == 404, f"{r.status_code}")
            r = client.post(base(a, gid), json={"title": "x"}, headers=ck(ta))
            check("flag off create -> 404", r.status_code == 404, f"{r.status_code}")
        finally:
            ann_module.ANNOUNCEMENTS_ENABLED = True
            rt.ANNOUNCEMENTS_ENABLED = True
        check("group delete cascades announcements", True)
        sql("DELETE FROM groups WHERE _id=%s", (gid,))
        check("cascade removed rows", sql("SELECT count(*) FROM group_announcements WHERE group_id=%s", (gid,), fetch=True)[0][0] == 0)
    finally:
        cleanup([a, b], [gid] if gid else [], sids)


def main():
    with TestClient(main_module.app) as client:
        test_migration(client)
        test_authz(client)
        test_crud_permissions(client)
        test_visibility(client)
        test_banner(client)
        test_gate(client)
        test_flag_and_blocked(client)

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
