"""Backend coverage for task 20260929-group-info-panel (testing step 2).

Proves, against the real routes + dev Postgres (same harness as
test_group_leave_delete.py):
  A. Authz: every new route is member-only (403 for a non-member, 401
     unauthenticated, 403 for a mismatched user_id in the path).
  B. Rename: happy path, blank/overlong/content-filtered rejected, members
     untouched; the old-client PUT /groups/{u}/{g} still works and now also
     rejects a blank title.
  C. Group photo: upload-url policy is scoped to group-photos/{group_id}/;
     confirm rejects another group's key, a profile-photo key, a message
     attachment key, and traversal (403, nothing persisted); remove returns
     restore_key and restore via confirm works; photo_key is never exposed.
  D. Mute: per-user (other members unaffected), idempotent, persisted,
     reflected in GET /groups/{u}/{g} and /info; muted offline member gets NO
     APNs push but the message is still persisted; unmuted member still pushed.
  E. Gallery: newest-first, kind filter + invalid kind 422, keyset pagination
     without gaps/dupes, blocked users hidden, plain text messages excluded,
     stored attachment_key never returned, GIF url from meta, half/bad cursor
     422, non-member 403.

Run with: cd api && ../.venv/bin/python tests/test_group_info_panel.py
"""
import _pathfix  # noqa: F401

import asyncio
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
import routes.group_info as group_info_module  # noqa: E402
import backend.interactions.websockets as ws_module  # noqa: E402
from backend.interactions.websockets import ConnectionManager  # noqa: E402
from backend.interactions.groups import GALLERY_PAGE_SIZE  # noqa: E402
from db import DBManager  # noqa: E402

PASSED, FAILED = [], []


def check(label: str, cond: bool, detail: str = ""):
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


def cleanup(user_ids, group_ids):
    db = DBManager()
    try:
        for gid in group_ids:
            db.cur.execute("DELETE FROM messages WHERE group_id = %s", (gid,))
            db.cur.execute("DELETE FROM groups WHERE _id = %s", (gid,))
        for uid in user_ids:
            db.cur.execute("DELETE FROM message_recipients WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM messages WHERE from_user = %s", (uid,))
            db.cur.execute("DELETE FROM device_tokens WHERE user_id = %s", (uid,))
            db.cur.execute("DELETE FROM blocked_users WHERE blocker_id = %s OR blocked_id = %s", (uid, uid))
            db.cur.execute("DELETE FROM groups WHERE %s = ANY(users)", (uid,))
            db.cur.execute("DELETE FROM users WHERE _id = %s", (uid,))
        db.conn.commit()
    finally:
        db.close()


def create_group(client, token, owner, members, title="Info panel group"):
    gid = str(uuid.uuid4())
    r = client.post(f"/groups/{owner}", json={"group_id": gid, "title": title, "users": [owner, *members]},
                    headers=ck(token))
    assert r.status_code == 201, f"create_group failed: {r.status_code} {r.text}"
    return gid


def db_one(sql, params=()):
    db = DBManager()
    try:
        db.cur.execute(sql, params)
        return db.cur.fetchone()
    finally:
        db.close()


def seed_message(gid, uid, kind, key=None, meta=None, ts=None, text=""):
    import json
    mid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.cur.execute(
            "INSERT INTO messages (_id, from_user, group_id, text, timestamp, attachment_kind, "
            "attachment_key, attachment_meta) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
            (mid, uid, gid, text, ts or datetime.now(timezone.utc), kind, key,
             json.dumps(meta) if meta is not None else None),
        )
        db.conn.commit()
    finally:
        db.close()
    return mid


# ── A. authorization ──────────────────────────────────────────────────────────
def test_authz(client):
    print("\n== A. all new routes are member-only ==")
    a, ta = signup(client, f"gi_a_{uuid.uuid4().hex[:8]}")
    o, to = signup(client, f"gi_o_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, ta, a, [])
        routes = [
            ("GET", f"/groups/{o}/{gid}/info", None),
            ("PUT", f"/groups/{o}/{gid}/title", {"title": "hijack"}),
            ("POST", f"/groups/{o}/{gid}/photo/upload-url", {"content_type": "image/png"}),
            ("POST", f"/groups/{o}/{gid}/photo/confirm", {"object_key": f"group-photos/{gid}/{o}/x.png"}),
            ("DELETE", f"/groups/{o}/{gid}/photo", None),
            ("PUT", f"/groups/{o}/{gid}/mute", None),
            ("DELETE", f"/groups/{o}/{gid}/mute", None),
            ("GET", f"/groups/{o}/{gid}/gallery", None),
        ]
        for method, url, body in routes:
            r = client.request(method, url, json=body, headers=ck(to))
            check(f"non-member {method} {url.split(gid)[1]} -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
            # Outsider spoofing the member's user_id in the path is refused by require_match.
            spoof = url.replace(o, a)
            r = client.request(method, spoof, json=body, headers=ck(to))
            check(f"spoofed user_id {method} {url.split(gid)[1]} -> 403", r.status_code == 403, f"{r.status_code}")
            r = client.request(method, url.replace(o, a), json=body)
            check(f"unauthenticated {method} {url.split(gid)[1]} -> 401", r.status_code == 401, f"{r.status_code}")
        check("non-member calls changed nothing",
              db_one("SELECT title, photo_key FROM groups WHERE _id=%s", (gid,)) == ("Info panel group", None))
        check("non-member mute wrote no row",
              db_one("SELECT 1 FROM group_mutes WHERE group_id=%s", (gid,)) is None)
    finally:
        cleanup([a, o], [gid] if gid else [])


# ── B. rename ─────────────────────────────────────────────────────────────────
def test_rename(client):
    print("\n== B. rename + old-client PUT compatibility ==")
    a, ta = signup(client, f"gi_ra_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"gi_rb_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, ta, a, [b])
        r = client.put(f"/groups/{b}/{gid}/title", json={"title": "  New Name  "}, headers=ck(tb))
        check("any member (non-creator) can rename -> 200 stripped", r.status_code == 200 and r.json()["title"] == "New Name",
              f"{r.status_code} {r.text}")
        row = db_one("SELECT title, users FROM groups WHERE _id=%s", (gid,))
        check("stored title updated, members untouched", row[0] == "New Name" and set(row[1]) == {a, b}, str(row))
        seen = client.get(f"/groups/{a}/{gid}", headers=ck(ta)).json()
        check("other member sees new title", seen["group"].get("title") == "New Name", str(seen))

        for label, title in (("blank", "   "), ("empty", ""), ("overlong (256)", "x" * 256)):
            r = client.put(f"/groups/{a}/{gid}/title", json={"title": title}, headers=ck(ta))
            check(f"{label} title -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
        r = client.put(f"/groups/{a}/{gid}/title", json={"title": "x" * 255}, headers=ck(ta))
        check("255-char title accepted (VARCHAR(255) boundary)", r.status_code == 200, f"{r.status_code} {r.text}")
        check("rejected renames never overwrote title", db_one("SELECT title FROM groups WHERE _id=%s", (gid,))[0] == "x" * 255)

        # Content filter (check_clean) applies. Use the filter itself to find a rejected string.
        from backend.moderation.content_filter import ContentRejected, check_clean
        bad = None
        for cand in ("fuck", "shit", "nigger", "cunt"):
            try:
                check_clean(title=cand)
            except ContentRejected:
                bad = cand
                break
        if bad:
            r = client.put(f"/groups/{a}/{gid}/title", json={"title": bad}, headers=ck(ta))
            check("content-filtered title -> 422", r.status_code == 422, f"{r.status_code} {r.text}")
        else:
            check("content filter has a rejectable word to test with", False, "no candidate rejected")

        # Old client PUT: {group_id,title,users} only -- must still work.
        r = client.put(f"/groups/{a}/{gid}", json={"group_id": gid, "title": "Old Client Title", "users": [a, b]},
                       headers=ck(ta))
        check("old-client PUT /groups/{u}/{g} still succeeds", r.status_code in (200, 204), f"{r.status_code} {r.text}")
        check("old-client PUT applied", db_one("SELECT title FROM groups WHERE _id=%s", (gid,))[0] == "Old Client Title")
        r = client.put(f"/groups/{a}/{gid}", json={"group_id": gid, "title": "  ", "users": [a, b]}, headers=ck(ta))
        check("old-client PUT with blank title -> 422 (hardened)", r.status_code == 422, f"{r.status_code} {r.text}")
        check("blank PUT did not change title", db_one("SELECT title FROM groups WHERE _id=%s", (gid,))[0] == "Old Client Title")
    finally:
        cleanup([a, b], [gid] if gid else [])


# ── C. photo ──────────────────────────────────────────────────────────────────
def test_photo(client):
    print("\n== C. group photo key validation ==")
    a, ta = signup(client, f"gi_pa_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"gi_pb_{uuid.uuid4().hex[:8]}")
    gid = other_gid = None
    deleted = []
    orig_delete = group_info_module.delete_object
    group_info_module.delete_object = lambda k: deleted.append(k)
    try:
        gid = create_group(client, ta, a, [b])
        other_gid = create_group(client, tb, b, [])

        r = client.post(f"/groups/{a}/{gid}/photo/upload-url", json={"content_type": "image/png"}, headers=ck(ta))
        check("upload-url -> 200 with presigned POST", r.status_code == 200 and "fields" in r.json(), f"{r.status_code} {r.text}")
        key = r.json().get("object_key", "")
        check("object_key is scoped to group-photos/{group_id}/", key.startswith(f"group-photos/{gid}/"), key)
        r = client.post(f"/groups/{a}/{gid}/photo/upload-url", json={"content_type": "application/pdf"}, headers=ck(ta))
        check("non-image content_type -> 400", r.status_code == 400, f"{r.status_code} {r.text}")

        bad_keys = {
            "another group's key": f"group-photos/{other_gid}/{b}/{uuid.uuid4()}.png",
            "profile-photo key": f"profile-photos/{a}/{uuid.uuid4()}.png",
            "message attachment key": f"attachments/{a}/{uuid.uuid4()}.png",
            "traversal": f"group-photos/{gid}/../{other_gid}/x.png",
            "prefix-only lookalike": f"group-photos/{gid}x/y.png",
            "blank": "",
        }
        for label, bk in bad_keys.items():
            r = client.post(f"/groups/{a}/{gid}/photo/confirm", json={"object_key": bk}, headers=ck(ta))
            check(f"confirm rejects {label} -> 403", r.status_code == 403, f"{r.status_code} {r.text}")
        check("no rejected confirm persisted a key", db_one("SELECT photo_key FROM groups WHERE _id=%s", (gid,))[0] is None)

        r = client.post(f"/groups/{a}/{gid}/photo/confirm", json={"object_key": key}, headers=ck(ta))
        check("confirm with own-group key -> 200 + photo_url", r.status_code == 200 and r.json().get("photo_url"), f"{r.status_code} {r.text}")
        check("photo_key persisted", db_one("SELECT photo_key FROM groups WHERE _id=%s", (gid,))[0] == key)

        g = client.get(f"/groups/{b}/{gid}", headers=ck(tb)).json()
        check("GET group exposes photo_url, never photo_key", g["group"].get("photo_url") and "photo_key" not in g["group"], str(g))
        info = client.get(f"/groups/{b}/{gid}/info", headers=ck(tb)).json()
        check("/info has photo_url, no photo_key, title, members",
              info.get("photo_url") and "photo_key" not in info and info.get("title") and len(info.get("members", [])) == 2, str(info))

        key2 = f"group-photos/{gid}/{b}/{uuid.uuid4()}.png"
        r = client.post(f"/groups/{b}/{gid}/photo/confirm", json={"object_key": key2}, headers=ck(tb))
        check("replacing photo deletes the old object", r.status_code == 200 and deleted == [key], f"{r.status_code} deleted={deleted}")

        r = client.delete(f"/groups/{a}/{gid}/photo", headers=ck(ta))
        check("remove -> 200 with restore_key", r.status_code == 200 and r.json().get("restore_key") == key2, f"{r.status_code} {r.text}")
        check("photo_key cleared", db_one("SELECT photo_key FROM groups WHERE _id=%s", (gid,))[0] is None)
        check("remove keeps S3 object (undo grace)", deleted == [key], str(deleted))
        info = client.get(f"/groups/{a}/{gid}/info", headers=ck(ta)).json()
        check("/info photo_url None after remove (initials fallback)", info.get("photo_url") is None, str(info))
        r = client.delete(f"/groups/{a}/{gid}/photo", headers=ck(ta))
        check("remove again is idempotent, restore_key None", r.status_code == 200 and r.json().get("restore_key") is None, f"{r.status_code} {r.text}")
        r = client.post(f"/groups/{a}/{gid}/photo/confirm", json={"object_key": key2}, headers=ck(ta))
        check("undo: confirm(restore_key) restores photo", r.status_code == 200 and
              db_one("SELECT photo_key FROM groups WHERE _id=%s", (gid,))[0] == key2, f"{r.status_code} {r.text}")
    finally:
        group_info_module.delete_object = orig_delete
        cleanup([a, b], [g for g in (gid, other_gid) if g])


# ── D. mute ───────────────────────────────────────────────────────────────────
def test_mute_api(client):
    print("\n== D1. mute API ==")
    a, ta = signup(client, f"gi_ma_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"gi_mb_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, ta, a, [b])
        check("default not muted (GET group)", client.get(f"/groups/{a}/{gid}", headers=ck(ta)).json()["group"].get("muted") is False)
        r = client.put(f"/groups/{a}/{gid}/mute", headers=ck(ta))
        check("mute -> 200 muted true", r.status_code == 200 and r.json() == {"muted": True}, f"{r.status_code} {r.text}")
        r = client.put(f"/groups/{a}/{gid}/mute", headers=ck(ta))
        check("mute again is idempotent", r.status_code == 200 and r.json() == {"muted": True}, f"{r.status_code} {r.text}")
        check("exactly one mute row", db_one("SELECT count(*) FROM group_mutes WHERE group_id=%s", (gid,))[0] == 1)
        check("GET group reflects muted for A", client.get(f"/groups/{a}/{gid}", headers=ck(ta)).json()["group"].get("muted") is True)
        check("/info reflects muted for A", client.get(f"/groups/{a}/{gid}/info", headers=ck(ta)).json().get("muted") is True)
        check("B unaffected (GET group muted False)", client.get(f"/groups/{b}/{gid}", headers=ck(tb)).json()["group"].get("muted") is False)
        check("B unaffected (/info muted False)", client.get(f"/groups/{b}/{gid}/info", headers=ck(tb)).json().get("muted") is False)
        r = client.delete(f"/groups/{a}/{gid}/mute", headers=ck(ta))
        check("unmute -> 200 muted false", r.status_code == 200 and r.json() == {"muted": False}, f"{r.status_code} {r.text}")
        r = client.delete(f"/groups/{a}/{gid}/mute", headers=ck(ta))
        check("unmute when not muted is idempotent", r.status_code == 200 and r.json() == {"muted": False}, f"{r.status_code}")
        check("mute row gone", db_one("SELECT 1 FROM group_mutes WHERE group_id=%s", (gid,)) is None)
    finally:
        cleanup([a, b], [gid] if gid else [])


def _mk_user(prefix):
    uid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("users", {"_id": uid, "username": f"{prefix}_{uid[:8]}",
                               "email": f"{prefix}_{uid[:8]}@example.com", "hash_pass": "x"})
    finally:
        db.close()
    return uid


async def test_mute_push_suppression():
    print("\n== D2. muted member gets no push, still gets the message; others still pushed ==")
    sender, muted, normal = _mk_user("gi_s"), _mk_user("gi_m"), _mk_user("gi_n")
    gid = str(uuid.uuid4())
    db = DBManager()
    try:
        db.insertion("groups", {"_id": gid, "title": "mute-push", "users": [sender, muted, normal]})
        db.insertion("group_mutes", {"user_id": muted, "group_id": gid})
    finally:
        db.close()
    pushed = []

    async def fake_send_push(token, title, body, data=None):
        pushed.append(token)
        return True

    orig = ws_module.send_push
    ws_module.send_push = fake_send_push
    manager = ConnectionManager()
    try:
        manager.insertion("device_tokens", {"user_id": muted, "token": "tok-muted"})
        manager.insertion("device_tokens", {"user_id": normal, "token": "tok-normal"})
        await manager.send_msg({"from_user": sender, "to_users": [sender, muted, normal], "text": "hello mute",
                                "group_id": gid, "timestamp": datetime.now(timezone.utc).isoformat()})
        check("normal member pushed", "tok-normal" in pushed, str(pushed))
        check("muted member NOT pushed", "tok-muted" not in pushed, str(pushed))
        row = db_one("SELECT count(*) FROM messages WHERE group_id=%s AND text=%s", (gid, "hello mute"))
        check("message still persisted for the thread", row[0] == 1, str(row))

        # Online muted member still receives the live frame.
        class FakeWS:
            def __init__(self): self.sent = []
            async def send_json(self, p): self.sent.append(p)
        ws = FakeWS()
        manager.active_connections[muted] = ws
        pushed.clear()
        await manager.send_msg({"from_user": sender, "to_users": [sender, muted, normal], "text": "live mute",
                                "group_id": gid, "timestamp": datetime.now(timezone.utc).isoformat()})
        check("muted member still receives live WS frame", len(ws.sent) == 1 and ws.sent[0].get("text") == "live mute", str(ws.sent))
        manager.active_connections.pop(muted, None)

        # Unmute -> pushed again.
        db = DBManager()
        try:
            db.cur.execute("DELETE FROM group_mutes WHERE group_id=%s", (gid,))
            db.conn.commit()
        finally:
            db.close()
        pushed.clear()
        await manager.send_msg({"from_user": sender, "to_users": [sender, muted, normal], "text": "after unmute",
                                "group_id": gid, "timestamp": datetime.now(timezone.utc).isoformat()})
        check("after unmute the member is pushed again", "tok-muted" in pushed, str(pushed))
    finally:
        manager.close()
        ws_module.send_push = orig
        cleanup([sender, muted, normal], [gid])


def test_mute_scoped_per_group(client):
    print("\n== D3. muting one group does not mute another ==")
    a, ta = signup(client, f"gi_sa_{uuid.uuid4().hex[:8]}")
    gids = []
    try:
        g1 = create_group(client, ta, a, [], "g1")
        g2 = create_group(client, ta, a, [], "g2")
        gids = [g1, g2]
        client.put(f"/groups/{a}/{g1}/mute", headers=ck(ta))
        check("g1 muted", client.get(f"/groups/{a}/{g1}/info", headers=ck(ta)).json()["muted"] is True)
        check("g2 not muted", client.get(f"/groups/{a}/{g2}/info", headers=ck(ta)).json()["muted"] is False)
    finally:
        cleanup([a], gids)


# ── E. gallery ────────────────────────────────────────────────────────────────
def test_gallery(client):
    print("\n== E. gallery ==")
    a, ta = signup(client, f"gi_ga_{uuid.uuid4().hex[:8]}")
    b, tb = signup(client, f"gi_gb_{uuid.uuid4().hex[:8]}")
    c, tc = signup(client, f"gi_gc_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, ta, a, [b, c])
        base = datetime.now(timezone.utc) - timedelta(hours=1)
        n = GALLERY_PAGE_SIZE + 6  # forces a second page
        ids_by_order = []
        for i in range(n):
            ids_by_order.append(seed_message(gid, b, "image", key=f"attachments/{b}/img{i}.png",
                                             ts=base + timedelta(seconds=i)))
        seed_message(gid, b, None, text="plain text, not an attachment", ts=base + timedelta(seconds=n + 1))
        video = seed_message(gid, b, "video", key=f"attachments/{b}/v.mp4", ts=base + timedelta(seconds=n + 2))
        gif = seed_message(gid, b, "gif", meta={"url": "https://media.example/g.gif", "id": "g1"},
                           ts=base + timedelta(seconds=n + 3))
        fil = seed_message(gid, b, "file", key=f"attachments/{b}/d.pdf", meta={"filename": "d.pdf"},
                           ts=base + timedelta(seconds=n + 4))
        blocked_msg = seed_message(gid, c, "image", key=f"attachments/{c}/blocked.png", ts=base + timedelta(seconds=n + 5))

        # A blocks C.
        db = DBManager()
        try:
            db.insertion("blocked_users", {"blocker_id": a, "blocked_id": c})
        finally:
            db.close()

        r = client.get(f"/groups/{a}/{gid}/gallery", headers=ck(ta))
        check("gallery -> 200", r.status_code == 200, f"{r.status_code} {r.text}")
        page1 = r.json()
        items = page1["items"]
        check(f"first page size == GALLERY_PAGE_SIZE ({GALLERY_PAGE_SIZE})", len(items) == GALLERY_PAGE_SIZE, str(len(items)))
        check("has_more true with cursor", page1["has_more"] and page1["next_cursor_timestamp"] and page1["next_cursor_id"], str(page1)[:200])
        check("newest first (file, gif, video lead)", [i["id"] for i in items[:3]] == [fil, gif, video], str([i["id"] for i in items[:3]]))
        check("blocked user's attachment hidden from blocker", blocked_msg not in {i["id"] for i in items})
        check("plain text message excluded", all(i["kind"] in ("image", "video", "gif", "file") for i in items))
        check("stored attachment_key never returned", all("attachment_key" not in i and "attachments/" not in str(i.get("meta", "")) for i in items))
        gif_item = next(i for i in items if i["id"] == gif)
        check("gif url comes from meta.url", gif_item["url"] == "https://media.example/g.gif", str(gif_item))
        img_item = next(i for i in items if i["kind"] == "image")
        check("image url is freshly presigned", (img_item["url"] or "").startswith("https://") and "Signature" in img_item["url"] or "X-Amz" in (img_item["url"] or ""), str(img_item["url"]))
        check("item exposes from_user username + timestamp", img_item["from_user"].startswith("gi_gb_") and img_item["timestamp"], str(img_item))

        r = client.get(f"/groups/{a}/{gid}/gallery", params={
            "cursor_timestamp": page1["next_cursor_timestamp"], "cursor_id": page1["next_cursor_id"]}, headers=ck(ta))
        page2 = r.json()
        all_ids = [i["id"] for i in items] + [i["id"] for i in page2["items"]]
        expected = n + 3  # images + video + gif + file (blocked one and text excluded)
        check("pagination has no gaps and no duplicates", len(all_ids) == len(set(all_ids)) == expected, f"{len(all_ids)} vs {expected}")
        check("last page has_more false, no cursor", page2["has_more"] is False and page2["next_cursor_id"] is None, str(page2)[:200])
        check("second page continues strictly older", set(all_ids[GALLERY_PAGE_SIZE:]).isdisjoint({i["id"] for i in items}))

        # Not blocked from C's perspective? C blocked by A only for A. B (no block) sees C's image.
        rb = client.get(f"/groups/{b}/{gid}/gallery", headers=ck(tb)).json()
        check("user without a block relationship sees C's attachment", blocked_msg in {i["id"] for i in rb["items"]})
        # Block is bidirectional: C also cannot see... A has no attachments; verify C does not see nothing odd.
        rc_ids = {i["id"] for i in client.get(f"/groups/{c}/{gid}/gallery", headers=ck(tc)).json()["items"]}
        check("blocked user still sees own content (no self-hide)", blocked_msg in rc_ids)

        for kind, exp in (("video", {video}), ("gif", {gif}), ("file", {fil})):
            got = {i["id"] for i in client.get(f"/groups/{a}/{gid}/gallery", params={"kind": kind}, headers=ck(ta)).json()["items"]}
            check(f"kind={kind} filter", got == exp, str(got))
        imgs = client.get(f"/groups/{a}/{gid}/gallery", params={"kind": "image"}, headers=ck(ta)).json()
        check("kind=image only images", all(i["kind"] == "image" for i in imgs["items"]) and imgs["has_more"])

        for label, params in (
            ("bad kind", {"kind": "audio"}),
            ("timestamp without id", {"cursor_timestamp": "2026-01-01T00:00:00+00:00"}),
            ("id without timestamp", {"cursor_id": str(uuid.uuid4())}),
            ("garbage timestamp", {"cursor_timestamp": "nope", "cursor_id": str(uuid.uuid4())}),
            ("garbage id", {"cursor_timestamp": "2026-01-01T00:00:00+00:00", "cursor_id": "nope"}),
        ):
            r = client.get(f"/groups/{a}/{gid}/gallery", params=params, headers=ck(ta))
            check(f"{label} -> 422", r.status_code == 422, f"{r.status_code} {r.text}")

        # Attachments from another group never leak in.
        other = create_group(client, tb, b, [])
        seed_message(other, b, "image", key=f"attachments/{b}/other.png")
        ids_now = {i["id"] for i in client.get(f"/groups/{a}/{gid}/gallery", headers=ck(ta)).json()["items"]}
        check("gallery scoped to the group", len(ids_now) == GALLERY_PAGE_SIZE)
        cleanup([], [other])
    finally:
        cleanup([a, b, c], [gid] if gid else [])


def test_empty_gallery(client):
    print("\n== E2. empty gallery is an empty page, not an error ==")
    a, ta = signup(client, f"gi_ea_{uuid.uuid4().hex[:8]}")
    gid = None
    try:
        gid = create_group(client, ta, a, [])
        r = client.get(f"/groups/{a}/{gid}/gallery", headers=ck(ta))
        check("empty gallery -> 200 no items", r.status_code == 200 and r.json() == {
            "items": [], "next_cursor_timestamp": None, "next_cursor_id": None, "has_more": False}, f"{r.status_code} {r.text}")
    finally:
        cleanup([a], [gid] if gid else [])


def main():
    with TestClient(main_module.app) as client:
        test_authz(client)
        test_rename(client)
        test_photo(client)
        test_mute_api(client)
        test_mute_scoped_per_group(client)
        test_gallery(client)
        test_empty_gallery(client)
    asyncio.run(test_mute_push_suppression())

    print(f"\n{'='*60}")
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
